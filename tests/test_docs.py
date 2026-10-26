"""Parse documented agent commands without executing any installation commands."""
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = ("README.md", "README.en.md", "docs/AGENT_INSTALL.md", "docs/TROUBLESHOOTING.md")


class DocumentationTests(unittest.TestCase):
    def test_bash_examples_parse(self):
        for filename in DOCUMENTS:
            source = (ROOT / filename).read_text()
            for index, script in enumerate(re.findall(r"```bash\n(.*?)```", source, re.S), 1):
                with self.subTest(document=filename, block=index):
                    result = subprocess.run(
                        ["bash", "-n"], input=script, text=True,
                        capture_output=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_relative_links_resolve(self):
        for filename in DOCUMENTS:
            path = ROOT / filename
            for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
                if "://" in target or target.startswith("#"):
                    continue
                with self.subTest(document=filename, target=target):
                    self.assertTrue((path.parent / target.split("#", 1)[0]).is_file())


if __name__ == "__main__":
    unittest.main()
