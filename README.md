**Русский** · [English](README.en.md)

# AdGuard Home + фейковый веб-сайт

Ванлайн установщик, устанавливающий публичный
**резолвер DNS-over-HTTPS (DoH) + DNS-over-TLS (DoT)** на базе AdGuard Home,
где корень домена отдаёт фейковый сайт-заглушку, а админ-панель AdGuard
спрятана за длинным секретным путём.

## Что вы получаете на выходе

- Публичные резолверы по адресу `https://<domain>/dns-query` и `tls://<domain>:853`. Без обычного DNS.
- Фейковый сайт-заглушка на домене, чтобы сканеры не видели реальную админ-панель AdGuard.
- Админ-панель AdGuard — только по адресу `https://<domain>/<secret>/`
- Один сертификат Let's Encrypt, общий для Caddy (на `:443`) и AdGuard (на `:853`).

## Простая установка

### 1) Пререквизиты

1. **VPS** под Debian 12/13 или Ubuntu 22.04/24.04 с публичным IPv4 (на других не тестировалось)
2. **Доступ root**
3. **Имя домена, чья A (AAAA)-запись уже указывает на IP VPS.** Установщик прекратит работу, если DNS не разрешается на этот сервер. Настройте его у регистратора/DNS-провайдера до запуска.
4. **Входящие порты 80, 443, 853 доступны** из интернета — проверьте файрвол провайдера **и** облака.
5. **Порты 80/443/853 должны быть свободны.**
6. **Знайте свои остальные слушающие порты** (SSH = 22 по умолчанию, VPN и т. п.) — установщик покажет каждый слушающий сокет и спросит перед включением файрвола с политикой deny по умолчанию. Актуально, если на VPS установлена, например, Amnezia WG.

### 2) Запустите команду

```bash
curl -fsSL https://raw.githubusercontent.com/skarusto/adguard-stealth-dns/main/install.sh | sudo bash
```

Локальная установка:

```bash
git clone https://github.com/skarusto/adguard-stealth-dns.git
cd adguard-stealth-dns
sudo ./install.sh
```

### 3) Что делает скрипт установки

| Шаг | Что |
|---|---|
| 00-preflight | ОС, интернет, DNS указывает на этот сервер, нужные порты свободны |
| 10-base | пакеты apt, часовой пояс |
| 20-firewall | жёсткий UFW (SSH + 80 + 443 + 853) |
| 30-caddy | установка Caddy, остановка для проверки на порту 80 |
| 40-cert | certbot (standalone) + общий сертификат + deploy-хук |
| 50-adguard | AdGuard Home из официального установщика + патчинг конфига |
| 60-decoy | установка HTML фейкового сайта (копия из репозитория по умолчанию) |
| 70-caddyfile | генерация + проверка + запуск виртхоста Caddy |
| 80-verify | smoke-тесты |

Установщик задаст 4 вопроса (домен, email, имя администратора, пароль —
секретный путь сгенерирует сам) и сохранит ответы в `deploy.env`
(mode `0600`, **храните приватно**). Где лежит этот файл — зависит от способа
запуска:

- **однострочник (`curl … | sudo bash`)** — `/etc/adguard-deploy/deploy.env`:
  bootstrap работает из временного каталога в `/tmp`, поэтому конфиг сохраняется
  по стабильному пути — именно это позволяет повторным запускам сохранять тот же
  секретный путь.
- **git clone (`sudo ./install.sh`)** — `deploy.env` рядом с `install.sh`.

**В конце** установщик выведет:
```
Admin URL : https://<domain>/<secret>/
DoH URL   : https://<domain>/dns-query
DoT host  : tls://<domain>:853
```

Сохраните секретный путь в менеджер паролей.

## Установка через ИИ-агента

AI-агенты (Codex, OpenCode, Claude Code, …) должны руководствоваться документом
[`docs/AGENT_INSTALL.md`](docs/AGENT_INSTALL.md), а не этим разделом. Он написан для агента,
который выполняет установку **по SSH с рабочей станции**, и описывает:

- неинтерактивный контракт: `DOMAIN`, `EMAIL`, `ADMIN_PASS` кладутся в `deploy.env`
  (mode `600`), затем `./install.sh --yes` **без TTY** (`ssh -T`, `setsid … </dev/null`);
  TTY плюс отсутствующая переменная — и установщик навсегда зависает на вопросе;
- почему **код выхода 0 не доказывает успех** — обязательно разбирайте строку
  `Smoke tests: N passed, 0 failed.` из шага `80-verify`;
- SSH-гейт префлайта и то, что нужно согласовать с человеком **до** работы с сервером
  (DNS, доступность порта 80 извне, риск отрезать UFW свой же SSH, секреты никогда в `argv`);
- внешнюю проверку (заглушка `200`, секретный путь `302`, DoH, DoT), таблицу
  «симптом → причина → исправление» и жёсткие запреты (`certbot renew --dry-run`,
  `AdGuardHome --check-config`, раскрытие `:3000`, …).

Пример запуска из агента:

```bash
VPS=203.0.113.10
ssh -T root@$VPS 'git clone --depth 1 https://github.com/skarusto/adguard-stealth-dns.git /root/adguard-stealth-dns'
# затем создайте /root/adguard-stealth-dns/deploy.env (DOMAIN, EMAIL, ADMIN_PASS), chmod 600, и:
ssh -T root@$VPS 'cd /root/adguard-stealth-dns && setsid ./install.sh --yes </dev/null >/tmp/agent-install.out 2>&1; echo EXIT=$?'
```

## Сценарии использования

```bash
# интерактивно (спросит всё)
sudo ./install.sh
sudo ./install.sh -y                   # принять значения по умолчанию (только если deploy.env уже есть)
sudo ./install.sh --yes                # то же самое
sudo ./install.sh --config ./prod.env  # использовать конкретный файл конфигурации
sudo ./install.sh --force              # повторить все шаги
sudo ./install.sh --only 50-adguard    # выполнить один шаг (неизвестные имена отклоняются)
sudo ./install.sh --uninstall          # удалить всё
```

## Что оказывается установлено

- `/opt/AdGuardHome/AdGuardHome.yaml` — конфиг AdGuard (schema_version зафиксирована)
- `/etc/caddy/Caddyfile` — виртхост Caddy
- `/var/www/fake/index.html` — фейковый одностраничный сайт-заглушка. Можете заменить index.html на любой другой собственный.
- `/etc/ssl/adguard/{fullchain,privkey}.pem` — общий сертификат под управлением deploy-хука certbot
- `/etc/systemd/system/AdGuardHome.service` — детерминированный юнит (работает от root, чтобы занять `:853`)

Сервисы включены: `caddy`, `AdGuardHome`, `certbot.timer`, `ufw`. AdGuard
привязывает интерфейс админки/DoH **только** к `127.0.0.1:3000`; обычный
DNS и DoQ отключены; DoT открыт на `:853`.

## Важные замечания

- **Секретный путь — должны знать только вы.** Выбирайте длинное непредсказуемое значение (установщик генерирует путь из 16 байт / 32 hex-символов по умолчанию) и никогда и нигде не публикуйте его.
- **Не запускайте `certbot renew --dry-run`** при установленном deploy-хуке: хук скопирует *staging*-сертификат на место. Сначала отключите хук.
- **UFW по умолчанию закрывает всё.** Добавляйте порты VPN/приложений через переменную окружения `EXTRA_ALLOW` (например `EXTRA_ALLOW="51820/udp 64672/udp"`).
- **VPN-форвардинг — только по желанию.** Шаг файрвола не трогает `DEFAULT_FORWARD_POLICY` в `/etc/default/ufw`, если не задать `VPN_FORWARDING=yes` (нужно, только если сервер реально маршрутизирует VPN).
- **`SKIP_FIREWALL=yes` опасен на сервере, доступном из интернета.** Пока шаг `50-adguard` не пропатчит конфиг, мастер первичной настройки AdGuard может ненадолго слушать `0.0.0.0:3000`; держите файрвол включённым (или иначе закройте `:3000`) до завершения этого шага.
- **Страница-приманка по умолчанию берётся из репозитория**; задайте `DECOY_URL`, если хотите скачать другую страницу.
- В AdGuard Home ~v0.107.x **`--check-config` может зависнуть** и захватить `:3000` (поэтому шаг `50-adguard` его избегает; конфиги проверяются структурно).

## Удаление

Выполните `sudo ./install.sh --uninstall`. Команда удаляет AdGuard Home, Caddy и
certbot (пакеты), `/var/www/fake`, `/etc/ssl/adguard`, deploy-хук и юнит AdGuard,
apt-репозиторий/ключ Caddy, `deploy.env` (и `repo/deploy.env`, и
`/etc/adguard-deploy/deploy.env`), `/var/log/adguard-deploy.log` и состояние
идемпотентности. Намеренно **остаются**: live-сертификат Let's Encrypt
(`certbot delete --cert-name <domain>`), правила UFW (`ufw reset` — не делайте
это на удалённом сервере без консольного доступа) и DNS-записи A/AAAA,
указывающие на этот сервер.

## Полная документация

- [`docs/MANUAL.ru.md`](docs/MANUAL.ru.md) — на русском
- [`docs/MANUAL.md`](docs/MANUAL.md) — на английском
- [`docs/AGENT_INSTALL.md`](docs/AGENT_INSTALL.md) — руководство для AI-агентов (Codex, OpenCode, …), выполняющих установку по SSH

## Лицензия

[MIT](LICENSE).
 
