"""Isolated shell tests: no real service, sudo, Odoo or system config access."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT_DIR = Path(os.environ.get("SCRIPT_DIR", Path(__file__).parent))
SOURCE_SCRIPT_DIR = Path(os.environ.get(
    "SOURCE_SCRIPT_DIR", "/home/calic/odoo-local/odoo_deployment_scripts"))


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="install-test-", dir=SCRIPT_DIR)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALL_LOG=str(self.log), ODOO_STATUS="0", START_STATUS="0")
        self.write(self.bin / "sudo", '''#!/bin/bash
printf 'sudo %s\\n' "$*" >> "$CALL_LOG"
if [ "$1" = -u ]; then shift 2; fi
exec "$@"
''', executable=True)
        self.write(self.bin / "systemctl", '''#!/bin/bash
printf 'systemctl %s\\n' "$*" >> "$CALL_LOG"
if [ "$1" = start ]; then exit "${START_STATUS:-0}"; fi
''', executable=True)
        home = self.root / "home"
        self.write(home / "venv/bin/python3", '''#!/bin/bash
printf 'odoo %s\\n' "$*" >> "$CALL_LOG"
exit "${ODOO_STATUS:-0}"
''', executable=True)
        self.write(home / "odoo/odoo-bin", "# mock Odoo\n")
        config = self.root / "etc/instance.conf"
        self.write(config, "[options]\n")
        self.write(self.root / "etc/odoo_deploy/staging18.env",
                   f"DB_NAME=example\nOE_HOME={shlex.quote(str(home))}\n"
                   "OE_USER=odoo\nSERVICE_NAME=odoo-test\n")
        self.write(self.root / "etc/systemd/system/odoo-test.service",
                   f"ExecStart=python odoo-bin --config={config}\n")
        for name in ("odooctl.sh", "odoo-install-modules.sh", "odoo-update-modules.sh"):
            source = SCRIPT_DIR / name
            if not source.exists():
                source = SOURCE_SCRIPT_DIR / name
            # Redirect all system path lookups only in the disposable test copy.
            content = source.read_text()
            for directory in ("/usr/lib/systemd", "/lib/systemd", "/etc/"):
                content = content.replace(directory, str(self.root) + directory)
            self.write(self.root / name, content)

    @staticmethod
    def write(path, content, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if executable:
            path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(["bash", str(self.root / name), *args],
                              env=self.env, text=True, capture_output=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_install_uses_i_and_restarts(self):
        result = self.run_script("odooctl.sh", "install", "staging18", "sale,stock")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        odoo = next(line for line in calls if line.startswith("odoo "))
        self.assertIn(" -i sale,stock --stop-after-init", odoo)
        self.assertNotIn(" -u ", odoo)
        self.assertIn(" -d example ", odoo)
        self.assertEqual([c for c in calls if c.startswith("systemctl ")],
                         ["systemctl stop odoo-test", "systemctl start odoo-test"])
        self.assertIn("sudo -u odoo ", "\n".join(calls))
        if os.geteuid() != 0:
            self.assertTrue(calls[0].startswith("sudo bash "))

    def test_modules_keeps_u(self):
        result = self.run_script("odooctl.sh", "modules", "staging18", "sale")
        self.assertEqual(result.returncode, 0, result.stderr)
        odoo = next(c for c in self.calls() if c.startswith("odoo "))
        self.assertIn(" -u sale --stop-after-init", odoo)
        self.assertNotIn(" -i ", odoo)

    def test_failed_install_restarts_and_propagates_status(self):
        self.env["ODOO_STATUS"] = "23"
        result = self.run_script("odooctl.sh", "install", "staging18", "sale")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.calls()[-1], "systemctl start odoo-test")
        self.assertNotIn("installed successfully", result.stdout)

    def test_failed_restart_keeps_install_failure(self):
        self.env.update(ODOO_STATUS="23", START_STATUS="7")
        result = self.run_script("odoo-install-modules.sh", "staging18", "sale")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.calls()[-1], "systemctl start odoo-test")

    def test_missing_env_stops_before_service_calls(self):
        result = self.run_script("odoo-install-modules.sh", "missing", "sale")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_usage_and_describe(self):
        result = self.run_script("odooctl.sh", "help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("install <instance> <m1,m2>", result.stdout)
        for command, flag in (("install", "-i"), ("modules", "-u")):
            result = self.run_script("odooctl.sh", "describe", command)
            self.assertEqual(result.returncode, 0)
            self.assertIn(f"odoo-bin {flag}", result.stdout)
        for command in ("deploy", "git-update", "remove", "backup", "restore",
                        "backup-restore", "backup-restore-env", "neutralize",
                        "shell", "venv", "mini-deploy"):
            result = self.run_script("odooctl.sh", "describe", command)
            self.assertEqual(result.returncode, 0)
            self.assertTrue(result.stdout.startswith(f"{command}:"))

    def test_existing_routing_forwards_arguments(self):
        routes = {"deploy": "deploy_odoo.sh", "git-update": "odoo-git-update.sh",
                  "remove": "odoo-remove-instance.sh", "backup": "odoo-db-archive.sh",
                  "restore": "odoo-db-archive.sh", "backup-restore": "odoo-backup-restore.sh",
                  "backup-restore-env": "odoo-sync-env-create.sh", "shell": "odoo-shell.sh",
                  "venv": "odoo-venv.sh", "mini-deploy": "odoo_deploy_mini.sh"}
        for command, helper in routes.items():
            self.write(self.root / helper, "#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
            result = self.run_script("odooctl.sh", command, "argument with spaces", "--flag")
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = ["argument with spaces", "--flag"]
            if command in ("backup", "restore"):
                expected.insert(0, command)
            self.assertEqual(result.stdout.splitlines(), expected)


if __name__ == "__main__":
    unittest.main()
