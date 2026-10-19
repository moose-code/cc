#!/usr/bin/env python3
"""Exercise the workflow's actual path routing without Foundry, RPC or third-party packages."""

from pathlib import Path
import os
import subprocess
from tempfile import TemporaryDirectory
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text()
# Keep the routing in the workflow; exercise its shell against real Git diffs.
DIFF_STEP = WORKFLOW.split("      - id: diff\n", 1)[1].split("        run: |\n", 1)[1]
DIFF_SCRIPT = textwrap.dedent(DIFF_STEP.split("\n  web:", 1)[0])


class RoutingTests(unittest.TestCase):
    def route(self, path, *, deleted=False):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            env = {**os.environ, "GITHUB_OUTPUT": str(root / "outputs")}

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, env=env, text=True).strip()

            git("init", "-q")
            author = subprocess.check_output(["git", "log", "-1", "--format=%an%n%ae"], cwd=ROOT, text=True).splitlines()
            env.update(GIT_AUTHOR_NAME=author[0], GIT_AUTHOR_EMAIL=author[1],
                       GIT_COMMITTER_NAME=author[0], GIT_COMMITTER_EMAIL=author[1])
            changed = root / path
            changed.parent.mkdir(parents=True, exist_ok=True)
            if deleted:
                changed.write_text("original\n")
                git("add", "--", path)
            git("commit", "-qm", "base", "--allow-empty")
            env["BASE"] = git("rev-parse", "HEAD")
            if deleted:
                changed.unlink()
            else:
                changed.write_text("changed\n")
            git("add", "--", path)
            git("commit", "-qm", "change")
            subprocess.run(["bash", "-euo", "pipefail", "-c", DIFF_SCRIPT], cwd=root,
                           env=env, check=True, capture_output=True, text=True)
            return dict(line.split("=", 1) for line in (root / "outputs").read_text().splitlines())

    def test_tools_do_not_start_foundry_or_web(self):
        for path in ("script/mainnet-launch.py", "script/tools/test-mainnet-launch.py",
                     "script/tools/check-freeze.sh"):
            with self.subTest(path=path):
                routed = self.route(path)
                self.assertEqual((routed["tools"], routed["contracts"], routed["web"]),
                                 ("true", "false", "false"))

    def test_contract_and_shared_fixture_changes_cannot_receive_zero_tests(self):
        for path in ("src/Core.sol", "lib/credits", "foundry.toml", "script/LaunchConfig.sol",
                     "script/config/mainnet.json", "script/deploy.sh", "test/utils/Fixture.sol"):
            with self.subTest(path=path):
                routed = self.route(path)
                self.assertEqual((routed["contracts"], routed["smoke"]), ("true", "true"))

    def test_changed_tests_are_selected(self):
        routed = self.route("test/audit/PostflightInputs.t.sol")
        self.assertEqual(routed["contracts"], "true")
        self.assertEqual(routed["tests"].strip(), "test/audit/PostflightInputs.t.sol")

    def test_deleted_tests_use_the_smoke_fallback(self):
        routed = self.route("test/Config.t.sol", deleted=True)
        self.assertEqual(routed["contracts"], "true")
        self.assertEqual(routed["tests"], "")
        self.assertIn('if [ "$SMOKE" = true ] || [ -z "${TESTS// /}" ]; then', WORKFLOW)

    def test_web_and_docs_stay_separate(self):
        routed = self.route("web/src/page.tsx")
        self.assertEqual((routed["web"], routed["contracts"]), ("true", "false"))
        routed = self.route("docs/RUNBOOK.md")
        self.assertEqual((routed["web"], routed["contracts"], routed["tools"]),
                         ("false", "false", "false"))

    def test_smoke_and_changed_tests_share_one_compilation(self):
        step = WORKFLOW.split("      - name: focused contract checks\n", 1)[1]
        command = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        with TemporaryDirectory() as temp:
            capture = Path(temp) / "forge-args"
            env = {**os.environ, "SMOKE": "true", "TESTS": "test/Config.t.sol test/Fees.t.sol",
                   "CAPTURE": str(capture)}
            fake_forge = 'forge() { printf "%s\\n" "$*" >> "$CAPTURE"; };\n'
            subprocess.run(["bash", "-euo", "pipefail", "-c", fake_forge + command],
                           cwd=ROOT, env=env, check=True)
            calls = capture.read_text().splitlines()
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0].count("test/Config.t.sol"), 1)
            self.assertIn("test/Fees.t.sol", calls[0])
            self.assertIn("test/CoreLayout.t.sol", calls[0])

    def test_candidate_workflow_does_not_trigger_pr_release_work(self):
        routed = self.route(".github/workflows/candidate.yml")
        self.assertEqual((routed["web"], routed["contracts"], routed["tools"]),
                         ("false", "false", "true"))


if __name__ == "__main__":
    unittest.main()
