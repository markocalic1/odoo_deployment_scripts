"""Local regressions for service-user Git failures and read-only syntax checks."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import test_git_submodules as fixtures


class GitFailureTests(unittest.TestCase):
    def run_git(self, script, command, *, root=True, root_status=9, enabled=True):
        source = (ROOT / script).read_text()
        function = source[source.index('run_repo_git() {'):
                          source.index('detect_odoo_config() {')]
        # Simulate effective UID without requiring privilege or touching root's HOME.
        function = function.replace('[ "$EUID" -eq 0 ]', 'true' if root else 'false')
        function = function.replace('[ "$(id -u)" -eq 0 ]', 'true' if root else 'false')
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            env = dict(os.environ, MOCK_LOG=str(work / 'calls'),
                       PARTIAL_WRITE=str(work / 'partial'), OE_USER='service-user',
                       REPO_PATH=directory, PROJECT_DIR=directory,
                       DEPLOY_LOG=os.devnull, LOG_FILE=os.devnull,
                       FIX_REPO_PERMS='true' if enabled else 'false',
                       ROOT_GIT_STATUS=str(root_status))
            result = subprocess.run([
                'bash', '-c',
                'log() { :; }; '
                'sudo() { printf "service:%s\\n" "$*" >> "$MOCK_LOG"; '
                'printf "partial write\\n" >> "$PARTIAL_WRITE"; return 8; }; '
                'git() { printf "root:%s\\n" "$*" >> "$MOCK_LOG"; '
                'return "$ROOT_GIT_STATUS"; }; '
                'chown() { :; }; '
                'prepare_repo_permissions() { :; }; '
                + function + '\nrun_repo_git "$@"', 'git-failure-test', *command,
            ], env=env, capture_output=True, text=True, timeout=10)
            calls = (work / 'calls').read_text().splitlines()
            partial = (work / 'partial').read_text().splitlines()
        return result, calls, partial

    def test_failed_mutations_are_not_retried_after_partial_write(self):
        commands = (('pull', 'origin', 'main'), ('merge', '--ff-only', 'origin/main'),
                    ('reset', '--hard', 'origin/main'), ('stash', 'push'),
                    ('stash', 'pop'), ('diff', '--quiet'))
        for script in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            for command in commands:
                with self.subTest(script=script, command=command):
                    result, calls, partial = self.run_git(script, command)
                    self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
                    self.assertEqual(len(calls), 1, calls)
                    self.assertTrue(calls[0].startswith('service:'), calls)
                    self.assertEqual(partial, ['partial write'])

    def test_nonroot_failure_preserves_service_status(self):
        for script in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            with self.subTest(script=script):
                result, calls, _ = self.run_git(script, ('fetch', '--all'), root=False)
                self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1, calls)

    def test_root_fetch_fallback_preserves_its_status(self):
        for script in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            for status in (0, 9):
                with self.subTest(script=script, status=status):
                    result, calls, _ = self.run_git(script, ('fetch', '--all'),
                                                    root_status=status)
                    self.assertEqual(result.returncode, status,
                                     result.stdout + result.stderr)
                    self.assertEqual(len(calls), 2, calls)
                    self.assertTrue(calls[0].startswith('service:'), calls)
                    self.assertEqual(calls[1], 'root:fetch --all')

    def test_disabled_permission_repair_disables_root_fetch_fallback(self):
        for script in ('deploy_odoo.sh', 'odoo-git-update.sh'):
            with self.subTest(script=script):
                result, calls, _ = self.run_git(script, ('fetch', '--all'), enabled=False)
                self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1, calls)


class PermissionPreparationTests(unittest.TestCase):
    def prepare(self, *, enabled=True, root=True, chown_status=0, writable=True):
        source = (ROOT / 'odoo-git-common.sh').read_text()
        source = source.replace('[ "$EUID" -eq 0 ]', 'true' if root else 'false')
        source = source.replace('[ "$(id -u)" -eq 0 ]', 'true' if root else 'false')
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / 'repo with spaces'
            (repo / '.git').mkdir(parents=True)
            # A writable .git directory alone must not bypass whole-tree repair.
            (repo / 'addons').mkdir()
            (repo / 'addons' / 'owned-by-another-user.py').write_text('value = 1\n')
            env = dict(os.environ, OE_USER='service-user',
                       FIX_REPO_PERMS='true' if enabled else 'false',
                       MOCK_LOG=str(Path(directory) / 'ownership.log'),
                       CHOWN_STATUS=str(chown_status),
                       WRITE_STATUS='0' if writable else '1',
                       DEPLOY_LOG=os.devnull, LOG_FILE=os.devnull)
            result = subprocess.run([
                'bash', '-c',
                'log() { :; }; sudo() { return "$WRITE_STATUS"; }; '
                'chown() { printf "%s\\n" "$@" >> "$MOCK_LOG"; '
                'return "$CHOWN_STATUS"; }; '
                + source + '\nprepare_repo_permissions "$1"', 'permissions-test', str(repo),
            ], env=env, capture_output=True, text=True, timeout=10)
            log = Path(env['MOCK_LOG'])
            arguments = log.read_text().splitlines() if log.exists() else []
            return result, arguments, str(repo)

    def test_root_repairs_entire_tree_even_when_git_directory_is_writable(self):
        result, arguments, repo = self.prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('-R', arguments)
        self.assertIn('service-user:service-user', arguments)
        self.assertIn(repo, arguments)

    def test_explicit_disable_and_nonroot_do_not_change_ownership(self):
        for options in ({'enabled': False}, {'root': False}):
            with self.subTest(options=options):
                result, arguments, _ = self.prepare(**options)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(arguments, [])

    def test_ownership_repair_failure_is_not_hidden(self):
        result, arguments, _ = self.prepare(chown_status=7)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(arguments)

    def test_disabled_repair_rejects_unwritable_repository_without_chown(self):
        result, arguments, _ = self.prepare(enabled=False, writable=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(arguments, [])


class PythonSyntaxTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GitSubmoduleTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.helper = ROOT / 'odoo-check-python.py'

    def check_syntax(self, repo=None):
        self.assertTrue(self.helper.is_file(), f'Helper missing: {self.helper}')
        return subprocess.run([sys.executable, '-B', '-', str(repo or self.fixture.repo)],
                              input=self.helper.read_bytes(), env=self.fixture.env,
                              capture_output=True, timeout=10)

    def test_read_only_tracked_python_creates_no_cache(self):
        f = self.fixture
        f.commit_file(f.repo, 'valid.py', 'answer = 42\n')
        tracked = f.repo / 'valid.py'
        tracked.chmod(0o444)
        f.repo.chmod(0o555)
        try:
            result = self.check_syntax()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse(list(f.repo.rglob('__pycache__')))
            self.assertFalse(list(f.repo.rglob('*.pyc')))
        finally:
            f.repo.chmod(0o755)
            tracked.chmod(0o644)

    def test_invalid_tracked_python_reports_filename_and_line(self):
        f = self.fixture
        f.commit_file(f.repo, 'broken.py', 'answer = 42\nif True\n    pass\n')
        result = self.check_syntax()
        self.assertNotEqual(result.returncode, 0)
        diagnostic = result.stderr.decode()
        self.assertIn('broken.py', diagnostic)
        self.assertIn('line 2', diagnostic)
        self.assertIn('SyntaxError', diagnostic)
        self.assertFalse(list(f.repo.rglob('__pycache__')))

    def test_untracked_invalid_python_is_ignored(self):
        f = self.fixture
        f.commit_file(f.repo, 'valid.py', 'answer = 42\n')
        (f.repo / 'untracked.py').write_text('if True\n')
        result = self.check_syntax()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(list(f.repo.rglob('__pycache__')))

    def test_initialized_submodule_tracked_python_is_checked(self):
        f = self.fixture
        f.commit_file(f.remote, 'module code.py', 'if True\n')
        f.add_module()
        clone = f.clone_parent()
        f.helper('sync_repo_submodules', repo=clone)
        result = self.check_syntax(clone)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('module code.py', result.stderr.decode())
        self.assertIn('SyntaxError', result.stderr.decode())
        self.assertFalse(list(clone.rglob('__pycache__')))


if __name__ == '__main__':
    unittest.main()
