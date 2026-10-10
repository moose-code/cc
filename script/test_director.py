#!/usr/bin/env python3
"""Tests for director.py. Each test builds a throwaway git repository."""

from __future__ import annotations

import contextlib
import hashlib
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

REPORT_TEXT = "report v1\n"
REPORT = {"path": "reports/review.md", "sha256": hashlib.sha256(REPORT_TEXT.encode()).hexdigest()}
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
        "requiredDeployGates": list(GATES),
        "stateOnlyPaths": list(STATE_ONLY),
        "gates": {name: {"evidence": [], "kinds": list(GATE_KINDS[name])} for name in GATES},
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
    if over.get("kind") in ("review", "acceptance"):
        record["report"] = {**REPORT, "revision": revision}
    record.update(over)
    return record


class RepoCase(unittest.TestCase):
    init_args: tuple = ()

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        try:
            self.sh("init", "-q", "-b", "main", *self.init_args)
        except subprocess.CalledProcessError:
            self.skipTest("git does not support this repository format")
        director.set_root(self.repo)
        self.state = base_state()
        self.ledger = {"schemaVersion": 1, "assumptions": {}, "evidence": {}}
        self.write("docs/PRODUCT_RULES.md", "- R-1 [INVARIANT] a rule\n")
        self.write("docs/DECISIONS.md", "DEC-001\nDate: 2026-01-01\n")
        self.write("docs/PROJECT_STATE.md", "state\n")
        self.write("project/traceability.json", json.dumps({"rules": {"R-1": {"type": "INVARIANT", "status": "planned"}}}))
        self.write("src/Core.sol", "v1\n")
        self.write("other/file.txt", "v1\n")
        self.write(REPORT["path"], REPORT_TEXT)
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
        self.add_evidence(
            "E-2", revision, carries=["E-1"], carriedChanges=["src/Core.sol"],
            method="diff review of src/Core.sol", limitations="l",
        )
        self.commit("carry")

    def test_carry_over_scoped_change_is_valid(self) -> None:
        self.carry_setup()
        self.assertFalse(self.validity("E-1")[0])
        self.assertEqual(self.validity("E-2"), (True, "valid"))
        self.assertEqual(self.check("working")[0], 0)

    def test_carry_must_enumerate_changed_carried_paths(self) -> None:
        self.carry_setup()
        self.ledger["evidence"]["E-2"]["carriedChanges"] = []
        self.save()
        self.commit("missing")
        self.assertEqual(
            self.validity("E-2"),
            (False, "carriedChanges differs from changed carried scope: missing src/Core.sol"),
        )
        self.ledger["evidence"]["E-2"]["carriedChanges"] = ["src/Core.sol", "src/Other.sol"]
        self.save()
        self.commit("extra")
        self.assertEqual(
            self.validity("E-2"),
            (False, "carriedChanges differs from changed carried scope: extra src/Other.sol"),
        )
        del self.ledger["evidence"]["E-2"]["carriedChanges"]
        self.save()
        self.commit("absent")
        self.assertFalse(self.validity("E-2")[0])

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

    def test_analysis_is_never_a_gate_kind(self) -> None:
        self.state["gates"]["productRules"]["kinds"] = ["review", "analysis"]
        self.save()
        self.assertTrue(any("gate productRules: analysis cannot be a gate kind" in e for e in self.errors()))

    def test_zero_decision_ids_in_non_empty_document_warns(self) -> None:
        self.write("docs/DECISIONS.md", "prose with no ids\n")
        code, out = self.check("working")
        self.assertEqual(code, 0, out)
        self.assertIn("WARN: docs/DECISIONS.md is non-empty but matches no decision ids", out)
        self.write("docs/DECISIONS.md", "DEC-001\n")
        self.assertNotIn("WARN: docs/DECISIONS.md", self.check("working")[1])

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
                "migrate: see the skill's SKILL.md (Start, older installed checker)",
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


class CarryClosure(RepoCase):
    """A review reached through a chain of carries is checked like a direct carry."""

    def setUp(self) -> None:
        super().setUp()
        self.state["gates"]["productRules"]["kinds"] = ["acceptance", "review", "test"]
        self.state["requiredFreezeGates"] = ["productRules"]

    def chain(self, review_kind="review", mid=None, top=None, change=True) -> str:
        """R (review at the initial commit) <- A1 <- A2 <- TOP; src changes before TOP."""
        base = self.head
        self.add_evidence("R", base, kind=review_kind, reviewer="Alice")
        self.add_evidence("A1", base, kind="analysis", carries=["R"], **(mid or {}))
        self.add_evidence("A2", base, kind="analysis", carries=["A1"], **(mid or {}))
        self.commit("review and carries")
        revision = base
        if change:
            self.write("src/Core.sol", "v2\n")
            revision = self.commit("change reviewed code")
        fields = {"kind": "analysis", "carries": ["A2"], "carriedChanges": ["src/Core.sol"] if change else []}
        fields.update(top or {})
        self.add_evidence("TOP", revision, **fields)
        return self.commit("top")

    def freeze(self) -> tuple[int, str]:
        self.state["candidate"] = self.sh("rev-parse", "HEAD")
        self.state["candidatePolicy"] = director.policy_hash(self.state)
        self.state["gates"]["productRules"]["evidence"] = ["TOP"]
        self.save()
        self.commit("gate")
        return self.check("freeze")

    def assertBlocked(self, fragment: str = "carried review R: reviewed scope changed: src/Core.sol") -> None:
        code, out = self.freeze()
        self.assertEqual(code, 1, out)
        self.assertIn(fragment, out)

    def test_unchanged_chain_is_valid(self) -> None:
        self.chain(change=False)
        code, out = self.freeze()
        self.assertEqual(code, 0, out)

    def test_review_reached_through_two_analysis_levels(self) -> None:
        self.chain()
        self.assertBlocked()

    def test_wide_scope_on_intermediate_and_top_records(self) -> None:
        self.chain(mid={"scope": ["*"]}, top={"scope": ["*"]})
        self.assertBlocked()

    def test_review_kind_carrier_over_a_review(self) -> None:
        self.chain(top={"kind": "review", "reviewer": "Bob", "carriedChanges": []})
        self.assertBlocked()

    def test_acceptance_reached_through_a_chain(self) -> None:
        self.chain(review_kind="acceptance")
        self.assertBlocked("carried acceptance R: reviewed scope changed: src/Core.sol")

    def test_test_kind_carrier_over_a_review_chain(self) -> None:
        self.chain(top={"kind": "test", "carriedChanges": []})
        self.assertBlocked()

    def test_closure_changes_for_non_independent_kinds_are_enumerated(self) -> None:
        self.chain(review_kind="test")
        self.assertEqual(self.freeze()[0], 0)
        self.ledger["evidence"]["TOP"]["carriedChanges"] = []
        self.save()
        self.commit("drop enumeration")
        self.assertIn("missing src/Core.sol", self.validity("TOP")[1])

    def test_reviewer_identity_is_normalized(self) -> None:
        for author, reviewer in [
            ("dir ector", "dir\u00a0ector"),
            ("dir ector", "dir  ector"),
            ("Strasse", "Stra\u00dfe"),
            ("Director", " DIRECTOR\t"),
        ]:
            errors: list[str] = []
            director.validate_record("R", base_record(self.head, kind="review", author=author, reviewer=reviewer), errors)
            self.assertTrue(any("reviewer must differ" in e for e in errors), (author, reviewer))
        errors = []
        director.validate_record("R", base_record(self.head, kind="review", author="director", reviewer="Alice"), errors)
        self.assertEqual(errors, [])

    def test_evidence_output_prints_reviewer(self) -> None:
        self.add_evidence("R", kind="review", reviewer="Alice")
        self.commit("review")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            director.evidence_report()
        self.assertIn("reviewer Alice", buffer.getvalue())

    def test_state_only_path_cannot_hide_a_deleted_reviewed_file(self) -> None:
        self.add_evidence("R", kind="review", reviewer="Alice", scope=["src/Core.sol"])
        self.commit("review")
        self.sh("rm", "-q", "src/Core.sol")
        self.state["stateOnlyPaths"] = STATE_ONLY + ["src/Core.sol"]
        self.save()
        self.commit("delete and hide")
        code, out = self.check("working")
        self.assertEqual(code, 1, out)
        self.assertIn("stateOnlyPaths entry src/Core.sol hides src/Core.sol", out)


class Reports(RepoCase):
    def honest_review(self, **over) -> str:
        """Review commit X, then commit the report at Y after X."""
        reviewed = self.head
        self.write("reports/honest.md", "findings: none\n")
        added = self.commit("add report")
        report = {"path": "reports/honest.md", "sha256": hashlib.sha256(b"findings: none\n").hexdigest(), "revision": added}
        self.add_evidence("R", reviewed, kind="review", reviewer="Alice", report=report, **over)
        self.commit("record review")
        return added

    def test_review_and_acceptance_require_a_report(self) -> None:
        for kind in ("review", "acceptance"):
            record = base_record(self.head, kind=kind, reviewer="Alice")
            del record["report"]
            errors: list[str] = []
            director.validate_record("R", record, errors)
            self.assertTrue(any("requires a report" in e for e in errors), kind)
        for report in ({"path": "../x", "sha256": "ab", "revision": self.head}, {"path": "a", "sha256": REPORT["sha256"]}):
            errors = []
            director.validate_record("R", base_record(self.head, report=report), errors)
            self.assertTrue(any("report must be" in e for e in errors), report)

    def test_report_added_after_the_reviewed_commit_is_valid_and_printed(self) -> None:
        self.honest_review()
        self.assertEqual(self.validity("R"), (True, "valid"))
        self.assertEqual(self.check("working")[0], 0)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            director.evidence_report()
        self.assertIn("report reports/honest.md", buffer.getvalue())

    def test_report_edited_in_working_tree_then_committed(self) -> None:
        self.honest_review()
        self.write("reports/honest.md", "tampered\n")
        ok, reason = self.validity("R")
        self.assertFalse(ok)
        self.assertIn("report reports/honest.md in the working tree differs", reason)
        self.commit("commit the edit")
        self.assertIn("at target differs from the recorded sha256", self.validity("R")[1])

    def test_report_committed_before_the_reviewed_commit_fails(self) -> None:
        self.write("src/Core.sol", "v2\n")
        reviewed = self.commit("reviewed commit")
        self.add_evidence("R", reviewed, kind="review", reviewer="Alice", report={**REPORT, "revision": self.head})
        self.commit("record review")
        ok, reason = self.validity("R")
        self.assertFalse(ok)
        self.assertIn("is not a descendant of sourceRevision", reason)

    def test_report_not_tracked_at_its_revision(self) -> None:
        early = self.head
        self.write("reports/late.md", "late\n")
        self.commit("add late report")
        report = {"path": "reports/late.md", "sha256": hashlib.sha256(b"late\n").hexdigest(), "revision": early}
        self.add_evidence("R", early, kind="review", reviewer="Alice", report=report)
        self.commit("record review")
        self.assertIn("not a regular tracked file at report revision", self.validity("R")[1])

    def test_report_symlink_is_rejected(self) -> None:
        reviewed = self.head
        (self.repo / "reports" / "link.md").symlink_to("review.md")
        added = self.commit("add symlink")
        report = {"path": "reports/link.md", "sha256": REPORT["sha256"], "revision": added}
        self.add_evidence("R", reviewed, kind="review", reviewer="Alice", report=report)
        self.commit("record review")
        self.assertIn("not a regular tracked file at report revision", self.validity("R")[1])

    def test_report_inside_the_record_scope_is_a_structural_error(self) -> None:
        self.add_evidence("R", kind="review", reviewer="Alice", scope=["reports/**"])
        code, out = self.check("working")
        self.assertEqual(code, 1, out)
        self.assertIn("report reports/review.md matches the record's scope", out)
        self.add_evidence("R", kind="review", reviewer="Alice", scope=["*"])
        self.assertIn("matches the record's scope", self.check("working")[1])
        self.state["stateOnlyPaths"] = STATE_ONLY + ["reports/**"]
        self.save()
        self.assertEqual(self.check("working")[0], 0)

    def test_adding_the_report_does_not_invalidate_the_review(self) -> None:
        self.honest_review()
        self.write("reports/second.md", "more\n")
        self.commit("unrelated report")
        self.assertEqual(self.validity("R"), (True, "valid"))

    def test_carried_review_report_is_checked_at_the_carrier_target(self) -> None:
        self.honest_review()
        self.add_evidence("A", kind="analysis", carries=["R"])
        self.commit("carry")
        self.assertEqual(self.validity("A"), (True, "valid"))
        self.write("reports/honest.md", "tampered\n")
        self.commit("edit report")
        self.assertIn("carried R: report reports/honest.md at target differs", self.validity("A")[1])


class HashLength(RepoCase):
    def test_64_hex_revision_is_well_formed_but_must_resolve(self) -> None:
        errors: list[str] = []
        director.validate_record("E", base_record("a" * 64), errors)
        self.assertTrue(any("not a commit in this repository" in e for e in errors))
        self.assertFalse(any("full commit hash" in e for e in errors))
        errors = []
        director.validate_record("E", base_record("a" * 41), errors)
        self.assertTrue(any("full commit hash" in e for e in errors))


class Sha256Repository(RepoCase):
    init_args = ("--object-format=sha256",)

    def test_evidence_in_a_sha256_repository(self) -> None:
        self.assertEqual(len(self.head), 64)
        self.add_evidence("E-1")
        self.commit("evidence")
        self.assertEqual(self.validity("E-1"), (True, "valid"))
        self.assertEqual(self.check("working")[0], 0)
        self.write("src/Core.sol", "v2\n")
        self.commit("change")
        self.assertFalse(self.validity("E-1")[0])


class DeployGate(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        candidate = self.head
        kinds = {"productRules": "review", "focusedTests": "test", "localLifecycle": "test", "deploymentRehearsal": "rehearsal"}
        for index, name in enumerate(GATES, start=1):
            self.ledger["evidence"][f"E-{index}"] = base_record(candidate, kind=kinds[name], reviewer="b")
            self.state["gates"][name]["evidence"] = [f"E-{index}"]
        self.state["candidate"] = candidate
        self.state["candidatePolicy"] = director.policy_hash(self.state)
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

    def test_analysis_cannot_extend_a_review_over_changed_code(self) -> None:
        review = self.state["candidate"]
        self.ledger["evidence"]["A-1"] = base_record(review, kind="analysis", carries=["E-1"])
        self.state["gates"]["productRules"]["evidence"] = ["A-1"]
        self.save()
        self.commit("carry unchanged review")
        self.assertEqual(self.check("freeze")[0], 0)
        self.write("src/Core.sol", "v2\n")
        changed = self.commit("change reviewed code")
        self.ledger["evidence"]["A-1"]["sourceRevision"] = changed
        self.state["candidate"] = changed
        self.save()
        self.commit("carry across change")
        self.assertEqual(
            self.validity("A-1"),
            (False, "carried review E-1: reviewed scope changed: src/Core.sol"),
        )
        code, out = self.check("freeze")
        self.assertEqual(code, 1, out)
        self.assertIn("reviewed scope changed: src/Core.sol", out)

    def test_freeze_command_records_candidate_and_policy(self) -> None:
        self.state["candidate"] = self.state["candidatePolicy"] = None
        self.save()
        self.commit("unfreeze")
        self.assertEqual(self.check("deploy")[0], 1)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(director.freeze_candidate(self.head), 0)
        recorded = json.loads((self.repo / "project/director-state.json").read_text())
        self.assertEqual(recorded["candidate"], self.head)
        self.assertEqual(recorded["candidatePolicy"], director.policy_hash(recorded))
        self.commit("freeze")
        self.assertEqual(self.check("deploy")[0], 0)

    def test_freeze_command_rejects_unknown_commit(self) -> None:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(director.freeze_candidate("0" * 40), 1)
        self.assertIn("not a commit reachable from HEAD", buffer.getvalue())

    def test_gate_policy_change_after_freeze_fails(self) -> None:
        for edit in (
            lambda: self.state["gates"]["focusedTests"]["kinds"].append("build"),
            lambda: self.state["requiredDeployGates"].remove("deploymentRehearsal"),
            lambda: self.state["stateOnlyPaths"].append("other/**"),
        ):
            edit()
            self.save()
            self.commit("edit policy")
            self.assertFails("gate policy changed after freeze: re-freeze deliberately")

    def test_candidate_set_by_hand_without_policy_fails(self) -> None:
        del self.state["candidatePolicy"]
        self.save()
        self.commit("by hand")
        self.assertFails("candidatePolicy is not recorded")

    def test_failing_result_is_not_accepted(self) -> None:
        self.ledger["evidence"]["E-3"]["result"] = "fail"
        self.save()
        self.commit("failed run")
        self.assertFails("evidence E-3 result is fail")


if __name__ == "__main__":
    unittest.main()
