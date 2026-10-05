"""Exercise command routing and failures without touching Odoo or PostgreSQL."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch
import importlib.util

SCRIPT = Path(__file__).with_name('odoo-db-archive.sh')


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.log = self.root / 'commands.log'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('systemctl', 'sudo', 'install', 'chmod', 'chown', 'docker'):
            p = self.bin / name
            p.write_text('''#!/bin/bash
printf '%s ' "$(basename "$0")" >> "$MOCK_LOG"
printf '%q ' "$@" >> "$MOCK_LOG"
printf '\\n' >> "$MOCK_LOG"
case "$(basename "$0")" in
 sudo) shift 2; exec "$@" ;;
 install) exec /usr/bin/install "$@" ;;
 systemctl) exit 0 ;;
 docker) [[ " $* " != *" run "* ]] || exit "${MOCK_FAIL:-0}" ;;
esac
''')
            p.chmod(0o755)
        self.odoo = self.bin / 'odoo'
        self.odoo.write_text('''#!/usr/bin/env python3
import os,sys,zipfile
with open(os.environ['MOCK_LOG'], 'a') as f: f.write('odoo ' + ' '.join(sys.argv[1:]) + '\\n')
if os.environ.get('MOCK_FAIL'): sys.exit(int(os.environ['MOCK_FAIL']))
if 'dump' in sys.argv:
 with zipfile.ZipFile(sys.argv[-1], 'w') as z:
  z.writestr('dump.sql', 'SELECT 1;')
  z.writestr('manifest.json', '{}')
''')
        self.odoo.chmod(0o755)
        self.config = self.root / 'odoo.conf'
        self.config.touch()
        self.env_file = self.root / 'target.env'
        self.base = (f'DB_NAME=target\nOE_HOME="{self.root}"\nOE_USER={os.getuid()}\n'
                     f'ODOO_BIN="{self.odoo}"\nCONFIG_PATH="{self.config}"\n')
        self.env_file.write_text(self.base + 'ENVIRONMENT=local\n')
        self.zip = self.root / 'backup.zip'
        with zipfile.ZipFile(self.zip, 'w') as z:
            z.writestr('dump.sql', 'SELECT 1;')
            z.writestr('manifest.json', '{}')

    def run_script(self, action, *args, fail=False):
        env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}',
               'MOCK_LOG': str(self.log)}
        if fail:
            env['MOCK_FAIL'] = '9'
        return subprocess.run(['bash', str(SCRIPT), action, str(self.env_file),
                               *map(str, args)], env=env, text=True, capture_output=True)

    def commands(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_backup_only_creates_zip_and_checksum(self):
        result = self.run_script('backup', self.root / 'output')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.root / 'output').glob('*.zip'))), 1)
        self.assertEqual(len(list((self.root / 'output').glob('*.sha256'))), 1)
        self.assertNotIn(' load ', self.commands())
        self.assertIn('systemctl start odoo', self.commands())

    def test_failed_backup_restarts_service(self):
        result = self.run_script('backup', self.root / 'output', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('systemctl start odoo', self.commands())
        self.assertNotIn('Backup:', result.stdout)

    def test_restore_is_neutralized_and_replace_is_explicit(self):
        result = self.run_script('restore', self.zip)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('load --neutralize target', self.commands())
        self.assertNotIn('--force', self.commands())
        result = self.run_script('restore', self.zip, '--replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('load --neutralize --force target', self.commands())

    def test_production_env_rejected_before_service_stop(self):
        self.env_file.write_text(self.base + 'ENVIRONMENT=production\n')
        result = self.run_script('restore', self.zip, '--replace')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), '')

    def test_corrupt_zip_rejected_before_service_stop(self):
        self.zip.write_text('HTML error page')
        result = self.run_script('restore', self.zip)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), '')

    def test_failed_restore_leaves_service_stopped(self):
        result = self.run_script('restore', self.zip, '--replace', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('systemctl stop odoo', self.commands())
        self.assertNotIn('systemctl start', self.commands())
        self.assertIn('remains stopped', result.stderr)

    def test_checksum_failure_rejected_before_stop(self):
        Path(str(self.zip) + '.sha256').write_text('0' * 64 + '  backup.zip\n')
        result = self.run_script('restore', self.zip)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), '')

    def test_docker_restore_uses_env_and_never_systemctl(self):
        compose = self.root / 'compose.yaml'
        compose.touch()
        self.env_file.write_text(self.base + 'ENVIRONMENT=local\nRUNTIME=docker\n'
                                 f'COMPOSE_FILE="{compose}"\nCOMPOSE_SERVICE=worker\n'
                                 'DATA_DIR=/data\n')
        result = self.run_script('restore', self.zip, '--replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(' stop worker', self.commands())
        self.assertIn('load --neutralize --force target /backup/input.zip', self.commands())
        self.assertIn(' start worker', self.commands())
        self.assertNotIn('systemctl', self.commands())

    def test_repository_docker_env_resolves_existing_target_without_secrets(self):
        spec = importlib.util.spec_from_file_location('docker_target', SCRIPT.with_name('odoo-docker-target.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        docker_env = self.root / 'env'
        docker_env.write_text('POSTGRES_PASSWORD=private-value\n')
        (self.root / 'docker-compose.yaml').touch()
        (self.root / 'etc').mkdir()
        (self.root / 'etc/odoo.conf').write_text('[options]\ndb_name=repo-db\ndata_dir=/opt/project/data\n')
        model = {'services': {'worker': {'environment': {'PASSWORD': 'private-value'},
                                         'volumes': [{'target': '/opt/project/venv'},
                                                     {'target': '/opt/project/data'}]}}}
        response = subprocess.CompletedProcess([], 0, json.dumps(model), '')
        with patch.object(module.subprocess, 'run', return_value=response):
            fields = module.target(docker_env)
        self.assertEqual(fields[1:], ['worker', '/opt/project/venv/bin/odoo',
                                     '/opt/project/etc/odoo.conf', '/opt/project/data', 'repo-db'])
        self.assertNotIn('private-value', str(fields))

    def test_repository_target_rejects_unmounted_filestore(self):
        spec = importlib.util.spec_from_file_location('docker_target', SCRIPT.with_name('odoo-docker-target.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        env = self.root / 'env'
        env.touch()
        (self.root / 'compose.yaml').touch()
        (self.root / 'etc').mkdir()
        (self.root / 'etc/odoo.conf').write_text('[options]\ndb_name=repo-db\ndata_dir=/wrong\n')
        response = subprocess.CompletedProcess([], 0, json.dumps({'services': {
            'worker': {'volumes': [{'target': '/opt/project/venv'}]}}}), '')
        with patch.object(module.subprocess, 'run', return_value=response):
            with self.assertRaisesRegex(ValueError, 'volume target'):
                module.target(env)


if __name__ == '__main__':
    unittest.main()
