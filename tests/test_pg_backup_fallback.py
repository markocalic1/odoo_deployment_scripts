import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PgBackupFallback(unittest.TestCase):
    def check_dump(self, script, fail=False):
        source = (ROOT / script).read_text()
        start = source.index('do_pg_dump_as_odoo_user() {')
        end = start + re.search(r'(?m)^\s{0,4}}\s*$', source[start:]).end()
        function = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sudo = root / 'sudo'
            sudo.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
            sudo.chmod(0o755)
            dump = root / 'pg_dump'
            dump.write_text('''#!/usr/bin/env python3
import os,sys
if '-f' in sys.argv:
    print('Cannot open deploy-owned file as database user', file=sys.stderr)
    sys.exit(13)
print('database user diagnostic', file=sys.stderr)
if os.environ.get('FAIL_DUMP') == '1':
    sys.exit(9)
sys.stdout.buffer.write(b'PGDMPbackup-bytes')
''')
            dump.chmod(0o755)
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                       BACKUP_DIR=str(root), DB_NAME='backup_test', OE_USER='odoo',
                       LOG_FILE=str(root/'dump.log'), DEPLOY_LOG=str(root/'dump.log'),
                       FAIL_DUMP='1' if fail else '0')
            result = subprocess.run(['bash', '-c', function+'\ndo_pg_dump_as_odoo_user'],
                                    env=env, capture_output=True)
            self.assertEqual(result.returncode, 9 if fail else 0)
            self.assertEqual((root/'backup_test.dump').read_bytes(), b'' if fail else b'PGDMPbackup-bytes')
            self.assertIn('database user diagnostic', (root/'dump.log').read_text())
            self.assertEqual(result.stdout, b'')

    def test_git_update_dump(self):
        self.check_dump('odoo-git-update.sh')

    def test_git_update_failure_propagates(self):
        self.check_dump('odoo-git-update.sh', fail=True)

    def test_deploy_dump(self):
        self.check_dump('deploy_odoo.sh')

    def test_deploy_failure_propagates(self):
        self.check_dump('deploy_odoo.sh', fail=True)


if __name__ == '__main__':
    unittest.main()
