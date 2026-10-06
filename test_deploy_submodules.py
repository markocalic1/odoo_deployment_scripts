"""Run deploy flows with local Git and simulated services, pip, HTTP and backups."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import unittest

import test_git_submodules as fixtures

SCRIPTS = Path(__file__).parent


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitSubmoduleTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.root = f.root
        self.env = f.env.copy()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.log'
        mock = '''#!/bin/bash
name=$(basename "$0")
printf '%s ' "$name" >> "$MOCK_LOG"
printf '%q ' "$@" >> "$MOCK_LOG"
printf '\\n' >> "$MOCK_LOG"
case "$name" in
 sudo)
    shift 2
    if [ "${1:-}" = "-H" ]; then shift; fi
    if [ "$1 $2 $3" = "git config --global" ]; then exit 0; fi
    exec "$@" ;;
 curl) printf '%s' "${MOCK_HTTP:-200}"; exit "${MOCK_CURL_EXIT:-0}" ;;
 pip)
    if [ -n "${EXPECT_PIN:-}" ]; then
        [ "$(git -C "$MOCK_REPO/module" rev-parse HEAD)" = "$EXPECT_PIN" ] || exit 9
    fi
    exit "${MOCK_PIP_EXIT:-0}" ;;
 python3)
    if [ "${1:-}" = "-m" ]; then exit 0; fi
    exit "${MOCK_ODOO_EXIT:-0}" ;;
 *) exit 0 ;;
esac
'''
        for name in ('sudo', 'curl', 'systemctl', 'sleep', 'tar', 'chown', 'pg_dump'):
            self.write_executable(self.bin / name, mock)
        self.home = self.root / 'home'
        (self.home / 'venv/bin').mkdir(parents=True)
        (self.home / 'odoo').mkdir()
        (self.home / 'odoo/odoo-bin').touch()
        for name in ('pip', 'python3'):
            self.write_executable(self.home / 'venv/bin' / name, mock)
        self.config = self.root / 'odoo.conf'
        self.config.write_text('[options]\nhttp_port = 8318\n')
        self.env.update(PATH=f'{self.bin}:{os.environ["PATH"]}', MOCK_LOG=str(self.log))
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        shutil.copy(SCRIPTS / 'odoo-git-common.sh', self.scripts)
        # Redirect fixed system paths only. Deploy logic and Git commands stay intact.
        for name in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            source = (SCRIPTS / name).read_text()
            source = source.replace('CONFIG_FILE="/etc/odoo_deploy/${INSTANCE_NAME}.env"',
                                    'CONFIG_FILE="$TEST_ENV_FILE"')
            source = source.replace('config_path=$(detect_odoo_config)',
                                    'config_path="$TEST_ODOO_CONFIG"')
            source = source.replace('CONFIG_PATH=$(detect_odoo_config)',
                                    'CONFIG_PATH="$TEST_ODOO_CONFIG"')
            source = source.replace('CONFIG_PATH=$(detect_odoo_config || true)',
                                    'CONFIG_PATH="$TEST_ODOO_CONFIG"')
            # Avoid changing global safe.directory even in unusual test environments.
            source = source.replace('git config --global --add safe.directory',
                                    'true config --global --add safe.directory')
            (self.scripts / name).write_text(source)

    def write_executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def setup_repo(self, module=True, old_checkout=False):
        f = self.fixture
        f.commit_file(f.repo, 'requirements.txt', 'requests\n')
        before = f.head(f.repo)
        if module:
            f.add_module()
        self.clone = f.clone_parent()
        if old_checkout:
            f.git(self.clone, 'reset', '--hard', before)
        env_file = self.root / 'instance.env'
        values = dict(OE_HOME=str(self.home), OE_USER=str(os.getuid()),
                      REPO_DIR=str(self.clone), BRANCH='main', DB_NAME='target db',
                      SERVICE_NAME='test-odoo', ODOO_PORT='8318')
        env_file.write_text(''.join(f'{k}={shlex.quote(v)}\n' for k, v in values.items()))
        self.env.update(TEST_ENV_FILE=str(env_file), TEST_ODOO_CONFIG=str(self.config),
                        MOCK_REPO=str(self.clone))
        return before

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(self.scripts / name), 'test', *args],
                              cwd=self.clone, env=self.env, text=True,
                              capture_output=True, timeout=30)

    def commands(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_deploy_initializes_before_pip_and_checks_named_database(self):
        self.setup_repo(old_checkout=True)
        self.env['EXPECT_PIN'] = self.fixture.module_old
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('pip install', self.commands())
        self.assertIn('db=target\\ db', self.commands())
        self.assertEqual(self.fixture.head(self.clone / 'module'), self.fixture.module_old)

    def test_health_accepts_redirects_and_rejects_server_error(self):
        before = self.setup_repo(old_checkout=True)
        for status in ('302', '303'):
            with self.subTest(status=status):
                self.env['MOCK_HTTP'] = status
                result = self.run_script('deploy_odoo.sh', '--no-db-backup')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.fixture.helper('restore_repo_commit', before, repo=self.clone)
        self.env['MOCK_HTTP'] = '500'
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.head(self.clone), before)
        self.assertFalse((self.clone / 'module/module.txt').exists())

    def test_failed_submodule_download_rolls_back_before_restart(self):
        before = self.setup_repo(old_checkout=True)
        f = self.fixture
        f.git(f.repo, 'config', '-f', '.gitmodules', 'submodule.module.url',
              str(self.root / 'nonexistent'))
        f.git(f.repo, 'add', '.gitmodules')
        f.git(f.repo, 'commit', '-m', 'broken URL')
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(f.head(self.clone), before)
        self.assertNotIn('systemctl restart', self.commands())
        self.assertNotIn('pip install', self.commands())

    def test_pip_failure_restores_submodules_and_parent(self):
        before = self.setup_repo(old_checkout=True)
        self.env['MOCK_PIP_EXIT'] = '9'
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.head(self.clone), before)
        self.assertFalse((self.clone / 'module/module.txt').exists())
        self.assertNotIn('systemctl restart', self.commands())

    def test_repo_without_submodules_still_deploys(self):
        self.setup_repo(module=False)
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_git_update_initializes_missing_submodule_without_parent_change(self):
        self.setup_repo()
        self.env['EXPECT_PIN'] = self.fixture.module_old
        result = self.run_script('odoo-git-update.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.fixture.head(self.clone / 'module'), self.fixture.module_old)
        self.assertIn('pip install', self.commands())
        self.assertIn('systemctl restart test-odoo', self.commands())

    def test_git_update_honors_module_arguments_even_without_code_changes(self):
        self.setup_repo(module=False)
        result = self.run_script('odoo-git-update.sh', 'update', 'queue_job', '--verbose')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('-u queue_job --stop-after-init', self.commands())

    def test_root_git_fallback_preserves_failure_status(self):
        for name in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            with self.subTest(script=name):
                source = (SCRIPTS / name).read_text()
                function = source[source.index('run_repo_git() {'):source.index('detect_odoo_config() {')]
                # Simulate root eligibility without requiring real root privileges.
                function = function.replace('[ "$EUID" -eq 0 ]', 'true')
                result = subprocess.run([
                    'bash', '-c',
                    'log() { :; }; sudo() { return 8; }; '
                    'git() { return 9; }; chown() { return 0; }; '
                    'DEPLOY_LOG=/dev/null; LOG_FILE=/dev/null; '
                    + function + '\nif run_repo_git fetch; then exit 0; else exit $?; fi',
                ], text=True, capture_output=True)
                self.assertEqual(result.returncode, 9, result.stdout + result.stderr)

    def test_http_port_is_read_from_odoo_config(self):
        self.setup_repo(module=False)
        p = Path(self.env['TEST_ENV_FILE'])
        p.write_text(p.read_text().replace('ODOO_PORT=8318\n', ''))
        result = self.run_script('deploy_odoo.sh', '--no-db-backup')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('http://127.0.0.1:8318/web/login', self.commands())


if __name__ == '__main__':
    unittest.main()
