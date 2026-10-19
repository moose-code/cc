#!/usr/bin/env python3
"""Offline release-boundary regressions using disposable Git repositories."""
from pathlib import Path
import shutil
import os
import subprocess
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
AUTHOR = subprocess.check_output(['git', 'log', '-1', '--format=%an%n%ae'], cwd=ROOT, text=True).splitlines()
FIXTURE_ENV = {**os.environ, 'GIT_AUTHOR_NAME': AUTHOR[0], 'GIT_AUTHOR_EMAIL': AUTHOR[1],
               'GIT_COMMITTER_NAME': AUTHOR[0], 'GIT_COMMITTER_EMAIL': AUTHOR[1]}


class FreezeTests(unittest.TestCase):
    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, env=FIXTURE_ENV).strip()

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        (self.root / 'script/tools').mkdir(parents=True)
        shutil.copy2(ROOT / 'script/tools/check-freeze.sh', self.root / 'script/tools/check-freeze.sh')
        (self.root / 'docs').mkdir()
        (self.root / 'docs/proof.md').write_text('Recorded evidence and limitations.\n')
        (self.root / 'source.sol').write_text('original input\n')
        self.commit()
        self.pin = self.git('rev-parse', 'HEAD')
        self.rows = [
            ['candidate', self.pin, 'docs/proof.md', 'all', 'pass'],
            *[[gate, self.pin, 'docs/proof.md', 'core,coin', 'pass']
              for gate in ('suite', 'deep', 'rehearsal')],
            ['e2e waiver for deferred Core only', self.pin, 'docs/proof.md', 'core', 'waived'],
            ['final review waiver for deferred Core only', self.pin, 'docs/proof.md', 'core', 'waived'],
            ['owner acceptance for deferred Core only', self.pin, 'docs/proof.md', 'core', 'pass'],
            *[[gate, 'pending', 'pending', 'coin', 'pending']
              for gate in ('e2e', 'review', 'acceptance')],
            ['services', 'pending', 'pending', 'coin,services', 'pending'],
            *[[gate, 'pending', 'pending', 'services', 'pending'] for gate in ('review', 'acceptance')],
        ]
        self.write_status()

    def commit(self):
        # Use the existing configured identity, just as a real local commit does.
        self.git('add', '--', '.')
        self.git('commit', '-qm', 'test fixture')

    def write_status(self):
        content = '## 4. the freeze table\n\n| gate | commit | result | stage | outcome |\n|---|---|---|---|---|\n'
        content += ''.join('| ' + ' | '.join(row) + ' |\n' for row in self.rows)
        (self.root / 'docs/STATUS.md').write_text(content + '\n### history\n')
        self.git('add', '--', 'docs/STATUS.md')
        self.git('commit', '-qm', 'record fixture evidence')

    def check(self, *stage):
        return subprocess.run(['bash', 'script/tools/check-freeze.sh', *stage], cwd=self.root,
                              text=True, capture_output=True)

    def test_core_waivers_cannot_clear_coin_or_services(self):
        # promise: Core approval preserves waivers as waivers and grants no later-stage approval.
        result = self.check('core')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('waived core:', result.stdout)
        for args in ((), ('coin',), ('services',), ('other',), ('core', 'coin')):
            self.assertNotEqual(self.check(*args).returncode, 0, args)

    def test_empty_or_missing_required_rows_fail(self):
        # promise: an absent table or missing gate can never look green.
        self.rows = []
        self.write_status()
        self.assertNotEqual(self.check('core').returncode, 0)

    def test_untracked_changed_missing_and_outside_evidence_fail(self):
        # promise: a path that merely exists is not enough to satisfy recorded evidence.
        (self.root / 'docs/proof.md').write_text('changed\n')
        self.assertNotEqual(self.check('core').returncode, 0)
        self.git('restore', '--', 'docs/proof.md')
        for path in ('docs/untracked.md', 'docs/missing.md', '../outside.md'):
            (self.root / 'docs/untracked.md').write_text('untracked\n')
            self.rows[1][2] = path
            self.write_status()
            self.assertNotEqual(self.check('core').returncode, 0, path)

    def test_pending_failed_and_invalid_revisions_fail(self):
        # promise: failed/pending checks and nonexistent revisions remain blockers.
        for outcome, revision in (('pending', self.pin), ('fail', self.pin), ('pass', 'abcdef123456')):
            self.rows[1][1] = revision
            self.rows[1][4] = outcome
            self.write_status()
            self.assertNotEqual(self.check('core').returncode, 0)

    def test_runtime_change_requires_repin_without_repeating_other_rows(self):
        # promise: candidate input changes need delta verification; unchanged historical rows are retained.
        (self.root / 'source.sol').write_text('changed input\n')
        self.commit()
        self.assertNotEqual(self.check('core').returncode, 0)
        self.rows[0][1] = self.git('rev-parse', 'HEAD')
        self.write_status()
        self.assertNotEqual(self.check('core').returncode, 0)
        # A newly recorded delta review and scoped approval are needed; broad suite rows stay unchanged.
        (self.root / 'docs/proof.md').write_text('New delta review and owner approval for the changed fixture input.\n')
        self.git('add', '--', 'docs/proof.md')
        self.git('commit', '-qm', 'record fixture delta review and approval')
        for row in self.rows:
            if row[0].startswith(('final review', 'owner acceptance')):
                row[1] = self.rows[0][1]
        self.write_status()
        result = self.check('core')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('suite ' + self.pin, result.stdout)

    def test_guidance_only_change_does_not_reopen_runtime_candidate(self):
        # promise: instruction cleanup alone does not invalidate executable evidence.
        (self.root / 'AGENTS.md').write_text('Use focused checks.\n')
        self.commit()
        self.assertEqual(self.check('core').returncode, 0)

    def test_duplicate_scope_and_waiver_errors_fail(self):
        # promise: broad acceptance or a mislabeled waiver cannot silently grant authority.
        original = [r[:] for r in self.rows]
        for change in ('duplicate', 'scope', 'acceptance', 'waiver'):
            self.rows = [r[:] for r in original]
            if change == 'duplicate': self.rows.append(self.rows[1][:])
            if change == 'scope': self.rows[1][3] = 'all,core'
            if change == 'acceptance': self.rows[6][3] = 'all'
            if change == 'waiver': self.rows[4][4] = 'pass'
            self.write_status()
            self.assertNotEqual(self.check('core').returncode, 0, change)


if __name__ == '__main__':
    unittest.main()
