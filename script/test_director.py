#!/usr/bin/env python3
"""Tests for director.py. Each test builds a throwaway git repository."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("director_under_test", HERE / "director.py")
director = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(director)

STATE_ONLY = ["docs/PROJECT_STATE.md", "project/director-state.json", "project/evidence.json"]
GATES = ["productRules", "focusedTests", "localLifecycle", "deploymentRehearsal"]
GATE_KINDS = {
    "productRules": ["acceptance", "review"],
    "focusedTests": ["test"],
    "localLifecycle": ["test", "rehearsal"],
    "deploymentRehearsal": ["rehearsal"],
}


def base_state(documents: dict | None = None) -> dict:
    return {
        "schemaVersion": 2,
        "projectName": "t",
        "riskLevel": "low",
        "phase": "product-rules",
        "documents": documents
        or {
            "rules": "docs/PRODUCT_RULES.md",
            "decisions": "docs/DECISIONS.md",
            "state": "docs/PROJECT_STATE.md",
            "traceability": "project/traceability.json",
            "evidence": "project/evidence.json",
        },
        "objective": {
            "id": "OBJ-1",
            "status": "active",
            "statement": "s",
            "authority": "owner, 2026-01-01",
            "boundaries": [],
            "requiredPaths": [],
            "deliverables": [],
        },
        "candidate": None,
        "activeChange": None,
        "openBlockers": [],
        "ownerDecisions": [],
        "nextAction": "n",
        "requiredFreezeGates": ["productRules"],
        "requiredDeployGates": GATES,
        "stateOnlyPaths": STATE_ONLY,
        "gates": {name: {"evidence": [], "kinds": GATE_KINDS[name]} for name in GATES},
    }


def base_record(revision: str, **over) -> dict:
    record = {
        "claim": "c",
        "kind": "test",
        "sourceRevision": revision,
        "scope": ["src/**"],
        "assumptions": {},
        "dependsOn": [],
        "inputs": "i",
        "method": "m",
        "author": "a",
        "result": "pass",
        "limitations": "l",
        "invalidated": None,
    }
    record.update(over)
    return record


class RepoCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        self.sh("init", "-q", "-b", "main")
        director.set_root(self.repo)
        self.state = base_state()
        self.ledger = {"schemaVersion": 1, "assumptions": {}, "evidence": {}}
        self.write("docs/PRODUCT_RULES.md", "- R-1 [INVARIANT] a rule\n")
        self.write("docs/DECISIONS.md", "DEC-001\nDate: 2026-01-01\n")
        self.write("docs/PROJECT_STATE.md", "state\n")
        self.write("project/traceability.json", json.dumps({"rules": {"R-1": {"type": "INVARIANT", "status": "planned"}}}))
        self.write("src/Core.sol", "v1\n")
        self.write("other/file.txt", "v1\n")
        self.save()
        self.head = self.commit("initial")

    def sh(self, *args: str) -> str:
        result = subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo,
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def write(self, rel: str, text: str) -> None:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def save(self) -> None:
        self.write("project/director-state.json", json.dumps(self.state, indent=2))
        self.write("project/evidence.json", json.dumps(self.ledger, indent=2))

    def commit(self, message: str) -> str:
        self.sh("add", "-A")
        self.sh("commit", "-q", "-m", message)
        return self.sh("rev-parse", "HEAD")

    def add_evidence(self, eid: str, revision: str | None = None, **over) -> None:
        self.ledger["evidence"][eid] = base_record(revision or self.head, **over)
        self.save()

    def check(self, level: str) -> tuple[int, str]:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = director.check_gate(level)
        return code, buffer.getvalue()

    def validity(self, eid: str) -> tuple[bool, str]:
        return director.evidence_validity(eid, self.sh("rev-parse", "HEAD"))


class EvidenceValidity(RepoCase):
    def test_assumption_bump_invalidates_without_file_change(self) -> None:
        self.ledger["assumptions"]["A-GAS-PRICE"] = {
            "statement": "s", "kind": "assumption", "source": "x", "version": 1, "checked": "2026-01-01"
        }
        self.add_evidence("E-1", assumptions={"A-GAS-PRICE": 1})
        self.add_evidence("E-2")
        self.commit("evidence")
        self.assertEqual(self.validity("E-1"), (True, "valid"))
        self.ledger["assumptions"]["A-GAS-PRICE"]["version"] = 2
        self.save()
        self.commit("bump assumption")
        self.assertEqual(
            self.validity("E-1"),
            (False, "assumption A-GAS-PRICE changed (recorded v1, current v2)"),
        )
        self.assertEqual(self.validity("E-2"), (True, "valid"))

    def test_scope_change_invalidates_outside_and_state_changes_do_not(self) -> None:
        self.add_evidence("E-1")
        self.commit("evidence")
        self.write("other/file.txt", "v2\n")
        self.write("docs/PROJECT_STATE.md", "state v2\n")
        self.commit("outside scope and state only")
        self.assertEqual(self.validity("E-1"), (True, "valid"))
        self.write("src/Core.sol", "v2\n")
        self.commit("inside scope")
        ok, reason = self.validity("E-1")
        self.assertFalse(ok)
        self.assertEqual(reason, "scope changed after verification: src/Core.sol")

    def test_depends_on_propagates(self) -> None:
        self.add_evidence("E-1")
        self.add_evidence("E-2", scope=["other/**"], dependsOn=["E-1"])
        self.commit("evidence")
        self.assertTrue(self.validity("E-2")[0])
        self.write("src/Core.sol", "v2\n")
        self.commit("break E-1")
        self.assertFalse(self.validity("E-1")[0])
        self.assertEqual(self.validity("E-2"), (False, "depends on invalid E-1"))

    def test_all_invalidity_reasons_are_reported(self) -> None:
        self.ledger["assumptions"]["A-FORK-BLOCK"] = {
            "statement": "s", "kind": "fact", "source": "x", "version": 1, "checked": "2026-01-01"
        }
        self.add_evidence("E-1", assumptions={"A-FORK-BLOCK": 1})
        self.commit("evidence")
        self.write("src/Core.sol", "v2\n")
        self.ledger["assumptions"]["A-FORK-BLOCK"]["version"] = 2
        self.save()
        self.commit("scope change and assumption bump")
        ok, reason = self.validity("E-1")
        self.assertFalse(ok)
        self.assertEqual(
            reason,
            "scope changed after verification: src/Core.sol; "
            "assumption A-FORK-BLOCK changed (recorded v1, current v2)",
        )

    def carry_setup(self) -> None:
        """E-1 verified at the initial commit, src changes, E-2 carries E-1 at the new commit."""
        self.ledger["assumptions"]["A-GAS-PRICE"] = {
            "statement": "s", "kind": "assumption", "source": "x", "version": 1, "checked": "2026-01-01"
        }
        self.add_evidence("E-1", assumptions={"A-GAS-PRICE": 1})
        self.write("src/Core.sol", "v2\n")
        revision = self.commit("scoped change covered by E-2 analysis")
        self.head = revision
        self.add_evidence("E-2", revision, carries=["E-1"], method="diff review of src/Core.sol", limitations="l")
        self.commit("carry")

    def test_carry_over_scoped_change_is_valid(self) -> None:
        self.carry_setup()
        self.assertFalse(self.validity("E-1")[0])
        self.assertEqual(self.validity("E-2"), (True, "valid"))
        self.assertEqual(self.check("working")[0], 0)

    def test_carry_invalidated_by_carried_assumption_bump(self) -> None:
        self.carry_setup()
        self.ledger["assumptions"]["A-GAS-PRICE"]["version"] = 2
        self.save()
        self.commit("bump")
        self.assertEqual(
            self.validity("E-2"),
            (False, "carried E-1: assumption A-GAS-PRICE changed (recorded v1, current v2)"),
        )

    def test_carry_invalidated_by_scoped_change_after_carrying_revision(self) -> None:
        self.carry_setup()
        self.write("src/Core.sol", "v3\n")
        self.commit("later change")
        self.assertEqual(self.validity("E-2"), (False, "scope changed after verification: src/Core.sol"))

    def test_carry_requires_passing_carried_result_for_gates(self) -> None:
        self.carry_setup()
        self.ledger["evidence"]["E-1"]["result"] = "findings"
        self.save()
        self.commit("findings")
        state, ledger, _ = director.analyze()
        ok, reason = director.evidence_usable("E-2", self.sh("rev-parse", "HEAD"), state, ledger, {})
        self.assertEqual((ok, reason), (False, "carried E-1 result is findings"))

    def test_glob_double_star_matches_zero_directories(self) -> None:
        self.assertTrue(director.matches("test/A.t.sol", ["test/**/*.sol"]))
        self.assertTrue(director.matches("test/a/b/A.t.sol", ["test/**/*.sol"]))
        self.assertFalse(director.matches("test/A.t.txt", ["test/**/*.sol"]))
        self.assertTrue(director.matches("src/a/b.sol", ["src/**"]))

    def test_non_ascii_paths_are_reported_unquoted(self) -> None:
        self.write("src/\u00e9.sol", "v1\n")
        self.head = self.commit("add file")
        self.add_evidence("E-1")
        self.commit("evidence")
        self.write("src/\u00e9.sol", "v2\n")
        self.commit("change")
        self.assertEqual(self.validity("E-1"), (False, "scope changed after verification: src/\u00e9.sol"))

    def test_evidence_output_lists_changed_carried_scope(self) -> None:
        self.carry_setup()
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            director.evidence_report()
        line = next(l for l in buffer.getvalue().splitlines() if l.startswith("E-2"))
        self.assertIn("src/Core.sol", line)

    def test_invalidated_record_is_invalid(self) -> None:
        self.add_evidence("E-1", invalidated={"reason": "flaky", "date": "2026-02-01"})
        self.commit("evidence")
        self.assertEqual(self.validity("E-1"), (False, "invalidated: flaky (2026-02-01)"))


class Structure(RepoCase):
    def errors(self) -> list[str]:
        code, out = self.check("working")
        return [line for line in out.splitlines() if line.startswith("ERROR")] if code else []

    def test_review_by_author_is_error(self) -> None:
        self.add_evidence("E-1", kind="review", reviewer="a")
        self.assertTrue(any("reviewer must differ from author" in e for e in self.errors()))
        self.add_evidence("E-1", kind="review", reviewer="b")
        self.assertEqual(self.errors(), [])

    def test_duplicate_owner_decision_and_rule_ids(self) -> None:
        decision = {"id": "OD-1", "question": "q", "status": "open", "blocks": []}
        self.state["ownerDecisions"] = [decision, dict(decision)]
        self.save()
        self.assertTrue(any("duplicate ownerDecisions id: OD-1" in e for e in self.errors()))
        self.state["ownerDecisions"] = []
        self.save()
        self.write("docs/PRODUCT_RULES.md", "- R-1 [INVARIANT] a\n- R-1 [INVARIANT] b\n")
        self.assertTrue(any("duplicate product rule id: R-1" in e for e in self.errors()))

    def test_stored_gate_status_is_rejected(self) -> None:
        self.state["gates"]["productRules"]["status"] = "pass"
        self.save()
        errors = self.errors()
        self.assertTrue(any("gate productRules stores 'status'" in e and "record evidence" in e for e in errors))

    def test_unknown_evidence_and_dependency_cycle(self) -> None:
        self.state["gates"]["productRules"]["evidence"] = ["E-9"]
        self.add_evidence("E-1", dependsOn=["E-2"])
        self.add_evidence("E-2", dependsOn=["E-1"])
        errors = self.errors()
        self.assertTrue(any("unknown evidence: E-9" in e for e in errors))
        self.assertTrue(any("cycle: E-1 -> E-2 -> E-1" in e for e in errors))

    def test_carrying_unknown_or_self_is_error(self) -> None:
        self.add_evidence("E-1", carries=["E-9", "E-1"])
        errors = self.errors()
        self.assertTrue(any("carries unknown evidence: E-9" in e for e in errors))
        self.assertTrue(any("carries itself" in e for e in errors))
        self.add_evidence("E-1", carries=["E-2"])
        self.add_evidence("E-2", carries=["E-1"])
        self.assertTrue(any("cycle: E-1 -> E-2 -> E-1" in e for e in self.errors()))

    def test_gate_without_kinds_and_empty_required_list_are_errors(self) -> None:
        del self.state["gates"]["productRules"]["kinds"]
        self.state["requiredFreezeGates"] = []
        self.save()
        errors = self.errors()
        self.assertTrue(any("gate productRules has no kinds" in e for e in errors))
        self.assertTrue(any("requiredFreezeGates must not be empty" in e for e in errors))

    def test_carrier_scope_must_cover_carried_scope(self) -> None:
        self.add_evidence("E-1", scope=["src/**"])
        self.add_evidence("E-2", scope=["docs/**"], carries=["E-1"])
        self.assertTrue(any("scope does not cover carried E-1 pattern src/**" in e for e in self.errors()))
        self.add_evidence("E-2", scope=["*"], carries=["E-1"])
        self.assertEqual(self.errors(), [])
        self.add_evidence("E-2", scope=["other/**", "src/**"], carries=["E-1"])
        self.assertEqual(self.errors(), [])

    def test_scope_pattern_matching_no_tracked_file_is_error(self) -> None:
        self.add_evidence("E-1", scope=["srcc/**", "*.nope"])
        errors = self.errors()
        self.assertTrue(any("scope pattern srcc/** matches no file" in e for e in errors))
        self.assertTrue(any("scope pattern *.nope matches no file" in e for e in errors))
        self.add_evidence("E-1", scope=["*"])
        self.assertEqual(self.errors(), [])

    def test_state_only_path_cannot_hide_evidence_scope(self) -> None:
        self.add_evidence("E-1", scope=["docs/**"])
        self.assertTrue(any("stateOnlyPaths entry docs/PROJECT_STATE.md hides" in e for e in self.errors()))
        self.add_evidence("E-1", scope=["*"])
        self.assertEqual(self.errors(), [])

    def test_decision_id_pattern(self) -> None:
        self.write("docs/DECISIONS.md", "## ADR-1\n## ADR-1\n\nDEC-001\nDEC-001\n")
        self.assertEqual(self.errors(), [ "ERROR: duplicate decision id: DEC-001 (2 times)"])
        self.state["documents"]["decisionIdPattern"] = r"^##\s+(ADR-\d+)"
        self.save()
        self.assertEqual(self.errors(), ["ERROR: duplicate decision id: ADR-1 (2 times)"])
        self.state["documents"]["decisionIdPattern"] = "(("
        self.save()
        self.assertTrue(any("decisionIdPattern" in e for e in self.errors()))

    def test_schema_1_state_gives_one_clear_error_for_every_command(self) -> None:
        self.write("project/director-state.json", json.dumps({"schemaVersion": 1, "gates": {}, "openBlockers": []}))
        for run in (
            lambda: director.check_gate("working"),
            lambda: director.check_gate("deploy"),
            director.status,
            director.handoff,
            director.evidence_report,
        ):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = run()
            self.assertEqual(code, 1)
            self.assertEqual(
                buffer.getvalue().strip(),
                "ERROR: director-state.json is schema 1; this checker needs schema 2: "
                "migrate (see the skill's references/change-management.md)",
            )

    def test_working_success_line_is_labeled_structural(self) -> None:
        code, out = self.check("working")
        self.assertEqual(code, 0, out)
        self.assertIn("structural only", out)
        self.assertIn("does not establish product correctness", out)

    def test_invalid_evidence_is_warning_not_error(self) -> None:
        self.add_evidence("E-1")
        self.commit("evidence")
        self.write("src/Core.sol", "v2\n")
        self.commit("break")
        code, out = self.check("working")
        self.assertEqual(code, 0, out)
        self.assertIn("WARN: evidence E-1 is invalid", out)

    def test_adopted_layout_without_traceability(self) -> None:
        documents = {
            "rules": "spec/RULES.md",
            "decisions": "spec/DECISIONS.md",
            "state": "spec/STATE.md",
            "traceability": None,
            "evidence": "project/evidence.json",
        }
        self.state = base_state(documents)
        self.state["stateOnlyPaths"] = ["spec/STATE.md", "project/director-state.json", "project/evidence.json"]
        self.write("spec/RULES.md", "free-form rules, no ids\n")
        self.write("spec/DECISIONS.md", "notes\n")
        self.write("spec/STATE.md", "state\n")
        (self.repo / "project/traceability.json").unlink()
        self.save()
        code, out = self.check("working")
        self.assertEqual(code, 0, out)


class DeployGate(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        candidate = self.head
        kinds = {"productRules": "review", "focusedTests": "test", "localLifecycle": "test", "deploymentRehearsal": "rehearsal"}
        for index, name in enumerate(GATES, start=1):
            self.ledger["evidence"][f"E-{index}"] = base_record(candidate, kind=kinds[name], reviewer="b")
            self.state["gates"][name]["evidence"] = [f"E-{index}"]
        self.state["candidate"] = candidate
        self.state["objective"].update(
            status="complete",
            requiredPaths=[{"id": "P-1", "description": "d", "status": "verified", "evidence": ["E-1"]}],
            deliverables=[{"id": "D-1", "description": "d", "status": "verified", "evidence": ["E-2"]}],
        )
        self.save()
        self.commit("record evidence")

    def assertFails(self, fragment: str) -> None:
        code, out = self.check("deploy")
        self.assertEqual(code, 1, out)
        self.assertIn(fragment, out)

    def test_passes_when_satisfied(self) -> None:
        code, out = self.check("deploy")
        self.assertEqual(code, 0, out)
        self.assertIn("deploy gate records pass for candidate", out)
        self.assertIn("not proven by this check", out)
        self.assertEqual(self.check("freeze")[0], 0)

    def test_incomplete_objective(self) -> None:
        self.state["objective"]["status"] = "active"
        self.save()
        self.commit("objective active")
        self.assertFails("not complete")

    def test_open_owner_decision_blocking_deploy(self) -> None:
        self.state["ownerDecisions"] = [{"id": "OD-1", "question": "q", "status": "open", "blocks": ["deploy"]}]
        self.save()
        self.commit("decision")
        self.assertFails("open owner decision OD-1 blocks deploy")
        self.state["ownerDecisions"][0]["status"] = "decided"
        self.save()
        self.commit("decided")
        self.assertEqual(self.check("deploy")[0], 0)

    def test_head_differs_from_candidate_by_non_state_file(self) -> None:
        self.write("other/file.txt", "v2\n")
        self.commit("non-state change")
        self.assertFails("non-state files changed after candidate: other/file.txt")

    def test_dirty_tree(self) -> None:
        self.write("untracked.txt", "x\n")
        self.assertFails("working tree is dirty")

    def test_invalid_gate_evidence_names_reason(self) -> None:
        self.write("src/Core.sol", "v2\n")
        self.commit("scope change")
        self.state["candidate"] = self.sh("rev-parse", "HEAD")
        self.save()
        self.commit("move candidate")
        self.assertFails("evidence E-1 invalid: scope changed after verification: src/Core.sol")

    def test_analysis_record_in_every_gate_passes_neither_freeze_nor_deploy(self) -> None:
        self.ledger["evidence"]["E-5"] = base_record(self.state["candidate"], kind="analysis")
        for name in GATES:
            self.state["gates"][name]["evidence"] = ["E-5"]
        self.save()
        self.commit("analysis everywhere")
        for level in ("freeze", "deploy"):
            code, out = self.check(level)
            self.assertEqual(code, 1, out)
            self.assertIn("gate productRules: evidence E-5 has kind analysis", out)

    def test_analysis_counts_as_the_kinds_it_carries(self) -> None:
        self.ledger["evidence"]["E-5"] = base_record(self.state["candidate"], kind="analysis", carries=["E-2"])
        self.state["gates"]["focusedTests"]["evidence"] = ["E-5"]
        self.save()
        self.commit("carry a test")
        self.assertEqual(self.check("deploy")[0], 0)
        self.state["gates"]["productRules"]["evidence"] = ["E-5"]
        self.save()
        self.commit("carry used as review")
        self.assertFails("gate productRules: evidence E-5 has kind test")

    def test_deploy_respects_owner_decision_blocking_freeze(self) -> None:
        self.state["ownerDecisions"] = [{"id": "OD-1", "question": "q", "status": "open", "blocks": ["freeze"]}]
        self.save()
        self.commit("decision")
        self.assertFails("open owner decision OD-1 blocks")

    def test_failing_result_is_not_accepted(self) -> None:
        self.ledger["evidence"]["E-3"]["result"] = "fail"
        self.save()
        self.commit("failed run")
        self.assertFails("evidence E-3 result is fail")


if __name__ == "__main__":
    unittest.main()
