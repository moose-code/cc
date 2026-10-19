#!/usr/bin/env bash
# Validate the recorded evidence for one release step; this does not execute or certify its tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - "$@" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

stage = sys.argv[1] if len(sys.argv) == 2 else 'coin' if len(sys.argv) == 1 else ''
required = {
    'core': {'candidate', 'suite', 'deep', 'e2e', 'rehearsal', 'review', 'acceptance'},
    'coin': {'candidate', 'suite', 'deep', 'e2e', 'rehearsal', 'review', 'services', 'acceptance'},
    'services': {'candidate', 'services', 'review', 'acceptance'},
}
if stage not in required:
    sys.exit('fail stage: use core, coin or services (default: coin)')

def git(*args):
    return subprocess.run(['git', *args], text=True, capture_output=True)

if git('cat-file', '-e', 'HEAD:docs/STATUS.md').returncode or git('diff', '--quiet', 'HEAD', '--', 'docs/STATUS.md').returncode:
    sys.exit('fail evidence table: docs/STATUS.md must be tracked and unchanged from HEAD')
text = Path('docs/STATUS.md').read_text()
section = re.search(r'^## 4\.[^\n]*\n(.*?)(?=^#|\Z)', text, re.M | re.S)
seen = set()
failures = []
for line in section[1].splitlines() if section else []:
    if not line.startswith('|'):
        continue
    cells = [cell.strip() for cell in line.strip('|').split('|')]
    if cells[0] == 'gate' or cells[0].startswith('---'):
        continue
    if len(cells) != 5:
        failures.append('malformed row: expected gate, commit, result, stage, outcome')
        continue
    label, commit, result, scope, outcome = cells
    scopes = set(scope.split(','))
    if not scopes or not scopes <= {'all', 'core', 'coin', 'services'} or ('all' in scopes and len(scopes) != 1):
        failures.append(f'{label}: invalid stage {scope}')
        continue
    if 'all' not in scopes and stage not in scopes:
        continue
    gate = ('acceptance' if label.startswith('owner acceptance') else
            'review' if label.startswith('final review') else label.split()[0])
    if gate not in required[stage] or gate in seen:
        failures.append(f'{label}: unexpected or duplicate gate for {stage}')
        continue
    seen.add(gate)
    try:
        if outcome not in {'pass', 'waived'}:
            raise ValueError(f'outcome is {outcome}, not proven')
        if outcome == 'waived' and not (stage == scope == 'core' and gate in {'e2e', 'review'}):
            raise ValueError('waiver is limited to the recorded deferred-Core e2e/review exception')
        if ('waiver' in label) != (outcome == 'waived'):
            raise ValueError('waiver label and outcome disagree')
        if gate == 'acceptance' and scopes != {stage}:
            raise ValueError('owner acceptance must name exactly this release step')
        if not re.fullmatch(r'[0-9a-f]{7,40}', commit) or git('rev-parse', '--verify', commit + '^{commit}').returncode:
            raise ValueError('evidence revision is missing or invalid')
        path = Path(result)
        if path.is_absolute() or '..' in path.parts or not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(Path.cwd()):
            raise ValueError('result must be a regular file inside this checkout')
        if git('cat-file', '-e', 'HEAD:' + result).returncode or git('diff', '--quiet', 'HEAD', '--', result).returncode:
            raise ValueError('result must be tracked and unchanged from HEAD')
        if gate == 'candidate':
            if git('merge-base', '--is-ancestor', commit, 'HEAD').returncode:
                raise ValueError('candidate is not an ancestor of HEAD')
            delta = git('diff', '--name-only', commit, 'HEAD')
            if delta.returncode:
                raise ValueError('cannot compare candidate inputs')
            changed = delta.stdout.splitlines()
            if any(not (p.startswith('docs/') or p in {'AGENTS.md', 'CLAUDE.md'}) for p in changed):
                raise ValueError('executable inputs changed: re-pin candidate and verify the affected delta; retain unaffected evidence')
        print(f'{"waived" if outcome == "waived" else "ok"} {stage}: {label} {commit} {result}')
    except ValueError as error:
        failures.append(f'{label}: {error}')
failures.extend('missing gate: ' + gate for gate in sorted(required[stage] - seen))
for failure in failures:
    print('fail ' + stage + ': ' + failure)
sys.exit(bool(failures))
PY
