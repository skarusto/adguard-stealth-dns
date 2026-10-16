# Руководство: Публичный DNS-over-HTTPS / DNS-over-TLS резолвер со скрытой админ-панелью и сайтом-приманкой

Это руководство воспроизводит с нуля ту же самую конфигурацию, что работает на эталонном VPS:

- **AdGuard Home** как DNS-движок.
- **Публичные резолверы: только DoH и DoT.** Никакого публичного обычного DNS (порт 53), никакого DoQ.
- **Голый домен отдаёт поддельную страницу «корпоративного файлового менеджера»** — приманку, чтобы сканеры и перебор портов видели безобидный сайт.
- **Админ-панель AdGuard недоступна по корню домена.** Она живёт за длинным секретным путём, который перенаправляет на собственную страницу входа AdGuard (без HTTP Basic Auth).
- **Caddy** завершает TLS на `:80`/`:443` и проксирует эндпоинт DoH и секретный путь админки на AdGuard, слушающий `127.0.0.1:3000`.
- Один **сертификат Let's Encrypt** используется совместно Caddy (для `:443`) и AdGuard (для DoT на `:853`).

Всё ниже можно копировать и вставлять. Сначала замените плейсхолдеры из §0 на свои значения.

---

## Содержание

0. [Значения, которые нужно задать](#0-значения-которые-нужно-задать)
1. [Архитектура](#1-архитектура)
2. [Требования](#2-требования)
3. [DNS: направить имя на VPS](#3-dns-направить-имя-на-vps)
4. [Базовая подготовка сервера](#4-базовая-подготовка-сервера)
5. [Файрвол (UFW)](#5-файрвол-ufw)
6. [Установка Caddy](#6-установка-caddy)
7. [Выпуск общего TLS-сертификата (certbot)](#7-выпуск-общего-tls-сертификата-certbot)
8. [Установка AdGuard Home](#8-установка-adguard-home)
9. [Настройка AdGuard Home (критический YAML)](#9-настройка-adguard-home-критический-yaml)
10. [Развёртывание сайта-приманки](#10-развёртывание-сайта-приманки)
11. [Caddyfile (мозг маршрутизации)](#11-caddyfile-мозг-маршрутизации)
12. [Запуск и проверка](#12-запуск-и-проверка)
13. [Опционально: импорт настроек из другого конфига AdGuard](#13-опционально-импорт-настроек-из-другого-конфига-adguard)
14. [Подводные камни и мины](#14-подводные-камни-и-мины)
15. [Укрепление и обслуживание](#15-укрепление-и-обслуживание)
16. [Приложение A: полное дерево файлов](#приложение-a-полное-дерево-файлов)
17. [Приложение B: шпаргалка по проверке](#приложение-b-шпаргалка-по-проверке)
18. [Приложение C: откат / удаление](#приложение-c-откат--удаление)

---

## 0. Значения, которые нужно задать

| Плейсхолдер | Значение | Пример из эталона |
|---|---|---|
| `DOMAIN` | Публичное имя хоста с A/AAAA-записью на VPS | `YOURDOMAIN.example` |
| `EMAIL` | Контактный email для Let's Encrypt | `you@example.com` |
| `SECRET_PATH` | Длинный случайный путь, скрывающий админку. Никогда не публикуется. | `/REDACTED_SECRET_PATH` (без слэша на конце) |
| `ADMIN_USER` | Имя администратора AdGuard | `admin` |
| `ADMIN_PASS` | Пароль администратора AdGuard (надёжный) | — |
| `VPS_IP` | Публичный IPv4 сервера | `YOUR_VPS_IP` |

Сгенерируйте секретный путь (сделайте это один раз и сохраните):

```bash
SECRET_PATH="/$(openssl rand -hex 16)"   # -> /a1b2c3d4e5f60718a1b2c3d4e5f60718  (16 байт / 32 hex)
echo "$SECRET_PATH"
```

Задайте переменные оболочки для остатка руководства (вставьте одним блоком, отредактируйте значения):

```bash
DOMAIN="dns.example.com"
EMAIL="you@example.com"
SECRET_PATH="/a1b2c3d4e5f60718a1b2c3d4e5f60718"
ADMIN_USER="admin"
ADMIN_PASS="CHANGE_ME_TO_SOMETHING_STRONG"
```

> Рекомендация: выполняйте всю сборку от `root` (или через `sudo -i`). Штатный юнит AdGuard запускает процесс от root; Caddy работает под непривилегированным пользователем `caddy`.

---

## 1. Архитектура

```
                          Интернет
                             |
              +--------------+---------------+
              |  :80  (HTTP -> редирект HTTPS)|
              |  :443 (TLS, Caddy)            |
              |  :853 (TLS, AdGuard DoT)      |
              +--------------+---------------+
                             |
                 +-----------+-----------+
                 |        Caddy          |   завершает TLS общим сертификатом
                 |  (владеет :80 и :443) |
                 +-----------+-----------+
                             |
   маршрутизация (взаимоисключающая, в этом порядке):
     1. /dns-query                      -> reverse_proxy 127.0.0.1:3000   (публичный DoH)
     2. $SECRET_PATH и всё под ним      -> strip prefix -> 127.0.0.1:3000 (скрытая админка)
     3. всё остальное                   -> /var/www/fake (сайт-приманка)

                 AdGuard Home  (только 127.0.0.1:3000)
                 - веб-админка + DoH (обычный HTTP за Caddy, "insecure_enabled")
                 - слушатель DoT на :853 с /etc/ssl/adguard/{fullchain,privkey}.pem
                 - обычный DNS: ОТКЛЮЧЁН   DoQ: ОТКЛЮЧЁН   :443: не используется (им владеет Caddy)
```

Ключевые правила дизайна:

- **Только Caddy слушает публично на `:443`.** Собственный HTTPS-слушатель AdGuard выключен (`tls.port_https: 0`), поэтому нет конфликта портов, и админка никогда не доступна напрямую по домену.
- **AdGuard слушает только на `127.0.0.1:3000`.** Его веб-интерфейс никогда не выставляется на публичный интерфейс.
- **DoH в AdGuard работает по обычному HTTP за Caddy** (`http.doh.insecure_enabled: true`). Caddy делает TLS; AdGuard лишь отвечает на протокол DoH на localhost.
- **DoT (`:853`) в AdGuard публичен и говорит по TLS напрямую**, используя общий сертификат.
- **Сайт-приманка — это обработчик по умолчанию.** Любой путь, кроме `/dns-query` и путей под `$SECRET_PATH`, получает поддельную страницу.

---

## 2. Требования

- VPS под **Debian 12/13** или **Ubuntu 22.04/24.04**, x86_64 или arm64.
- Доступ **root** (или sudo).
- **Публичный IPv4**.
- **Имя хоста** (`DOMAIN`), A-запись которого (и, при желании, AAAA) указывает на VPS. Если IP вашего домашнего/серверного подключения меняется, используйте динамический DNS (DuckDNS, `linkpc.net`, `afraid.org` и т. п.) или полноценный домен.
- **Входящие порты 80, 443, 853 доступны из интернета.** Проверьте позже из внешней сети; многие провайдеры блокируют 80/443 на домашних подключениях, а часть облачных файрволов закрывает их по умолчанию.
- VPS должен иметь доступ в интернет (для установки пакетов и для того, чтобы AdGuard скачивал блок-листы).
- Никакой существующий сервис уже не занимает порты **80, 443 или 853**. Проверьте перед началом:

```bash
ss -tlnp | grep -E ':(80|443|853)\b' || echo "все три порта свободны"
```

- **Проверьте, какие порты уже занимают существующие сервисы** (например, WireGuard, SSH), чтобы файрвол не отрезал вас. См. §5.

---

## 3. DNS: направить имя на VPS

Выберите один вариант:

**A) Настоящий домен** — у регистратора/DNS-провайдера создайте:

```
A     dns.example.com   ->  <VPS_IP>
```

**B) DuckDNS** (бесплатный динамический DNS):

```bash
# создайте субдомен в панели DuckDNS, затем:
curl -s "https://www.duckdns.org/update?domains=YOURNAME&token=YOURTOKEN&ip="
```

**C) linkpc.net / afraid.org** — используйте их URL обновления динамического DNS или панель, чтобы направить `YOURNAME.<провайдер>` на публичный IP VPS.

Проверьте распространение **до того, как продолжите** (иначе Let's Encrypt потерпит неудачу):

```bash
getent hosts "$DOMAIN"
# или: dig +short A "$DOMAIN"
```

Возвращённый IP должен совпасть с публичным IP VPS. Также убедитесь, что ваш роутер/провайдер не делает DNS rebinding protection или captive portal на 80.

---

## 4. Базовая подготовка сервера

```bash
apt update && apt -y upgrade
apt -y install curl wget gnupg ca-certificates apt-transport-https \
               debian-keyring debian-archive-keyring ufw openssl
timedatectl set-timezone UTC
```

Убедитесь, что на самом сервере работает разрешение имён (нужно для установки пакетов):

```bash
getent hosts deb.debian.org || echo "проблема с резолвером"
```

---

## 5. Файрвол (UFW)

> **Прочтите сначала.** Прежде чем включать UFW, перечислите все порты, которые должны остаться открытыми (SSH, WireGuard, игровые серверы и т. д.). Включение файрвола с политикой deny по умолчанию, при котором вы забыли порт какого-то сервиса, отрежет его. На эталонном сервере пришлось дополнительно разрешить UDP-порт WireGuard/AmneziaWG и TCP-порт узла OpenFlux именно по этой причине.

Посмотрите, что сейчас слушается:

```bash
ss -tlnp        # TCP
ss -ulnp        # UDP
```

Затем настройте (отредактируйте дополнительные строки под свой сервер; примеры даны закомментированными):

```bash
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp          # SSH  -- НИКОГДА не забывайте этот порт
ufw allow 80/tcp          # ACME HTTP-01 + редирект HTTP->HTTPS
ufw allow 443/tcp         # DoH + админка + приманка (TLS)
ufw allow 853/tcp         # DoT

# --- сохраните уже существующие сервисы (примеры; УДАЛИТЕ лишнее) ---
# ufw allow 51820/udp     # WireGuard
# ufw allow 64672/udp     # AmneziaWG
# ufw allow 58472/tcp     # какой-то ваш сервис

# ТОЛЬКО если сервер реально маршрутизирует VPN, сохраните форвардинг.
# Установщик делает это опцией (VPN_FORWARDING=yes) и по умолчанию файл не трогает:
# sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw --force enable
ufw status verbose
```

Ожидаемый результат: `443/tcp`, `853/tcp`, `80/tcp`, `22/tcp` — ALLOW на вход; всё остальное запрещено.

> **Не** открывайте `3000` и `53`. Интерфейс AdGuard остаётся на localhost, а обычный DNS отключён — если позже в файрволе окажется открытым `3000` или `53`, значит что-то настроено неправильно.

---

## 6. Установка Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list

apt update
apt -y install caddy
```

Пакет сразу запускает Caddy со штатным конфигом. **Остановите его на время**, чтобы освободить порт 80 для проверки сертификата:

```bash
systemctl stop caddy
```

---

## 7. Выпуск общего TLS-сертификата (certbot)

Мы используем **certbot** (а не встроенный ACME Caddy), потому что одни и те же файлы сертификата/ключа должны читаться **и** Caddy (для `:443`), **и** AdGuard (для `:853`).

```bash
apt -y install certbot
```

### 7.1 Создайте общий каталог сертификата

```bash
install -d -m 755 /etc/ssl/adguard
```

### 7.2 Получите сертификат (standalone)

Порт 80 должен быть свободен; Caddy остановлен, а AdGuard ещё не установлен, так что всё в порядке. `--pre-hook`/`--post-hook` сохраняются в конфиг продления и будут освобождать порт 80 при каждом будущем продлении:

```bash
certbot certonly --standalone \
  --pre-hook  "systemctl stop caddy || true" \
  --post-hook "systemctl start caddy || true" \
  -d "$DOMAIN" \
  -m "$EMAIL" \
  --agree-tos --no-eff-email --non-interactive
```

Результат: `/etc/letsencrypt/live/$DOMAIN/{fullchain.pem,privkey.pem}`.

### 7.3 Deploy-хук (навсегда держит общую копию в синхроне)

Создайте `/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh`:

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh <<'EOF'
#!/bin/bash
# Копирует только что выпущенный/продлённый сертификат в общее место и
# заставляет каждый сервис подхватить его.
set -e
DOMAIN="__DOMAIN__"
LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="/etc/ssl/adguard"

install -d -m 755 "$DEST"
# fullchain: доступен всем на чтение. privkey: на чтение только root и группе caddy.
install -m 644 "$LIVE/fullchain.pem" "$DEST/fullchain.pem"
install -m 640 -o root -g caddy "$LIVE/privkey.pem" "$DEST/privkey.pem"
chown root:caddy "$DEST"

systemctl reload caddy   2>/dev/null || true   # Caddy перечитывает сертификат на лету
systemctl restart AdGuardHome 2>/dev/null || true # AdGuard читает сертификат при запуске
EOF

# подставляем реальный домен и делаем исполняемым
sed -i "s|__DOMAIN__|$DOMAIN|" /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
```

Запустите его один раз сейчас, чтобы файлы существовали до старта Caddy:

```bash
/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
ls -l /etc/ssl/adguard/
```

Вы должны увидеть `fullchain.pem` (root:root, 644) и `privkey.pem` (root:caddy, 640).

> **Почему `root:caddy` + `640`:** сервис Caddy работает под пользователем `caddy` и должен читать приватный ключ; AdGuard работает от root, который тоже может его читать. Если позже смените пользователя Caddy, обновите эту группу.

> **Продление** выполняется автоматически systemd-таймером `certbot.timer`. Поскольку продление использует `--standalone`, сохранённый `--pre-hook` останавливает Caddy, чтобы освободить `:80` (пара секунд простоя), затем `--post-hook` запускает его снова.

> **НИКОГДА не запускайте `certbot renew --dry-run` на этом сервере бездумно.** Dry-run использует **staging**-окружение Let's Encrypt, и deploy-хук выше послушно скопирует *staging* сертификат поверх боевого, сломав DoT/DoH до следующего реального выпуска. Если dry-run всё же нужен, сначала отключите deploy-хук.

---

## 8. Установка AdGuard Home

Используйте официальный установщик:

```bash
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
```

Он скачивает AdGuard Home в `/opt/AdGuardHome`, устанавливает systemd-юнит (`AdGuardHome.service`) и запускает **мастер первоначальной настройки** на `:3000` (временно слушающий на всех интерфейсах).

### 8.1 Прогоните мастер настройки один раз (чтобы задать учётную запись администратора)

Сделайте это через SSH-туннель, чтобы `:3000` никогда не выставлялся публично:

```bash
# с ВАШЕЙ машины:
ssh -L 3000:127.0.0.1:3000 root@<VPS_IP>
# затем откройте http://127.0.0.1:3000 в браузере
```

Задайте имя/пароль администратора `$ADMIN_USER` / `$ADMIN_PASS`, завершите мастер и дайте ему хотя бы раз дойти до дашборда. Затем остановите AdGuard, чтобы отредактировать YAML напрямую:

```bash
systemctl stop AdGuardHome
```

> Мастер записывает **bcrypt**-хэш вашего пароля в `AdGuardHome.yaml`. Последующее редактирование YAML сохраняет этот хэш. Это избавляет от ручной генерации совместимой bcrypt-строки.

---

## 9. Настройка AdGuard Home (критический YAML)

Отредактируйте `/opt/AdGuardHome/AdGuardHome.yaml`. Приведённые ниже настройки — те, что заставляют всю архитектуру работать. **Не перезаписывайте файл целиком вслепую** — сгенерированные мастером `users:`, `filters:`, `clients:` и т. д. должны остаться. Измените/вставьте эти ключи:

```yaml
http:
  address: 127.0.0.1:3000        # (1) привязать админку + DoH ТОЛЬКО к LOCALHOST
  session_ttl: 720h
  doh:
    enabled: true
    insecure_enabled: true       # (2) ОБЯЗАТЕЛЬНО: TLS завершает Caddy,
                                 #     поэтому Caddy->AdGuard идёт по обычному HTTP. Без
                                 #     этого /dns-query возвращает ошибки.

dns:
  bind_hosts:
    - 0.0.0.0                    # куда AdGuard привязал бы обычный DNS (не используется, см. ниже)
  port: 53
  serve_plain_dns: false         # (3) НИКАКОГО публичного обычного DNS на :53
  # ... ваши upstream_dns / bootstrap_dns / fallback_dns / и т. д. остаются здесь ...

tls:
  enabled: true
  server_name: DOMAIN            # ваше имя хоста
  force_https: false
  certificate_path: /etc/ssl/adguard/fullchain.pem   # (4) общий сертификат
  private_key_path: /etc/ssl/adguard/privkey.pem
  port_https: 0                  # (5) НЕ привязывать :443 -- им владеет Caddy
  port_dns_over_tls: 853         # (6) здесь живёт публичный DoT
  port_dns_over_quic: 0          # (7) DoQ ВЫКЛ

schema_version: 34               # (8) ЗАФИКСИРУЙТЕ ЭТО -- см. предупреждение ниже
```

Затем примените владельца и перезапустите:

```bash
chown root:root /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
sleep 3
systemctl is-active AdGuardHome
ss -tlnp | grep AdGuardHome      # ожидайте ТОЛЬКО 127.0.0.1:3000 и *:853
```

### Почему важна каждая пронумерованная строка

1. **`http.address: 127.0.0.1:3000`** — если оставить значение мастера по умолчанию (`0.0.0.0:3000`), админка будет доступна по `http://<VPS_IP>:3000` (и через домен, если что-то его проксирует), что разрушает всю идею «скрытой админки».
2. **`http.doh.insecure_enabled: true`** — эндпоинт DoH в AdGuard обычно требует HTTPS. За реверс-прокси TLS завершается выше по стеку, поэтому AdGuard надо явно указать принимать обычный HTTP DoH. **Это самая частая причина неработающего `/dns-query`.**
3. **`dns.serve_plain_dns: false`** — обычный DNS наружу не выставляется.
4. **пути к сертификату** — указывают на общую копию, которой управляет deploy-хук certbot.
5. **`tls.port_https: 0`** — не даёт AdGuard бороться с Caddy за `:443`. `0` = не слушать.
6. **`tls.port_dns_over_tls: 853`** — именно так выставляется DoT.
7. **`tls.port_dns_over_quic: 0`** — DoQ выключен (не требуется; минимальная поверхность атаки).
8. **`schema_version`** — см. ниже.

> **Мина версии схемы.** Если позволить AdGuard выполнить миграцию конфига (записав конфиг с `schema_version` *ниже*, чем ожидает бинарник, и затем перезапустившись), он перепишет YAML и может (а) заново вложить `bootstrap_dns` так, что это перестанет парситься, и (б) отбросить новые ключи вроде `http.doh.insecure_enabled`. Для конфига из *более старого* AdGuard задайте `schema_version` равным значению, которое использует **текущий** бинарник (узнать можно через `AdGuardHome --version` / один раз прогнав мастер и прочитав сгенерированный файл) и держите его зафиксированным. В эталонном развёртывании зафиксировано **34**.

### Systemd-юнит

Установщик создаёт `/etc/systemd/system/AdGuardHome.service`. Убедитесь, что он совпадает (чтобы всегда загружался наш явный конфиг и никогда не выполнялось само-обновление):

```ini
[Unit]
Description=AdGuard Home
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome --no-check-update
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable AdGuardHome
```

---

## 10. Развёртывание сайта-приманки

```bash
install -d -m 755 /var/www/fake
# Установщик по умолчанию использует копию из репозитория; задайте DECOY_URL,
# чтобы скачать другую страницу. Ручной эквивалент (из клона репозитория):
cp /root/adguard-stealth-dns/assets/index.html /var/www/fake/index.html
chmod 644 /var/www/fake/index.html
```

Эта страница рисует поддельный «корпоративный файловый менеджер». Форма входа на ней работает только на стороне клиента (всегда неудачна и ничего не сохраняет). Убедитесь, что файл не пустой:

```bash
wc -c /var/www/fake/index.html    # ожидайте десятки КБ
```

> Здесь подойдёт любой статический HTML. Смысл лишь в том, чтобы корень домена выглядел как обычный, скучный сайт для автоматических сканеров.

---

## 11. Caddyfile (мозг маршрутизации)

Замените `/etc/caddy/Caddyfile` на следующее (подставьте `DOMAIN` и `SECRET_PATH`):

```caddyfile
{
	email you@example.com        # контакт для ACME; установщик подставляет сюда EMAIL
}

# (Опционально) ничего особенного не доверяем; Caddy сам передаёт X-Forwarded-*.
DOMAIN {
	encode zstd gzip

	# Использовать общий сертификат от certbot (его же применяет AdGuard для DoT)
	tls /etc/ssl/adguard/fullchain.pem /etc/ssl/adguard/privkey.pem

	# ---- 1. Публичный эндпоинт DoH (RFC 8484), GET + POST -> AdGuard ----
	handle /dns-query {
		reverse_proxy 127.0.0.1:3000
	}

	# ---- 2. Голый секретный путь -> добавляем слэш на конце ----
	handle SECRET_PATH {
		redir SECRET_PATH/ 302
	}

	# ---- 3. Секретная админка -> AdGuard, префикс срезается на бэкенде,
	#         а корневые абсолютные редиректы снова получают префикс на пути назад ----
	handle SECRET_PATH/* {
		uri strip_prefix SECRET_PATH
		header >Location ^/(.*)$ SECRET_PATH/$1
		reverse_proxy 127.0.0.1:3000
	}

	# ---- 4. Всё остальное -> сайт-приманка ----
	handle {
		root * /var/www/fake
		try_files {path} /index.html
		file_server
	}
}
```

Для эталонного примера две строки с `SECRET_PATH` становятся `/REDACTED_SECRET_PATH`. Конкретно, обработчик 3 выглядит так:

```caddyfile
	handle /REDACTED_SECRET_PATH/* {
		uri strip_prefix /REDACTED_SECRET_PATH
		header >Location ^/(.*)$ /REDACTED_SECRET_PATH/$1
		reverse_proxy 127.0.0.1:3000
	}
```

Проверьте и запустите:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
```

### Как на самом деле работает обработчик 3 (и почему это безопасно)

Приятная часть: **дашборд AdGuard терпим к подпутям**, поэтому прокси со срезанием префикса работает. Это так, потому что интерфейс AdGuard:

- использует **`HashRouter`** (`hashType="noslash"`) — его клиентские маршруты живут в `#fragment` URL, который никогда не отправляется на сервер, поэтому префикс пути для навигации не важен;
- загружает ресурсы по **относительным** путям;
- использует **относительную базу API** (`control`);
- после входа перенаправляет в корень приложения через `pathname.replace("/login.html", "/")` — то есть относительно *текущего* пути, поэтому остаётся внутри секретного префикса.

Caddy срезает `/REDACTED_SECRET_PATH` до того, как запрос доходит до AdGuard, так что AdGuard считает, что он находится в `/`. Когда AdGuard выдаёт редирект `Location:` (например, `302 -> /login.html`), строка

```
header >Location ^/(.*)$ /REDACTED_SECRET_PATH/$1
```

переписывает его в `/REDACTED_SECRET_PATH/login.html`, чтобы браузер остался внутри префикса. (`header >Field <regex> <replacement>` — это отложенная замена заголовка ответа по регулярному выражению в Caddy; `>` включает defer, поэтому замена выполняется после того, как прокси запишет свои заголовки.)

> Если вместо этого использовать `handle_path`, Caddy срежет префикс сам — но перезапись `Location` всё равно нужна, иначе редиректы AdGuard выйдут за пределы префикса.

---

## 12. Запуск и проверка

```bash
systemctl restart AdGuardHome
systemctl restart caddy
sleep 3
systemctl is-active caddy AdGuardHome
ss -tlnp | grep -E ':(80|443|853|3000)\b'
```

Ожидаемые слушатели:

```
0.0.0.0:80      caddy            (редирект -> https)
0.0.0.0:443     caddy
*:853           AdGuardHome
127.0.0.1:3000  AdGuardHome      (только localhost!)
```

Теперь проверьте **с другой машины** (или через публичный интернет):

```bash
# 1) DoH разрешает имя (wire-формат). Ожидайте HTTP 200 + DNS-ответ.
Q=$(printf '\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
curl -s "https://$DOMAIN/dns-query?dns=$Q" -H 'accept: application/dns-message' \
  | xxd | head -3

# 2) Сайт-приманка. Ожидайте 200 + поддельный HTML.
curl -sI "https://$DOMAIN/" | head -1
curl -s  "https://$DOMAIN/" | grep -io '<title>[^<]*</title>' | head -1

# 3) Случайный путь тоже отдаёт приманку (catch-all). Ожидайте 200.
curl -sI "https://$DOMAIN/some/random/path" | head -1

# 4) Секретный путь админки. Ожидайте 302 (редирект внутрь страницы входа с префиксом).
curl -sI "https://$DOMAIN$SECRET_PATH/" | head -1

# 5) DoT. Ожидайте, что субъект/имя сертификата совпадает с DOMAIN и проверка проходит.
echo | openssl s_client -connect $DOMAIN:853 -servername $DOMAIN 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

Для настоящей сквозной проверки разрешения имён используйте скрипт из приложения §17.1 и убедитесь, что:
- обычный домен разрешается (rcode 0),
- домен, который должен блокироваться (например, `doubleclick.net` со штатным фильтром AdGuard), возвращает `0.0.0.0` / NXDOMAIN.

Наконец, убедитесь, что админка действительно работает через секретную ссылку: откройте `https://$DOMAIN$SECRET_PATH/` в браузере, войдите как `$ADMIN_USER`/`$ADMIN_PASS` и проверьте, что дашборд загружается и `/control/status` отвечает.

---

## 13. Опционально: импорт настроек из другого конфига AdGuard

Если у вас есть существующий `AdGuardHome.yaml` из другого развёртывания и вы хотите перенести его **функциональные** настройки (апстримы, фильтры, правила, лимиты) **без** его домена, TLS-сертификатов, пароля администратора или адресов привязки — объединяйте обдуманно.

**Принцип: начинайте с НОВОГО, заведомо рабочего конфига и копируйте только те значения, которые нужны.** Никогда не начинайте со старого файла (его ключи идентичности/сети/TLS/авторизации затрут новый сервер).

Пример скрипта слияния (запускать на новом сервере; список разрешённых ключей правьте по вкусу):

```python
# merge_adguard.py
import sys, yaml

# новый (целевой) конфиг и старый (источник) конфиг
NEW = '/opt/AdGuardHome/AdGuardHome.yaml'
OLD = '/path/to/old/AdGuardHome.yaml'
OUT = '/tmp/AdGuardHome.merged.yaml'

new = yaml.safe_load(open(NEW))
old = yaml.safe_load(open(OLD))

def take(section, keys):
    """Копирует old[section][k] -> new[section][k] для каждого присутствующего ключа."""
    if section not in old:
        return
    new.setdefault(section, {})
    for k in keys:
        if k in old[section]:
            new[section][k] = old[section][k]

# --- Поведение DNS (безопасно импортировать) ---
take('dns', ['upstream_dns', 'upstream_mode', 'bootstrap_dns', 'fallback_dns',
             'ratelimit', 'ratelimit_subnet_len_ipv4', 'ratelimit_subnet_len_ipv6',
             'cache_size', 'blocked_hosts', 'enable_dnssec', 'upstream_timeout',
             'refuse_any', 'edns_cs_enabled', 'disable_ipv6',
             'dnssec_query_timeout', 'use_private_ptr_resolvers'])
# --- Фильтрация (безопасно импортировать) ---
take('filtering', ['filters', 'whitelist_filters', 'user_rules', 'safe_search',
                   'safe_browsing', 'parental', 'rewrites', 'blocked_services'])
# --- Прочее поведение ---
take('clients', ['runtime_sources'])

# --- СОЗНАТЕЛЬНО НЕ ИМПОРТИРУЕТСЯ (идентичность / сеть / TLS / авторизация) ---
#   users                          -> сохранить новые учётные данные администратора
#   tls.*                          -> сохранить новый домен + пути к сертификатам
#   http.address / http.doh.*      -> сохранить 127.0.0.1:3000 + insecure_enabled
#   dns.bind_hosts / dns.port / dns.serve_plain_dns
#   schema_version                 -> сохранить зафиксированным под текущий бинарник

yaml.safe_dump(new, open(OUT, 'w'), sort_keys=False, allow_unicode=True)
print('записано', OUT)
```

Затем разверните его **безопасно** (см. мину в §14 про `--check-config`):

```bash
cp -a /opt/AdGuardHome/AdGuardHome.yaml /root/AdGuardHome.yaml.bak.$(date +%s)
systemctl stop AdGuardHome
# ждём, пока не станет inactive (AdGuard может тратить несколько секунд на сброс состояния)
for i in $(seq 1 60); do systemctl is-active --quiet AdGuardHome || break; sleep 1; done
cp -a /tmp/AdGuardHome.merged.yaml /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
sleep 5
systemctl is-active AdGuardHome && echo OK || { echo "НЕУДАЧА -> откат";
  systemctl stop AdGuardHome
  cp -a /root/AdGuardHome.yaml.bak.* /opt/AdGuardHome/AdGuardHome.yaml
  systemctl start AdGuardHome; }
```

**Правила безопасного слияния:**

- После слияния сравните результат с новым конфигом и убедитесь, что **сохранённые** ключи не изменились: `users[0].password`, `tls.server_name`, `tls.certificate_path`, `tls.private_key_path`, `tls.port_https` (0), `tls.port_dns_over_quic` (0), `tls.port_dns_over_tls` (853), `http.address` (`127.0.0.1:3000`), `http.doh.insecure_enabled` (true), `dns.serve_plain_dns` (false), `schema_version`.
- Конфиг из *более старого* AdGuard может ссылаться на ключи, которые новый бинарник переименовал — проверяйте структурно (YAML загружается, ключи выглядят разумно), а не доверяя слепому `--check-config`.
- Импортированные `user_rules` часто содержат `$client='<какой-то старый IP>'`. Эти IP ничего не значат на новом сервере — просмотрите и обновите/удалите их.

---

## 14. Подводные камни и мины

Это ровно те ловушки, что встретились при сборке эталонного развёртывания. Прочтите их до развёртывания.

1. **`AdGuardHome --check-config` на этой версии — ловушка.**
   В AdGuard Home ~v0.107.x команда `AdGuardHome --check-config -c <file>` может запустить **полноценный экземпляр, который никогда не завершается**, заняв `:3000` и заставив systemd-юнит зациклиться в `activating / auto-restart` (потому что порт занят). Если видите юнит, застрявший в `activating`, поищите зависший процесс:
   ```bash
   ps -eo pid,ppid,etime,cmd | grep '[A]dGuardHome'
   ```
   Убейте «завихрение» и запустите сервис обычным образом. **Для проверки конфигов делайте это структурно (YAML загружается, сравнение с заведомо рабочим файлом) и развёртывайте через `stop -> swap -> start` с копией для отката.** Не полагайтесь на `--check-config` на живом сервере.
   Также помните: запуск `--check-config`, пока сервис *работает*, падает с безобидной ошибкой `session_storage: opening db ... timeout` (работающий процесс держит блокировку BoltDB) — это ложное срабатывание.

2. **`http.doh.insecure_enabled: true` обязательно** за реверс-прокси, завершающим TLS. Забудьте — и `/dns-query` сломается, хотя прокси выглядит правильно.

3. **Фиксируйте `schema_version`.** Запись конфига с более низким `schema_version` и перезапуск запускают миграцию, которая может вложить `bootstrap_dns` (непарсибельно) и молча отбросить `http.doh.insecure_enabled`. См. §9.

4. **`tls.port_https: 0`** — оставляйте собственный HTTPS-слушатель AdGuard выключенным. Если поставить 443, он столкнётся с Caddy, и админка может стать доступной напрямую.

5. **`http.address` должен быть `127.0.0.1:3000`.** Всё вроде `0.0.0.0:3000` выставляет админку наружу. Если `ss` когда-либо покажет `*:3000` для AdGuard, считайте это ошибкой конфигурации (в эталонном случае это был зависший процесс `--check-config`, а не сервис).

6. **Не запускайте `certbot renew --dry-run`** при установленном deploy-хуке — staging-сертификат затрёт боевой. Сначала отключите хук, если dry-run действительно нужен.

7. **DoT должен быть публично доступен на `:853`** — проверьте через `openssl s_client` извне. Если таймаут — проверьте и UFW, и файрвол облачного провайдера.

8. **AdGuard ограничивает частоту неудачных входов** (HTTP `429` + `Retry-After`). Не скриптуйте повторные попытки `/control/login`. Для проверки войдите **один раз**, сохраните cookie сессии и переиспользуйте её.

9. **Именно hash-маршрутизация делает трюк с префиксом рабочим** — если в будущей версии AdGuard дашборд перейдёт на history/path-роутер, схема с секретным префиксом может сломаться. Перепроверяйте поток входа в админку после обновлений AdGuard.

10. **Блоки `handle` в Caddy вычисляются в порядке записи** внутри блока сайта. Держите `/dns-query` и `SECRET_PATH/*` перед catch-all `handle {}`.

---

## 15. Укрепление и обслуживание

**Перейдите на ключи SSH и отключите пароли:**

```bash
# на сервере, после установки вашего публичного ключа в /root/.ssh/authorized_keys
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh
```

**Автоматические обновления безопасности:**

```bash
apt -y install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades   # включить
```

**fail2ban** для защиты от перебора SSH:

```bash
apt -y install fail2ban
systemctl enable --now fail2ban
```

**Запуск AdGuard не от root (опционально, продвинуто).** Штатный юнит запускает AdGuard от root, чтобы он мог занять `:853`. Если вы предпочитаете выделенного пользователя, дайте ему `CAP_NET_BIND_SERVICE` и укажите этого пользователя в юните; убедитесь, что он может читать `/etc/ssl/adguard/privkey.pem` (добавьте его в группу `caddy` или скорректируйте права в deploy-хуке).

**Проверка продления** (наглядно, без разрушительных действий):

```bash
certbot certificates
systemctl list-timers | grep certbot
```

**Держите блок-листы свежими:** AdGuard обновляет включённые фильтры по своему расписанию (по умолчанию ~24 ч). Проверяйте в интерфейсе в разделе *Filters* или через API (`/control/filtering/status` → `last_updated` у каждого фильтра).

**Бэкапы**, которые стоит делать (они небольшие):

```bash
tar czf /root/adguard-etc-$(date +%F).tgz \
  /opt/AdGuardHome/AdGuardHome.yaml \
  /etc/caddy/Caddyfile \
  /var/www/fake/index.html \
  /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
```

---

## Приложение A: полное дерево файлов

```
/etc/caddy/Caddyfile                                   виртхост Caddy: TLS, прокси DoH, секретный путь админки, приманка
/var/www/fake/index.html                               HTML сайта-приманки
/opt/AdGuardHome/AdGuardHome                           бинарник AdGuard
/opt/AdGuardHome/AdGuardHome.yaml                      конфиг AdGuard (schema_version зафиксирована)
/opt/AdGuardHome/data/                                 рабочее состояние AdGuard (журнал запросов, статистика, sessions DB)
/etc/systemd/system/AdGuardHome.service                юнит AdGuard
/etc/systemd/system/caddy.service                      юнит Caddy (из пакета)
/etc/ssl/adguard/fullchain.pem                         общий сертификат (root:root 644)
/etc/ssl/adguard/privkey.pem                           общий ключ  (root:caddy 640)
/etc/letsencrypt/live/<DOMAIN>/                        боевые сертификаты certbot (симлинки)
/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh   копирует сертификаты + перезагружает сервисы
```

Включённые сервисы: `caddy`, `AdGuardHome`, `certbot.timer`, `ufw`, (опционально `fail2ban`).

---

## Приложение B: шпаргалка по проверке

### B.1 Настоящее разрешение DoH + тест блокировки

```python
# doh_check.py  -- запускать на любой машине с python3 (только стандартная библиотека)
import socket, struct, ssl, urllib.request
URL = 'https://DNS.EXAMPLE.COM/dns-query'
CTX = ssl.create_default_context()

def q(name):
    hdr = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
    body = b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\x00\x01\x00\x01'
    req = urllib.request.Request(URL, data=hdr + body,
          headers={'content-type': 'application/dns-message', 'accept': 'application/dns-message'})
    r = urllib.request.urlopen(req, context=CTX, timeout=15).read()
    flags, an = struct.unpack('>HH', r[2:6])[0], struct.unpack('>H', r[6:8])[0]
    i = 12
    while r[i] != 0: i += r[i] + 1
    i += 5
    out = []
    for _ in range(an):
        i += 2
        t, _, _, n = struct.unpack('>HHIH', r[i:i+10]); i += 10
        d = r[i:i+n]; i += n
        out.append(socket.inet_ntoa(d) if t == 1 and n == 4 else f'type{t}')
    return flags & 0xF, out

for d in ['example.com', 'cloudflare.com', 'doubleclick.net']:
    print(d, q(d))
```

Ожидайте rcode `0` и настоящие IP для первых двух; `0.0.0.0` (или NXDOMAIN) для `doubleclick.net`, когда включён блок-лист.

### B.2 Быстрые проверки в оболочке

```bash
curl -sI "https://$DOMAIN/"                                   # 200, приманка
curl -sI "https://$DOMAIN/dns-query"                          # любой ответ (405/400 нормально; доказывает маршрутизацию)
curl -sI "https://$DOMAIN$SECRET_PATH/"                       # 302 внутрь страницы входа с префиксом
openssl s_client -connect $DOMAIN:853 -servername $DOMAIN </dev/null 2>/dev/null | openssl x509 -noout -dates
ss -tlnp | grep -E ':(80|443|853|3000)\b'                     # 3000 должен быть 127.0.0.1
```

### B.3 Проверка через API админки (один вход, переиспользование cookie)

```bash
SP="/a1b2c3d4e5f60718"; H="https://$DOMAIN"
curl -s -c /tmp/cj -o /dev/null -w 'login: %{http_code}\n' \
  -X POST "$H$SP/control/login" -H 'content-type: application/json' \
  -d '{"name":"admin","password":"YOURPASS"}'
curl -s -b /tmp/cj "$H$SP/control/status" | head -c 200; echo
curl -s -b /tmp/cj "$H$SP/control/filtering/status" | head -c 300; echo
rm -f /tmp/cj
```

---

## Приложение C: откат / удаление

**Откатить конфиг AdGuard к последней рабочей копии:**

```bash
systemctl stop AdGuardHome
cp -a /root/AdGuardHome.yaml.bak.<timestamp> /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
```

**Снести всё целиком (в обратном порядке):**

```bash
systemctl disable --now caddy
caddy stop 2>/dev/null || true

/opt/AdGuardHome/AdGuardHome -s uninstall   # удаляет юнит AdGuard (режим установки)
rm -rf /opt/AdGuardHome

apt -y remove --purge caddy certbot
rm -rf /var/www/fake /etc/ssl/adguard
rm -f /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh

# опционально: отозвать/удалить сертификат
# certbot delete --cert-name "$DOMAIN"

# файрвол назад к значениям по умолчанию
ufw reset
```

---

*Конец руководства.*
