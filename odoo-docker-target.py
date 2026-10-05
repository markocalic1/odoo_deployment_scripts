#!/usr/bin/env python3
"""Read an existing deployment Docker env and Compose without exposing secrets."""
import configparser
import json
from pathlib import Path
import subprocess
import sys


def target(env_file):
    env_file = Path(env_file).resolve()
    compose = next((env_file.parent / n for n in
                    ('docker-compose.yaml', 'docker-compose.yml', 'compose.yaml', 'compose.yml')
                    if (env_file.parent / n).is_file()), None)
    if compose is None:
        raise ValueError('No Compose file next to Docker env')
    result = subprocess.run(['docker', 'compose', '--env-file', str(env_file),
                             '-f', str(compose), 'config', '--format', 'json'],
                            text=True, capture_output=True)
    if result.returncode:
        raise ValueError('Cannot resolve Compose configuration; check it with docker compose config')
    services = json.loads(result.stdout)['services']
    candidates = []
    for name, service in services.items():
        targets = [v['target'] for v in service.get('volumes', [])]
        venvs = [v for v in targets if v.endswith('/venv')]
        if len(venvs) == 1:
            candidates.append((name, venvs[0], targets))
    if len(candidates) != 1:
        raise ValueError('Expected one Odoo service with a mounted /venv; use an explicit restore env otherwise')
    name, venv, mounts = candidates[0]
    prefix = str(Path(venv).parent)
    conf = configparser.RawConfigParser()
    if not conf.read(env_file.parent / 'etc/odoo.conf'):
        raise ValueError('Missing repository Docker etc/odoo.conf')
    db_name = conf.get('options', 'db_name').strip()
    data = conf.get('options', 'data_dir').strip()
    if not db_name or ',' in db_name:
        raise ValueError('Expected one db_name in Docker Odoo config')
    if data not in mounts:
        raise ValueError('Odoo data_dir is not a Compose volume target')
    return [str(compose), name, venv + '/bin/odoo', prefix + '/etc/odoo.conf', data, db_name]


if __name__ == '__main__':
    try:
        print('\t'.join(target(sys.argv[1])))
    except (ValueError, KeyError, configparser.Error, json.JSONDecodeError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
