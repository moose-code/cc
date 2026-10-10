#!/usr/bin/env python3
"""Checker for the repository Project Director records.

Validates record structure and recomputes evidence validity from git history.
A passing check shows the records are internally consistent. It does not show
that the product is correct.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(os.environ.get("DIRECTOR_ROOT") or Path(__file__).resolve().parents[1]).resolve()
STATE_REL = "project/director-state.json"
UNBORN = "UNBORN"

RULE_RE = re.compile(r"^\s*-\s+(?:\*\*)?([A-Z][A-Z0-9]*-\d+)(?:\*\*)?\s+\[", re.MULTILINE)
DECISION_RE = re.compile(r"^\s*(?:#{1,6}\s+)?(?:\*\*)?(DEC-\d+)(?:\*\*)?(?=\s|:|$)", re.MULTILINE)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")

OBJECTIVE_STATUS = {"active", "paused", "complete"}
ITEM_STATUS = {"pending", "in-progress", "verified"}
OWNER_DECISION_STATUS = {"open", "decided", "withdrawn"}
ASSUMPTION_KINDS = {"fact", "assumption", "projection", "owner-decision"}
EVIDENCE_KINDS = {"test", "build", "review", "simulation", "rehearsal", "analysis", "acceptance"}
EVIDENCE_RESULTS = {"pass", "fail", "findings"}
INDEPENDENT_KINDS = {"review", "acceptance"}
EVIDENCE_TEXT_FIELDS = ("claim", "inputs", "method", "author", "limitations")

OK_WORKING = (
    "OK (structural only): director records are internally consistent at {head} on {branch}. "
    "This does not establish product correctness."
)
OK_GATE = (
    "OK (structural only): {level} gate records pass for candidate {candidate}. "
    "Product and release acceptance are recorded judgments, not proven by this check."
)
HANDOFF_RULE = (
    "Current owner instructions override recorded rules; recorded rules, tests and "
    "evidence are claims to challenge, not proof."
)


def set_root(path: str | Path) -> None:
    global ROOT
    ROOT = Path(path).resolve()


# git

def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=ROOT, text=True, capture_output=True, check=False
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def current() -> tuple[str, str, bool]:
    head = git("rev-parse", "--verify", "HEAD", check=False)
    dirty = bool(git("status", "--porcelain"))
    if not head:
        return git("symbolic-ref", "--short", "HEAD", check=False) or "unborn", UNBORN, dirty
    return git("rev-parse", "--abbrev-ref", "HEAD"), head, dirty


def resolve_commit(rev: str) -> str | None:
    if not rev or rev.startswith("-"):
        return None
    return git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check=False) or None


def is_ancestor(older: str, newer: str) -> bool:
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", older, newer],
        cwd=ROOT,
        capture_output=True,
    ).returncode == 0


def changed_paths(older: str, newer: str) -> list[str]:
    output = git("diff", "--name-only", "--no-renames", f"{older}..{newer}")
    return [line for line in output.splitlines() if line]


def short(sha: str) -> str:
    return sha[:10]


def matches(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if pattern == "*":
            return True
        if pattern.endswith("/**"):
            if path.startswith(pattern[:-2]):
                return True
        elif fnmatch.fnmatchcase(path, pattern):
            return True
    return False


# loading

def _no_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    seen: dict = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def read_json(rel: str, errors: list[str]) -> dict | None:
    path = ROOT / rel
    if not path.is_file():
        errors.append(f"missing required file: {rel}")
        return None
    try:
        data = json.loads(path.read_text(), object_pairs_hook=_no_duplicate_keys)
    except (OSError, ValueError) as exc:
        errors.append(f"{rel}: {exc}")
        return None
    if not isinstance(data, dict):
        errors.append(f"{rel}: top level must be an object")
        return None
    return data


def doc_path(docs: dict, key: str, nullable: bool, errors: list[str]) -> str | None:
    if key not in docs:
        errors.append(f"documents.{key} is required" + (" (use null to disable)" if nullable else ""))
        return None
    value = docs[key]
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value:
        errors.append(f"documents.{key} must be a repository relative path")
        return None
    parts = Path(value).parts
    if Path(value).is_absolute() or ".." in parts:
        errors.append(f"documents.{key} must be a repository relative path: {value}")
        return None
    if not (ROOT / value).is_file():
        errors.append(f"missing required file: {value}")
        return None
    return value


def load() -> tuple[dict | None, dict | None, dict | None, list[str], dict]:
    """Return state, evidence ledger, traceability, errors, resolved document paths."""
    errors: list[str] = []
    state = read_json(STATE_REL, errors)
    ledger = trace = None
    paths: dict[str, str | None] = {}
    if state is not None:
        docs = state.get("documents")
        if not isinstance(docs, dict):
            errors.append("documents must be an object")
        else:
            for key, nullable in (
                ("rules", False),
                ("decisions", False),
                ("state", False),
                ("traceability", True),
                ("evidence", False),
            ):
                paths[key] = doc_path(docs, key, nullable, errors)
            if paths.get("evidence"):
                ledger = read_json(paths["evidence"], errors)
            if paths.get("traceability"):
                trace = read_json(paths["traceability"], errors)
    return state, ledger, trace, errors, paths


# structural validation

def text_field(obj: dict, key: str, where: str, errors: list[str]) -> str | None:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{where}: {key} must be a non-empty string")
        return None
    return value


def str_list(value: object, where: str, errors: list[str]) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        errors.append(f"{where} must be a list of strings")
        return []
    return value


def report_duplicates(ids: list[str], label: str, errors: list[str]) -> None:
    for ident, count in sorted(Counter(ids).items()):
        if count > 1:
            errors.append(f"duplicate {label} id: {ident} ({count} times)")


def objective_items(state: dict) -> list[dict]:
    objective = state.get("objective")
    if not isinstance(objective, dict):
        return []
    items = []
    for group in ("requiredPaths", "deliverables"):
        entries = objective.get(group)
        if isinstance(entries, list):
            items.extend(item for item in entries if isinstance(item, dict))
    return items


def validate_objective(state: dict, errors: list[str]) -> None:
    objective = state.get("objective")
    if not isinstance(objective, dict):
        errors.append("objective must be an object")
        return
    for key in ("id", "statement", "authority"):
        text_field(objective, key, "objective", errors)
    status = objective.get("status")
    if status not in OBJECTIVE_STATUS:
        errors.append(f"objective: status must be one of {sorted(OBJECTIVE_STATUS)}")
    str_list(objective.get("boundaries"), "objective.boundaries", errors)
    ids: list[str] = []
    unverified = False
    for group in ("requiredPaths", "deliverables"):
        entries = objective.get(group)
        if not isinstance(entries, list):
            errors.append(f"objective.{group} must be a list")
            continue
        if status == "complete" and not entries:
            errors.append(f"objective is complete but {group} is empty")
        for index, item in enumerate(entries):
            where = f"objective.{group}[{index}]"
            if not isinstance(item, dict):
                errors.append(f"{where} must be an object")
                continue
            ident = text_field(item, "id", where, errors)
            if ident:
                ids.append(ident)
            text_field(item, "description", where, errors)
            item_status = item.get("status")
            if item_status not in ITEM_STATUS:
                errors.append(f"{where}: status must be one of {sorted(ITEM_STATUS)}")
            evidence = str_list(item.get("evidence"), f"{where}.evidence", errors)
            if item_status == "verified" and not evidence:
                errors.append(f"{where}: verified item {ident} lists no evidence")
            if item_status != "verified":
                unverified = True
    report_duplicates(ids, "objective item", errors)
    if status == "complete" and unverified:
        errors.append("objective is complete but not every path and deliverable is verified")


def validate_owner_decisions(state: dict, errors: list[str]) -> None:
    entries = state.get("ownerDecisions")
    if not isinstance(entries, list):
        errors.append("ownerDecisions must be a list")
        return
    ids: list[str] = []
    for index, entry in enumerate(entries):
        where = f"ownerDecisions[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{where} must be an object")
            continue
        ident = text_field(entry, "id", where, errors)
        if ident:
            ids.append(ident)
        text_field(entry, "question", where, errors)
        if entry.get("status") not in OWNER_DECISION_STATUS:
            errors.append(f"{where}: status must be one of {sorted(OWNER_DECISION_STATUS)}")
        str_list(entry.get("blocks", []), f"{where}.blocks", errors)
    report_duplicates(ids, "ownerDecisions", errors)


def validate_state(state: dict, errors: list[str]) -> None:
    if state.get("schemaVersion") != 2:
        errors.append(f"{STATE_REL}: schemaVersion must be 2")
    for key in ("projectName", "riskLevel", "phase", "nextAction"):
        text_field(state, key, STATE_REL, errors)
    candidate = state.get("candidate")
    if candidate is not None and not isinstance(candidate, str):
        errors.append("candidate must be null or a commit string")
    if not isinstance(state.get("activeChange"), (type(None), str, dict)):
        errors.append("activeChange must be null, a string or an object")
    str_list(state.get("openBlockers"), "openBlockers", errors)
    str_list(state.get("stateOnlyPaths"), "stateOnlyPaths", errors)
    required = {}
    for key in ("requiredFreezeGates", "requiredDeployGates"):
        required[key] = str_list(state.get(key), key, errors)
    validate_objective(state, errors)
    validate_owner_decisions(state, errors)
    gates = state.get("gates")
    if not isinstance(gates, dict):
        errors.append("gates must be an object")
        return
    for name, gate in gates.items():
        if not isinstance(gate, dict):
            errors.append(f"gate {name} must be an object")
            continue
        for stored in ("status", "commit"):
            if stored in gate:
                errors.append(
                    f"gate {name} stores '{stored}'; gate status is derived, "
                    "record evidence in the ledger and list its ids instead"
                )
        str_list(gate.get("evidence"), f"gate {name}.evidence", errors)
    for key, names in required.items():
        for name in names:
            if name not in gates:
                errors.append(f"{key} names undefined gate: {name}")


def validate_ledger(ledger: dict, errors: list[str]) -> None:
    rel = "evidence ledger"
    if ledger.get("schemaVersion") != 1:
        errors.append(f"{rel}: schemaVersion must be 1")
    assumptions = ledger.get("assumptions")
    if not isinstance(assumptions, dict):
        errors.append(f"{rel}: assumptions must be an object")
        assumptions = {}
    for aid, entry in assumptions.items():
        where = f"assumption {aid}"
        if not isinstance(entry, dict):
            errors.append(f"{where} must be an object")
            continue
        for key in ("statement", "source", "checked"):
            text_field(entry, key, where, errors)
        if entry.get("kind") not in ASSUMPTION_KINDS:
            errors.append(f"{where}: kind must be one of {sorted(ASSUMPTION_KINDS)}")
        if not is_version(entry.get("version")):
            errors.append(f"{where}: version must be a positive integer")
    records = ledger.get("evidence")
    if not isinstance(records, dict):
        errors.append(f"{rel}: evidence must be an object")
        return
    for eid, rec in records.items():
        validate_record(eid, rec, errors)


def is_version(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def validate_record(eid: str, rec: object, errors: list[str]) -> None:
    where = f"evidence {eid}"
    if not isinstance(rec, dict):
        errors.append(f"{where} must be an object")
        return
    for key in EVIDENCE_TEXT_FIELDS:
        text_field(rec, key, where, errors)
    kind = rec.get("kind")
    if kind not in EVIDENCE_KINDS:
        errors.append(f"{where}: kind must be one of {sorted(EVIDENCE_KINDS)}")
    if rec.get("result") not in EVIDENCE_RESULTS:
        errors.append(f"{where}: result must be one of {sorted(EVIDENCE_RESULTS)}")
    revision = rec.get("sourceRevision")
    if not isinstance(revision, str) or not SHA_RE.match(revision):
        errors.append(f"{where}: sourceRevision must be a full 40 character commit hash")
    elif not resolve_commit(revision):
        errors.append(f"{where}: sourceRevision {short(revision)} is not a commit in this repository")
    scope = str_list(rec.get("scope"), f"{where}.scope", errors)
    if isinstance(rec.get("scope"), list) and not scope:
        errors.append(f"{where}: scope must not be empty (use [\"*\"] for the whole tree)")
    refs = rec.get("assumptions")
    if not isinstance(refs, dict):
        errors.append(f"{where}: assumptions must be an object of id to version")
    else:
        for aid, version in refs.items():
            if not is_version(version):
                errors.append(f"{where}: assumption {aid} version must be a positive integer")
    str_list(rec.get("dependsOn"), f"{where}.dependsOn", errors)
    carries = str_list(rec.get("carries", []), f"{where}.carries", errors)
    if eid in carries:
        errors.append(f"{where}: carries itself")
    invalidated = rec.get("invalidated")
    if invalidated is not None and not (
        isinstance(invalidated, dict)
        and isinstance(invalidated.get("reason"), str)
        and isinstance(invalidated.get("date"), str)
    ):
        errors.append(f"{where}: invalidated must be null or an object with reason and date")
    if kind in INDEPENDENT_KINDS:
        reviewer = rec.get("reviewer")
        if not isinstance(reviewer, str) or not reviewer.strip():
            errors.append(f"{where}: {kind} evidence requires a reviewer")
        elif reviewer.strip().lower() == str(rec.get("author", "")).strip().lower():
            errors.append(f"{where}: reviewer must differ from author")


def find_cycles(graph: dict[str, list[str]]) -> list[list[str]]:
    cycles: list[list[str]] = []
    state: dict[str, int] = {}

    def visit(node: str, path: list[str]) -> None:
        state[node] = 1
        path.append(node)
        for dep in graph.get(node, []):
            if dep not in graph:
                continue
            if state.get(dep) == 1:
                cycles.append(path[path.index(dep):] + [dep])
            elif dep not in state:
                visit(dep, path)
        path.pop()
        state[node] = 2

    for node in graph:
        if node not in state:
            visit(node, [])
    return cycles


def validate_links(state: dict, ledger: dict, errors: list[str]) -> None:
    records = ledger.get("evidence") if isinstance(ledger.get("evidence"), dict) else {}
    assumptions = ledger.get("assumptions") if isinstance(ledger.get("assumptions"), dict) else {}
    for name, gate in (state.get("gates") or {}).items():
        if isinstance(gate, dict) and isinstance(gate.get("evidence"), list):
            for eid in gate["evidence"]:
                if eid not in records:
                    errors.append(f"gate {name} references unknown evidence: {eid}")
    for item in objective_items(state):
        if isinstance(item.get("evidence"), list):
            for eid in item["evidence"]:
                if eid not in records:
                    errors.append(f"objective item {item.get('id')} references unknown evidence: {eid}")
    graph: dict[str, list[str]] = {}
    for eid, rec in records.items():
        if not isinstance(rec, dict):
            continue
        refs = rec.get("assumptions")
        if isinstance(refs, dict):
            for aid in refs:
                if aid not in assumptions:
                    errors.append(f"evidence {eid} references missing assumption: {aid}")
        deps = rec.get("dependsOn")
        if isinstance(deps, list):
            graph[eid] = [d for d in deps if isinstance(d, str)]
            for dep in graph[eid]:
                if dep not in records:
                    errors.append(f"evidence {eid} depends on unknown evidence: {dep}")
        carries = rec.get("carries", [])
        if isinstance(carries, list):
            for cid in (c for c in carries if isinstance(c, str)):
                if cid not in records:
                    errors.append(f"evidence {eid} carries unknown evidence: {cid}")
                elif cid != eid:
                    graph.setdefault(eid, []).append(cid)
    for cycle in find_cycles(graph):
        errors.append("dependsOn/carries cycle: " + " -> ".join(cycle))


def validate_documents(state: dict, trace: dict | None, paths: dict, errors: list[str]) -> None:
    state_only = state.get("stateOnlyPaths") if isinstance(state.get("stateOnlyPaths"), list) else []
    for key in ("rules", "decisions"):
        if paths.get(key) and matches(paths[key], state_only):
            errors.append(f"documents.{key} is in stateOnlyPaths; a change to it changes the premises")
    if paths.get("decisions"):
        text = (ROOT / paths["decisions"]).read_text()
        report_duplicates(DECISION_RE.findall(text), "decision", errors)
    if trace is None:
        return
    rule_ids = RULE_RE.findall((ROOT / paths["rules"]).read_text())
    report_duplicates(rule_ids, "product rule", errors)
    rules = set(rule_ids)
    entries = trace.get("rules")
    if not isinstance(entries, dict):
        errors.append("traceability: rules must be an object")
        return
    for rule in sorted(rules - set(entries)):
        errors.append(f"product rule lacks traceability: {rule}")
    for rule in sorted(set(entries) - rules):
        errors.append(f"traceability references no active product rule: {rule}")
    for rule, entry in entries.items():
        if not isinstance(entry, dict):
            errors.append(f"traceability entry must be an object: {rule}")
            continue
        if not entry.get("type"):
            errors.append(f"traceability rule lacks type: {rule}")
        if not entry.get("status"):
            errors.append(f"traceability rule lacks status: {rule}")
        if entry.get("status") == "implemented" and not entry.get("tests"):
            errors.append(f"implemented rule lacks tests: {rule}")


def analyze() -> tuple[dict | None, dict | None, list[str]]:
    """Load all records and return state, ledger and structural errors."""
    state, ledger, trace, errors, paths = load()
    if state is not None:
        validate_state(state, errors)
    if ledger is not None:
        validate_ledger(ledger, errors)
    if state is not None and ledger is not None:
        validate_links(state, ledger, errors)
    if state is not None and all(paths.get(k) for k in ("rules", "decisions")):
        validate_documents(state, trace, paths, errors)
    return state, ledger, errors


# evidence validity

def _validity(
    eid: str, target: str, state: dict, ledger: dict, memo: dict, stack: list
) -> tuple[bool, str]:
    key = (eid, target)
    if key in memo:
        return memo[key]
    rec = ledger["evidence"].get(eid)
    if rec is None:
        return False, f"evidence {eid} does not exist"
    if key in stack:
        return False, f"dependency cycle through {eid}"
    stack.append(key)
    reasons = _reasons(rec, target, state, ledger, memo, stack)
    stack.pop()
    memo[key] = (not reasons, "; ".join(reasons) or "valid")
    return memo[key]


def _assumption_reasons(rec: dict, ledger: dict, prefix: str = "") -> list[str]:
    reasons = []
    for aid, recorded in rec["assumptions"].items():
        assumption = ledger["assumptions"].get(aid)
        if assumption is None:
            reasons.append(f"{prefix}assumption {aid} no longer exists")
        elif assumption["version"] != recorded:
            reasons.append(
                f"{prefix}assumption {aid} changed (recorded v{recorded}, current v{assumption['version']})"
            )
    return reasons


def _carry_reasons(
    rec: dict, state: dict, ledger: dict, memo: dict, stack: list
) -> list[str]:
    """Reasons a carried record no longer supports `rec`. Scope changes between
    the carried and the carrying revision are not checked; the carrying record's
    analysis covers that diff."""
    reasons = []
    for cid in rec.get("carries", []):
        carried = ledger["evidence"].get(cid)
        label = f"carried {cid}"
        if carried is None:
            reasons.append(f"{label} does not exist")
            continue
        if carried.get("invalidated"):
            reasons.append(f"{label} is invalidated: {carried['invalidated']['reason']}")
        if not is_ancestor(carried["sourceRevision"], rec["sourceRevision"]):
            reasons.append(
                f"{label} sourceRevision {short(carried['sourceRevision'])} "
                f"is not an ancestor of {short(rec['sourceRevision'])}"
            )
        reasons += _assumption_reasons(carried, ledger, f"{label}: ")
        for dep in carried["dependsOn"] + carried.get("carries", []):
            if not _validity(dep, carried["sourceRevision"], state, ledger, memo, stack)[0]:
                reasons.append(f"{label} depends on invalid {dep}")
    return reasons


def _reasons(
    rec: dict, target: str, state: dict, ledger: dict, memo: dict, stack: list
) -> list[str]:
    reasons = []
    invalidated = rec.get("invalidated")
    if invalidated:
        reasons.append(f"invalidated: {invalidated['reason']} ({invalidated['date']})")
    if target == UNBORN:
        return reasons + ["repository has no commits"]
    source = rec["sourceRevision"]
    if not resolve_commit(source):
        reasons.append(f"sourceRevision {short(source)} is not a commit in this repository")
    elif not is_ancestor(source, target):
        reasons.append(f"sourceRevision {short(source)} is not an ancestor of {short(target)}")
    else:
        state_only = state.get("stateOnlyPaths", [])
        hits = [
            path
            for path in changed_paths(source, target)
            if not matches(path, state_only) and matches(path, rec["scope"])
        ]
        if hits:
            suffix = ", ..." if len(hits) > 5 else ""
            reasons.append("scope changed after verification: " + ", ".join(hits[:5]) + suffix)
    reasons += _assumption_reasons(rec, ledger)
    for dep in rec["dependsOn"]:
        if not _validity(dep, target, state, ledger, memo, stack)[0]:
            reasons.append(f"depends on invalid {dep}")
    if resolve_commit(source):
        reasons += _carry_reasons(rec, state, ledger, memo, stack)
    return reasons


def evidence_validity(eid: str, target: str) -> tuple[bool, str]:
    """Return whether evidence record `eid` is valid for commit `target`.

    The reason lists every cause of invalidity, joined with "; "."""
    state, ledger, errors = analyze()
    if errors:
        raise RuntimeError("structural errors: " + "; ".join(errors))
    return _validity(eid, target, state, ledger, {}, [])


def carried_closure(eid: str, ledger: dict) -> list[str]:
    seen: list[str] = []
    pending = list(ledger["evidence"][eid].get("carries", []))
    while pending:
        cid = pending.pop()
        if cid not in seen and cid in ledger["evidence"]:
            seen.append(cid)
            pending += ledger["evidence"][cid].get("carries", [])
    return seen


def evidence_usable(eid: str, target: str, state: dict, ledger: dict, memo: dict) -> tuple[bool, str]:
    """Validity plus result 'pass', for use by gates and objective items."""
    ok, reason = _validity(eid, target, state, ledger, memo, [])
    if not ok:
        return False, f"invalid: {reason}"
    result = ledger["evidence"][eid]["result"]
    if result != "pass":
        return False, f"result is {result}"
    for cid in carried_closure(eid, ledger):
        if ledger["evidence"][cid]["result"] != "pass":
            return False, f"carried {cid} result is {ledger['evidence'][cid]['result']}"
    return True, "valid"


def invalid_evidence(state: dict, ledger: dict, target: str) -> list[tuple[str, str]]:
    memo: dict = {}
    out = []
    for eid in ledger["evidence"]:
        ok, reason = _validity(eid, target, state, ledger, memo, [])
        if not ok:
            out.append((eid, reason))
    return out


# commands

def print_errors(errors: list[str]) -> int:
    for error in errors:
        print(f"ERROR: {error}")
    return 1


def gate_errors(state: dict, ledger: dict, level: str, head: str, dirty: bool) -> tuple[list[str], str | None]:
    errors: list[str] = []
    target = None
    candidate = state.get("candidate")
    if head == UNBORN:
        errors.append("repository has no commits")
    elif not candidate:
        errors.append("candidate commit is not recorded")
    else:
        resolved = resolve_commit(candidate)
        if not resolved:
            errors.append(f"candidate {candidate} does not resolve to a commit")
        elif not is_ancestor(resolved, head):
            errors.append(f"candidate {short(resolved)} is not an ancestor of HEAD {short(head)}")
        else:
            target = resolved
            non_state = [
                path
                for path in changed_paths(resolved, head)
                if not matches(path, state.get("stateOnlyPaths", []))
            ]
            if non_state:
                errors.append("non-state files changed after candidate: " + ", ".join(non_state[:8]))
    if dirty:
        errors.append("working tree is dirty")
    if state.get("activeChange"):
        errors.append("an active change remains open")
    if state.get("openBlockers"):
        errors.append("open blockers remain: " + "; ".join(state["openBlockers"]))
    blocked = {level} if level == "freeze" else {"deploy"}
    for entry in state.get("ownerDecisions", []):
        if entry.get("status") == "open" and blocked & set(entry.get("blocks", [])):
            errors.append(f"open owner decision {entry['id']} blocks {level}: {entry['question']}")
    if level == "deploy":
        objective = state["objective"]
        if objective["status"] != "complete":
            errors.append(f"objective {objective['id']} status is {objective['status']}, not complete")
    if target is None:
        return errors, None
    memo: dict = {}
    key = "requiredFreezeGates" if level == "freeze" else "requiredDeployGates"
    for name in state.get(key, []):
        ids = state["gates"][name]["evidence"]
        if not ids:
            errors.append(f"gate {name} has no evidence")
        for eid in ids:
            ok, reason = evidence_usable(eid, target, state, ledger, memo)
            if not ok:
                errors.append(f"gate {name}: evidence {eid} {reason}")
    if level == "deploy" and state["objective"]["status"] == "complete":
        for item in objective_items(state):
            for eid in item["evidence"]:
                ok, reason = evidence_usable(eid, target, state, ledger, memo)
                if not ok:
                    errors.append(f"objective item {item['id']}: evidence {eid} {reason}")
    return errors, target


def check_gate(level: str) -> int:
    state, ledger, errors = analyze()
    if errors:
        return print_errors(errors)
    branch, head, dirty = current()
    if head != UNBORN:
        for eid, reason in invalid_evidence(state, ledger, head):
            print(f"WARN: evidence {eid} is invalid at {short(head)}: {reason}")
    if level == "working":
        print(OK_WORKING.format(head=head, branch=branch))
        return 0
    errors, target = gate_errors(state, ledger, level, head, dirty)
    if errors:
        return print_errors(errors)
    print(OK_GATE.format(level=level, candidate=target))
    return 0


def count_items(state: dict, group: str) -> str:
    items = state["objective"].get(group, [])
    tally = Counter(item.get("status") for item in items if isinstance(item, dict))
    return ", ".join(f"{tally[s]} {s}" for s in ("verified", "in-progress", "pending"))


def status() -> int:
    state, ledger, errors = analyze()
    if state is None:
        return print_errors(errors)
    branch, head, dirty = current()
    active = state.get("activeChange") or "None"
    if isinstance(active, dict):
        active = active.get("id", "unnamed change")
    blocker = state.get("openBlockers") or ["None"]
    objective = state.get("objective", {})
    open_decisions = [
        d for d in state.get("ownerDecisions", []) if isinstance(d, dict) and d.get("status") == "open"
    ]
    print(f"Phase: {state.get('phase', 'unknown')}")
    print(f"Branch: {branch}")
    print(f"HEAD: {head}")
    print(f"Candidate: {state.get('candidate') or 'None'}")
    if isinstance(objective, dict):
        print(f"Objective: {objective.get('id')} ({objective.get('status')})")
        print(f"Required paths: {count_items(state, 'requiredPaths')}")
        print(f"Deliverables: {count_items(state, 'deliverables')}")
    print(f"Active change: {active}")
    print(f"Blocker: {blocker[0]}")
    print("Open owner decisions: " + (", ".join(d["id"] for d in open_decisions) or "None"))
    if errors:
        print(f"Structural errors: {len(errors)} (run `check --gate working`)")
    elif head == UNBORN:
        print("Invalid evidence: not computed, repository has no commits")
    else:
        bad = invalid_evidence(state, ledger, head)
        print(f"Invalid evidence: {len(bad)}" + (f" ({', '.join(e for e, _ in bad)})" if bad else ""))
    print(f"Working tree: {'dirty' if dirty else 'clean'}")
    print(f"Next: {state.get('nextAction', 'Not recorded')}")
    return 0


def evidence_report() -> int:
    state, ledger, errors = analyze()
    if errors:
        return print_errors(errors)
    _, head, _ = current()
    memo: dict = {}
    for eid, rec in ledger["evidence"].items():
        if head == UNBORN:
            ok, reason = False, "repository has no commits"
        else:
            ok, reason = _validity(eid, head, state, ledger, memo, [])
        claim = rec["claim"] if len(rec["claim"]) <= 70 else rec["claim"][:67] + "..."
        carries = f"  carries {','.join(rec['carries'])}" if rec.get("carries") else ""
        print(f"{eid}  {'valid' if ok else 'invalid'}  {rec['result']}  {reason}{carries}  | {claim}")
    return 0


def handoff() -> int:
    state, ledger, errors = analyze()
    if state is None:
        return print_errors(errors)
    branch, head, dirty = current()
    reads = [STATE_REL]
    docs = state.get("documents")
    if isinstance(docs, dict):
        reads += [p for p in docs.values() if isinstance(p, str)]
    reads += [name for name in ("AGENTS.md", "CLAUDE.md") if (ROOT / name).is_file()]
    print("Resume as the sole active product director.\n")
    print("Read:")
    for path in dict.fromkeys(reads):
        print(f"- {path}")
    print(f"\nVerify branch {branch} and HEAD {head}, then run `python3 script/director.py status`.")
    print(f"Phase: {state.get('phase', 'unknown')}.")
    print(f"Candidate: {state.get('candidate') or 'none'}.")
    print(f"Active change: {state.get('activeChange') or 'none'}.")
    objective = state.get("objective")
    if isinstance(objective, dict):
        print(f"\nObjective {objective.get('id')} ({objective.get('status')}): {objective.get('statement')}")
        print(f"Authority: {objective.get('authority')}")
        unfinished = [
            item
            for group in ("requiredPaths", "deliverables")
            for item in (objective.get(group) or [])
            if isinstance(item, dict) and item.get("status") != "verified"
        ]
        print("Unfinished required paths and deliverables:" + ("" if unfinished else " none"))
        for item in unfinished:
            print(f"- {item.get('id')} [{item.get('status')}]: {item.get('description')}")
    print("\nInvalid evidence:", end="")
    if errors:
        print(" not computed, structural errors:")
        for error in errors:
            print(f"- {error}")
    elif head == UNBORN:
        print(" not computed, repository has no commits")
    else:
        bad = invalid_evidence(state, ledger, head)
        print("" if bad else " none")
        for eid, reason in bad:
            print(f"- {eid}: {reason}")
    print("Open owner decisions:", end="")
    open_decisions = [
        d for d in state.get("ownerDecisions", []) if isinstance(d, dict) and d.get("status") == "open"
    ]
    print("" if open_decisions else " none")
    for entry in open_decisions:
        print(f"- {entry.get('id')} (blocks {', '.join(entry.get('blocks', [])) or 'nothing'}): {entry.get('question')}")
    print(f"\nExact next action: {state.get('nextAction', 'not recorded')}")
    if dirty:
        print("WARNING: The working tree is dirty; inspect it before acting.")
    print(HANDOFF_RULE)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    check_parser = sub.add_parser("check")
    check_parser.add_argument("--gate", choices=["working", "freeze", "deploy"], required=True)
    sub.add_parser("evidence")
    sub.add_parser("handoff")
    args = parser.parse_args()
    try:
        if args.command == "status":
            return status()
        if args.command == "check":
            return check_gate(args.gate)
        if args.command == "evidence":
            return evidence_report()
        return handoff()
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
