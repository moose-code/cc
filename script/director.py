#!/usr/bin/env python3
"""Checker for the repository Project Director records.

Validates record structure and recomputes evidence validity from git history.
A passing check shows the records are internally consistent. It does not show
that the product is correct.
"""

from __future__ import annotations

import argparse
import fnmatch
import functools
import hashlib
import itertools
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
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

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

def git(*args: str, check: bool = True, raw: bool = False) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout if raw else result.stdout.strip()

def by_root(fn):
    """Memoize a function of full commit hashes per repository root."""
    cached = functools.lru_cache(maxsize=None)(lambda root, *args: fn(*args))
    return functools.wraps(fn)(lambda *args: cached(str(ROOT), *args))

def resolve_commit(rev: str) -> str | None:
    if not rev or rev.startswith("-"):
        return None
    return git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check=False) or None

@by_root
def commit_exists(rev: str) -> bool:
    return resolve_commit(rev) is not None

@by_root
def is_ancestor(older: str, newer: str) -> bool:
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", older, newer], cwd=ROOT, capture_output=True
    ).returncode == 0

@by_root
def changed_paths(older: str, newer: str) -> list[str]:
    output = git("diff", "--name-only", "-z", "--no-renames", f"{older}..{newer}", raw=True)
    return [path for path in output.split("\0") if path]

@by_root
def tracked_files(rev: str) -> list[str]:
    return [p for p in git("ls-tree", "-r", "--name-only", "-z", rev, raw=True).split("\0") if p]

@by_root
def blob_digest(rev: str, path: str) -> tuple[str, str | None] | None:
    """Tree mode and sha256 of a file at a commit, or None when the path is not tracked."""
    entry = git("ls-tree", "-z", rev, "--", path, raw=True)
    if not entry:
        return None
    blob = subprocess.run(["git", "cat-file", "blob", f"{rev}:{path}"], cwd=ROOT, capture_output=True)
    return entry.split(" ", 1)[0], hashlib.sha256(blob.stdout).hexdigest() if blob.returncode == 0 else None

def current() -> tuple[str, str, bool]:
    head = git("rev-parse", "--verify", "HEAD", check=False)
    dirty = bool(git("status", "--porcelain"))
    if not head:
        return git("symbolic-ref", "--short", "HEAD", check=False) or "unborn", UNBORN, dirty
    return git("rev-parse", "--abbrev-ref", "HEAD"), head, dirty

def short(sha: str) -> str:
    return sha[:10]

def fmt_paths(paths: list[str]) -> str:
    return ", ".join(paths[:5]) + (", ..." if len(paths) > 5 else "")

@functools.lru_cache(maxsize=None)
def _variants(pattern: str) -> tuple[str, ...]:
    """Expand each '**/' to both 'any directories' and 'zero directories'."""
    parts = pattern.split("**/")
    return tuple(
        "".join(p + j for p, j in zip(parts, joins + ("",)))
        for joins in itertools.product(("**/", ""), repeat=len(parts) - 1)
    )

def matches(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if pattern == "*" or (pattern.endswith("/**") and path.startswith(pattern[:-2])):
            return True
        if any(fnmatch.fnmatchcase(path, variant) for variant in _variants(pattern)):
            return True
    return False

# loading

def _unique_keys(pairs: list[tuple[str, object]]) -> dict:
    out: dict = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate key {key!r}")
        out[key] = value
    return out

def read_json(rel: str, errors: list[str]) -> dict | None:
    try:
        data = json.loads((ROOT / rel).read_text(), object_pairs_hook=_unique_keys)
    except OSError:
        errors.append(f"missing required file: {rel}")
        return None
    except ValueError as exc:
        errors.append(f"{rel}: {exc}")
        return None
    if not isinstance(data, dict):
        errors.append(f"{rel}: top level must be an object")
        return None
    return data

def relative_path(value: object) -> bool:
    return isinstance(value, str) and bool(value) and not Path(value).is_absolute() and ".." not in Path(value).parts

def doc_path(docs: dict, key: str, nullable: bool, errors: list[str]) -> str | None:
    value = docs.get(key, ...)
    if value is ...:
        errors.append(f"documents.{key} is required" + (" (use null to disable)" if nullable else ""))
    elif value is None and nullable:
        return None
    elif not relative_path(value):
        errors.append(f"documents.{key} must be a repository relative path")
    elif not (ROOT / value).is_file():
        errors.append(f"missing required file: {value}")
    else:
        return value
    return None

def load() -> tuple[dict | None, dict | None, dict | None, list[str], dict]:
    """Return state, evidence ledger, traceability, errors, resolved document paths."""
    errors: list[str] = []
    state = read_json(STATE_REL, errors)
    ledger = trace = None
    paths: dict[str, str | None] = {}
    if state is not None and (
        state.get("schemaVersion") != 2 or "documents" not in state or "objective" not in state
    ):
        found = (
            f"is schema {state.get('schemaVersion', 1)}"
            if state.get("schemaVersion") != 2
            else "lacks documents or objective"
        )
        errors.append(
            f"director-state.json {found}; this checker needs schema 2: "
            "migrate: see the skill's SKILL.md (Start, older installed checker)"
        )
        state = None
    if state is not None:
        if not isinstance(state["documents"], dict):
            errors.append("documents must be an object")
        else:
            for key, nullable in (
                ("rules", False), ("decisions", False), ("state", False),
                ("traceability", True), ("evidence", False),
            ):
                paths[key] = doc_path(state["documents"], key, nullable, errors)
            ledger = read_json(paths["evidence"], errors) if paths["evidence"] else None
            trace = read_json(paths["traceability"], errors) if paths["traceability"] else None
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

def is_version(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1

def dicts(value: object) -> list[dict]:
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []

def objective_items(state: dict) -> list[dict]:
    objective = state.get("objective")
    if not isinstance(objective, dict):
        return []
    return dicts(objective.get("requiredPaths")) + dicts(objective.get("deliverables"))

def check_entries(entries: object, where: str, status_values: set, errors: list[str]) -> list[dict]:
    """Validate a list of {id, status, ...} objects and return the well-formed ones."""
    if not isinstance(entries, list):
        errors.append(f"{where} must be a list")
        return []
    valid = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"{where}[{index}] must be an object")
            continue
        text_field(entry, "id", f"{where}[{index}]", errors)
        if entry.get("status") not in status_values:
            errors.append(f"{where}[{index}]: status must be one of {sorted(status_values)}")
        valid.append(entry)
    return valid

def validate_objective(state: dict, errors: list[str]) -> None:
    objective = state["objective"]
    if not isinstance(objective, dict):
        errors.append("objective must be an object")
        return
    for key in ("id", "statement", "authority"):
        text_field(objective, key, "objective", errors)
    status = objective.get("status")
    if status not in OBJECTIVE_STATUS:
        errors.append(f"objective: status must be one of {sorted(OBJECTIVE_STATUS)}")
    str_list(objective.get("boundaries"), "objective.boundaries", errors)
    items = []
    for group in ("requiredPaths", "deliverables"):
        entries = check_entries(objective.get(group), f"objective.{group}", ITEM_STATUS, errors)
        if status == "complete" and not entries:
            errors.append(f"objective is complete but {group} is empty")
        items += entries
    report_duplicates([i["id"] for i in items if isinstance(i.get("id"), str)], "objective item", errors)
    for item in items:
        text_field(item, "description", f"objective item {item.get('id')}", errors)
        evidence = str_list(item.get("evidence"), f"objective item {item.get('id')}.evidence", errors)
        if item.get("status") == "verified" and not evidence:
            errors.append(f"objective item {item.get('id')} is verified but lists no evidence")
        if status == "complete" and item.get("status") != "verified":
            errors.append(f"objective is complete but {item.get('id')} is not verified")

def validate_owner_decisions(state: dict, errors: list[str]) -> None:
    entries = check_entries(state["ownerDecisions"], "ownerDecisions", OWNER_DECISION_STATUS, errors)
    report_duplicates([e["id"] for e in entries if isinstance(e.get("id"), str)], "ownerDecisions", errors)
    for entry in entries:
        text_field(entry, "question", f"ownerDecision {entry.get('id')}", errors)
        str_list(entry.get("blocks", []), f"ownerDecision {entry.get('id')}.blocks", errors)

def validate_state(state: dict, errors: list[str]) -> None:
    for key in ("projectName", "riskLevel", "phase", "nextAction"):
        text_field(state, key, STATE_REL, errors)
    for key in ("candidate", "candidatePolicy"):
        if not isinstance(state.get(key), (type(None), str)):
            errors.append(f"{key} must be null or a string")
    if not isinstance(state.get("activeChange"), (type(None), str, dict)):
        errors.append("activeChange must be null, a string or an object")
    required = {}
    for key in ("openBlockers", "stateOnlyPaths", "requiredFreezeGates", "requiredDeployGates"):
        required[key] = str_list(state.get(key), key, errors)
        if key.startswith("required") and isinstance(state.get(key), list) and not required[key]:
            errors.append(f"{key} must not be empty")
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
        if not isinstance(gate.get("kinds"), list) or not gate["kinds"]:
            errors.append(f"gate {name} has no kinds; list the evidence kinds that can satisfy it")
            continue
        for kind in str_list(gate["kinds"], f"gate {name}.kinds", errors):
            if kind == "analysis":
                errors.append(f"gate {name}: analysis cannot be a gate kind")
            elif kind not in EVIDENCE_KINDS:
                errors.append(f"gate {name}: unknown kind {kind}")
    for key in ("requiredFreezeGates", "requiredDeployGates"):
        errors += [f"{key} names undefined gate: {n}" for n in required[key] if n not in gates]

def validate_ledger(ledger: dict, errors: list[str]) -> None:
    if ledger.get("schemaVersion") != 1:
        errors.append("evidence ledger: schemaVersion must be 1")
    for field in ("assumptions", "evidence"):
        if not isinstance(ledger.get(field), dict):
            errors.append(f"evidence ledger: {field} must be an object")
            return
    for aid, entry in ledger["assumptions"].items():
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
    for eid, rec in ledger["evidence"].items():
        validate_record(eid, rec, errors)

def identity(name: object) -> str:
    """Comparison form of an author or reviewer name."""
    return " ".join(str(name).casefold().split())

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
    known = isinstance(revision, str) and bool(SHA_RE.match(revision))
    if not known:
        errors.append(f"{where}: sourceRevision must be a full commit hash (40 or 64 hex)")
    elif not commit_exists(revision):
        errors.append(f"{where}: sourceRevision {short(revision)} is not a commit in this repository")
        known = False
    scope = str_list(rec.get("scope"), f"{where}.scope", errors)
    if isinstance(rec.get("scope"), list) and not scope:
        errors.append(f"{where}: scope must not be empty (use [\"*\"] for the whole tree)")
    if known:
        files = tracked_files(revision)
        for pattern in scope:
            if pattern != "*" and not any(matches(f, [pattern]) for f in files):
                errors.append(f"{where}: scope pattern {pattern} matches no file tracked at {short(revision)}")
    refs = rec.get("assumptions")
    if not isinstance(refs, dict):
        errors.append(f"{where}: assumptions must be an object of id to version")
    else:
        errors += [
            f"{where}: assumption {aid} version must be a positive integer"
            for aid, version in refs.items()
            if not is_version(version)
        ]
    str_list(rec.get("dependsOn"), f"{where}.dependsOn", errors)
    str_list(rec.get("carries", []), f"{where}.carries", errors)
    str_list(rec.get("carriedChanges", []), f"{where}.carriedChanges", errors)
    invalidated = rec.get("invalidated")
    if invalidated is not None and not (
        isinstance(invalidated, dict)
        and isinstance(invalidated.get("reason"), str)
        and isinstance(invalidated.get("date"), str)
    ):
        errors.append(f"{where}: invalidated must be null or an object with reason and date")
    report = rec.get("report")
    if report is None and kind in INDEPENDENT_KINDS:
        errors.append(f"{where}: {kind} evidence requires a report {{path, sha256, revision}}")
    elif report is not None and not (
        isinstance(report, dict)
        and relative_path(report.get("path"))
        and isinstance(report.get("sha256"), str)
        and SHA256_RE.match(report["sha256"])
        and isinstance(report.get("revision"), str)
        and SHA_RE.match(report["revision"])
    ):
        errors.append(
            f"{where}: report must be {{path: repository relative path, sha256: 64 hex, "
            "revision: commit that added the report}"
        )
    elif report is not None and not commit_exists(report["revision"]):
        errors.append(f"{where}: report revision {short(report['revision'])} is not a commit in this repository")
    if kind in INDEPENDENT_KINDS:
        reviewer = rec.get("reviewer")
        if not isinstance(reviewer, str) or not reviewer.strip():
            errors.append(f"{where}: {kind} evidence requires a reviewer")
        elif identity(reviewer) == identity(rec.get("author", "")):
            errors.append(f"{where}: reviewer must differ from author")

def find_cycles(graph: dict[str, list[str]]) -> list[list[str]]:
    """One id path per distinct set of records that form a cycle."""
    cycles: list[list[str]] = []
    for start in graph:
        stack, seen = [(start, [start])], set()
        while stack:
            node, path = stack.pop()
            for dep in graph.get(node, []):
                if dep == start and not any(set(path) == set(c) for c in cycles):
                    cycles.append(path + [start])
                elif dep not in seen and dep != start:
                    seen.add(dep)
                    stack.append((dep, path + [dep]))
    return cycles

def validate_links(state: dict, ledger: dict, errors: list[str]) -> None:
    records, assumptions = ledger["evidence"], ledger["assumptions"]
    references = [(f"gate {n}", g["evidence"]) for n, g in state["gates"].items()]
    references += [(f"objective item {i.get('id')}", i["evidence"]) for i in objective_items(state)]
    for owner, ids in references:
        errors += [f"{owner} references unknown evidence: {e}" for e in ids if e not in records]
    graph: dict[str, list[str]] = {}
    for eid, rec in records.items():
        errors += [
            f"evidence {eid} references missing assumption: {a}" for a in rec["assumptions"] if a not in assumptions
        ]
        report = rec.get("report")
        if report and matches(report["path"], rec["scope"]) and not matches(report["path"], state["stateOnlyPaths"]):
            errors.append(f"evidence {eid}: report {report['path']} matches the record's scope; adding it would invalidate the record")
        graph[eid] = []
        for dep in rec["dependsOn"]:
            if dep not in records:
                errors.append(f"evidence {eid} depends on unknown evidence: {dep}")
            graph[eid].append(dep)
        for cid in rec.get("carries", []):
            if cid == eid:
                errors.append(f"evidence {eid}: carries itself")
            elif cid not in records:
                errors.append(f"evidence {eid} carries unknown evidence: {cid}")
            else:
                graph[eid].append(cid)
                if "*" not in rec["scope"]:
                    errors += [
                        f"evidence {eid}: scope does not cover carried {cid} pattern {p}"
                        for p in records[cid]["scope"]
                        if p not in rec["scope"]
                    ]
    validate_state_only_scopes(state, records, errors)
    errors += ["dependsOn/carries cycle: " + " -> ".join(c) for c in find_cycles(graph)]

def validate_state_only_scopes(state: dict, records: dict, errors: list[str]) -> None:
    """A stateOnlyPaths entry must not match a tracked file that an evidence scope names."""
    revisions = {resolve_commit("HEAD")} | {rec["sourceRevision"] for rec in records.values()}
    files = sorted({f for rev in revisions if rev for f in tracked_files(rev)})
    for entry in state["stateOnlyPaths"]:
        hidden = [f for f in files if matches(f, [entry])]
        for eid, rec in records.items():
            patterns = [p for p in rec["scope"] if p != "*"]
            hit = next((f for f in hidden if matches(f, patterns)), None)
            if hit:
                errors.append(f"stateOnlyPaths entry {entry} hides {hit}, which evidence {eid} scope covers")

def decision_pattern(state: dict) -> re.Pattern:
    custom = state["documents"].get("decisionIdPattern")
    if custom is None:
        return DECISION_RE
    pattern = re.compile(custom, re.MULTILINE)
    if pattern.groups != 1:
        raise ValueError("expected exactly one capture group")
    return pattern

def decision_warnings(state: dict) -> list[str]:
    rel = state["documents"]["decisions"]
    text = (ROOT / rel).read_text()
    if text.strip() and not decision_pattern(state).findall(text):
        return [f"{rel} is non-empty but matches no decision ids; check documents.decisionIdPattern"]
    return []

def validate_documents(state: dict, trace: dict | None, paths: dict, errors: list[str]) -> None:
    for key in ("rules", "decisions"):
        if matches(paths[key], state["stateOnlyPaths"]):
            errors.append(f"documents.{key} is in stateOnlyPaths; a change to it changes the premises")
    try:
        pattern = decision_pattern(state)
    except (re.error, TypeError, ValueError) as exc:
        errors.append(f"documents.decisionIdPattern is not a regex with one group: {exc}")
    else:
        report_duplicates(pattern.findall((ROOT / paths["decisions"]).read_text()), "decision", errors)
    if trace is None:
        return
    rule_ids = RULE_RE.findall((ROOT / paths["rules"]).read_text())
    report_duplicates(rule_ids, "product rule", errors)
    entries = trace.get("rules")
    if not isinstance(entries, dict):
        errors.append("traceability: rules must be an object")
        return
    errors += [f"product rule lacks traceability: {r}" for r in sorted(set(rule_ids) - set(entries))]
    errors += [f"traceability references no active product rule: {r}" for r in sorted(set(entries) - set(rule_ids))]
    for rule, entry in entries.items():
        if not isinstance(entry, dict):
            errors.append(f"traceability entry must be an object: {rule}")
            continue
        errors += [f"traceability rule lacks {key}: {rule}" for key in ("type", "status") if not entry.get(key)]
        if entry.get("status") == "implemented" and not entry.get("tests"):
            errors.append(f"implemented rule lacks tests: {rule}")

def analyze() -> tuple[dict | None, dict | None, list[str]]:
    """Load all records and return state, ledger and structural errors."""
    state, ledger, trace, errors, paths = load()
    if state is not None:
        validate_state(state, errors)
    if ledger is not None:
        validate_ledger(ledger, errors)
    if not errors:
        validate_links(state, ledger, errors)
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
        current_version = ledger["assumptions"].get(aid, {}).get("version")
        if current_version is None:
            reasons.append(f"{prefix}assumption {aid} no longer exists")
        elif current_version != recorded:
            reasons.append(f"{prefix}assumption {aid} changed (recorded v{recorded}, current v{current_version})")
    return reasons

def _report_reasons(rec: dict, target: str, prefix: str = "") -> list[str]:
    """The report must be committed at `revision` (a descendant of the record's
    sourceRevision and an ancestor of the target) and hash to its sha256 there, at the
    target, and in the working tree when the target is HEAD. Symlinks are rejected."""
    report = rec.get("report")
    if not report:
        return []
    path, want, revision = report["path"], report["sha256"], report["revision"]
    reasons = []
    if not is_ancestor(rec["sourceRevision"], revision):
        reasons.append(f"{prefix}report revision {short(revision)} is not a descendant of sourceRevision {short(rec['sourceRevision'])}")
    if not is_ancestor(revision, target):
        reasons.append(f"{prefix}report revision {short(revision)} is not an ancestor of {short(target)}")
    for label, rev in (("report revision", revision), ("target", target)):
        seen = blob_digest(rev, path)
        if seen is None or seen[1] is None or seen[0] not in {"100644", "100755"}:
            reasons.append(f"{prefix}report {path} is not a regular tracked file at {label}")
        elif seen[1] != want:
            reasons.append(f"{prefix}report {path} at {label} differs from the recorded sha256")
    if target == resolve_commit("HEAD"):
        file = ROOT / path
        if file.is_symlink() or not file.is_file():
            reasons.append(f"{prefix}report {path} is not a regular file in the working tree")
        elif hashlib.sha256(file.read_bytes()).hexdigest() != want:
            reasons.append(f"{prefix}report {path} in the working tree differs from the recorded sha256")
    return list(dict.fromkeys(reasons))


def _carry_reasons(rec: dict, target: str, state: dict, ledger: dict, memo: dict, stack: list) -> list[str]:
    """Reasons the carried records no longer support `rec`.

    Every review or acceptance record in the carried closure stays valid only if
    nothing in its scope changed up to the carrier's revision. Changes in the
    scope of other carried kinds must equal the carrier's `carriedChanges`."""
    reasons = []
    for cid in rec.get("carries", []):
        carried = ledger["evidence"][cid]
        label = f"carried {cid}"
        if carried.get("invalidated"):
            reasons.append(f"{label} is invalidated: {carried['invalidated']['reason']}")
        if not is_ancestor(carried["sourceRevision"], rec["sourceRevision"]):
            reasons.append(
                f"{label} sourceRevision {short(carried['sourceRevision'])} "
                f"is not an ancestor of {short(rec['sourceRevision'])}"
            )
        reasons += _assumption_reasons(carried, ledger, f"{label}: ")
        reasons += [
            f"{label} depends on invalid {dep}"
            for dep in carried["dependsOn"] + carried.get("carries", [])
            if not _validity(dep, carried["sourceRevision"], state, ledger, memo, stack)[0]
        ]
    enumerated: set[str] = set()
    for cid, paths in carried_changes(rec, ledger, state).items():
        kind = ledger["evidence"][cid]["kind"]
        reasons += _report_reasons(ledger["evidence"][cid], target, f"carried {cid}: ")
        if kind not in INDEPENDENT_KINDS:
            enumerated.update(paths)
        elif paths:
            reasons.append(f"carried {kind} {cid}: reviewed scope changed: {fmt_paths(paths)}")
    listed = set(rec.get("carriedChanges", []))
    missing, extra = sorted(enumerated - listed), sorted(listed - enumerated)
    if missing or extra:
        parts = ([f"missing {', '.join(missing)}"] if missing else []) + (
            [f"extra {', '.join(extra)}"] if extra else []
        )
        reasons.append("carriedChanges differs from changed carried scope: " + "; ".join(parts))
    return reasons

def _reasons(rec: dict, target: str, state: dict, ledger: dict, memo: dict, stack: list) -> list[str]:
    reasons = []
    if rec.get("invalidated"):
        reasons.append(f"invalidated: {rec['invalidated']['reason']} ({rec['invalidated']['date']})")
    if target == UNBORN:
        return reasons + ["repository has no commits"]
    source = rec["sourceRevision"]
    if not is_ancestor(source, target):
        reasons.append(f"sourceRevision {short(source)} is not an ancestor of {short(target)}")
    else:
        hits = [
            p for p in changed_paths(source, target)
            if not matches(p, state["stateOnlyPaths"]) and matches(p, rec["scope"])
        ]
        if hits:
            reasons.append("scope changed after verification: " + fmt_paths(hits))
    reasons += _assumption_reasons(rec, ledger)
    reasons += _report_reasons(rec, target)
    reasons += [
        f"depends on invalid {dep}"
        for dep in rec["dependsOn"]
        if not _validity(dep, target, state, ledger, memo, stack)[0]
    ]
    return reasons + _carry_reasons(rec, target, state, ledger, memo, stack)

def evidence_validity(eid: str, target: str) -> tuple[bool, str]:
    """Return whether evidence record `eid` is valid for commit `target`.

    The reason lists every cause of invalidity, joined with "; "."""
    state, ledger, errors = analyze()
    if errors:
        raise RuntimeError("structural errors: " + "; ".join(errors))
    return _validity(eid, target, state, ledger, {}, [])

def closure_from(start: list[str], ledger: dict) -> list[str]:
    """Records reachable through `carries`, starting from the ids in `start`."""
    seen: list[str] = []
    pending = list(start)
    while pending:
        cid = pending.pop()
        if cid not in seen and cid in ledger["evidence"]:
            seen.append(cid)
            pending += ledger["evidence"][cid].get("carries", [])
    return seen

def effective_kinds(eid: str, ledger: dict, seen: tuple = ()) -> set[str]:
    """Kind a record counts as for a gate. An analysis record counts as the kinds of
    the records it carries, or as analysis when it carries none."""
    rec = ledger["evidence"][eid]
    carried = [c for c in rec.get("carries", []) if c not in seen]
    if rec["kind"] != "analysis" or not carried:
        return {rec["kind"]}
    return set().union(*(effective_kinds(c, ledger, seen + (eid,)) for c in carried))

def evidence_usable(eid: str, target: str, state: dict, ledger: dict, memo: dict) -> tuple[bool, str]:
    """Validity plus result 'pass', for use by gates and objective items."""
    ok, reason = _validity(eid, target, state, ledger, memo, [])
    if not ok:
        return False, f"invalid: {reason}"
    if ledger["evidence"][eid]["result"] != "pass":
        return False, f"result is {ledger['evidence'][eid]['result']}"
    for cid in closure_from(ledger["evidence"][eid].get("carries", []), ledger):
        if ledger["evidence"][cid]["result"] != "pass":
            return False, f"carried {cid} result is {ledger['evidence'][cid]['result']}"
    return True, "valid"

def carried_changes(rec: dict, ledger: dict, state: dict) -> dict[str, list[str]]:
    """Per record in the carried closure, paths in its scope that changed between its
    own revision and the carrier's revision."""
    out = {}
    for cid in closure_from(rec.get("carries", []), ledger):
        carried = ledger["evidence"][cid]
        out[cid] = [
            p for p in changed_paths(carried["sourceRevision"], rec["sourceRevision"])
            if matches(p, carried["scope"]) and not matches(p, state["stateOnlyPaths"])
        ]
    return out

def invalid_evidence(state: dict | None, ledger: dict | None, errors: list[str], head: str) -> tuple[str, list]:
    """(why evidence was not checked, [(id, reason)] for invalid records)."""
    if errors:
        return "not computed, structural errors", []
    if head == UNBORN:
        return "not computed, repository has no commits", []
    memo: dict = {}
    results = [(eid, _validity(eid, head, state, ledger, memo, [])) for eid in ledger["evidence"]]
    return "", [(eid, reason) for eid, (ok, reason) in results if not ok]

# gate lock

def policy_hash(state: dict) -> str:
    """Hash of the gate policy: required gates, every gate's kinds and the state-only paths."""
    policy = {k: state[k] for k in ("requiredFreezeGates", "requiredDeployGates", "stateOnlyPaths")}
    policy["kinds"] = {name: gate["kinds"] for name, gate in state["gates"].items()}
    return hashlib.sha256(json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def freeze_candidate(commit: str) -> int:
    state, _, errors = analyze()
    if errors:
        return print_errors(errors)
    sha, head = resolve_commit(commit), resolve_commit("HEAD")
    if not sha or not head or not is_ancestor(sha, head):
        return print_errors([f"{commit} is not a commit reachable from HEAD"])
    state["candidate"], state["candidatePolicy"] = sha, policy_hash(state)
    (ROOT / STATE_REL).write_text(json.dumps(state, indent=2) + "\n")
    print(f"Recorded candidate {sha} and gate policy {state['candidatePolicy'][:12]} in {STATE_REL}.")
    print("Commit the state file. Editing the gate policy afterwards fails freeze and deploy until re-frozen.")
    return 0

# commands

def print_errors(errors: list[str]) -> int:
    for error in errors:
        print(f"ERROR: {error}")
    return 1

def gate_errors(state: dict, ledger: dict, level: str, head: str, dirty: bool) -> tuple[list[str], str | None]:
    errors: list[str] = []
    target = None
    candidate = state.get("candidate")
    resolved = resolve_commit(candidate) if candidate else None
    if head == UNBORN:
        errors.append("repository has no commits")
    elif not candidate:
        errors.append("candidate commit is not recorded")
    elif not resolved:
        errors.append(f"candidate {candidate} does not resolve to a commit")
    elif not is_ancestor(resolved, head):
        errors.append(f"candidate {short(resolved)} is not an ancestor of HEAD {short(head)}")
    else:
        target = resolved
        non_state = [p for p in changed_paths(resolved, head) if not matches(p, state["stateOnlyPaths"])]
        if non_state:
            errors.append("non-state files changed after candidate: " + ", ".join(non_state[:8]))
    if candidate and not state.get("candidatePolicy"):
        errors.append("candidatePolicy is not recorded; set the candidate with `python3 script/director.py freeze <commit>`")
    elif candidate and state["candidatePolicy"] != policy_hash(state):
        errors.append("gate policy changed after freeze: re-freeze deliberately")
    if dirty:
        errors.append("working tree is dirty")
    if state.get("activeChange"):
        errors.append("an active change remains open")
    if state["openBlockers"]:
        errors.append("open blockers remain: " + "; ".join(state["openBlockers"]))
    blocked = {"freeze"} if level == "freeze" else {"freeze", "deploy"}
    for entry in state["ownerDecisions"]:
        if entry["status"] == "open" and blocked & set(entry.get("blocks", [])):
            errors.append(f"open owner decision {entry['id']} blocks {level}: {entry['question']}")
    objective = state["objective"]
    if level == "deploy" and objective["status"] != "complete":
        errors.append(f"objective {objective['id']} status is {objective['status']}, not complete")
    if target is None:
        return errors, None
    names = state["requiredFreezeGates" if level == "freeze" else "requiredDeployGates"]
    owners = [(f"gate {n}", state["gates"][n]["evidence"]) for n in names]
    for name in names:
        gate = state["gates"][name]
        if not gate["evidence"]:
            errors.append(f"gate {name} has no evidence")
        for eid in gate["evidence"]:
            held = effective_kinds(eid, ledger)
            if not held <= set(gate["kinds"]):
                errors.append(
                    f"gate {name}: evidence {eid} has kind {', '.join(sorted(held))}; "
                    f"gate accepts {', '.join(gate['kinds'])}"
                )
    if level == "deploy" and objective["status"] == "complete":
        owners += [(f"objective item {i['id']}", i["evidence"]) for i in objective_items(state)]
    memo: dict = {}
    for owner, ids in owners:
        for eid in ids:
            ok, reason = evidence_usable(eid, target, state, ledger, memo)
            if not ok:
                errors.append(f"{owner}: evidence {eid} {reason}")
    return errors, target

def check_gate(level: str) -> int:
    state, ledger, errors = analyze()
    if errors:
        return print_errors(errors)
    branch, head, dirty = current()
    for warning in decision_warnings(state):
        print(f"WARN: {warning}")
    for eid, reason in invalid_evidence(state, ledger, errors, head)[1]:
        print(f"WARN: evidence {eid} is invalid at {short(head)}: {reason}")
    if level == "working":
        print(OK_WORKING.format(head=head, branch=branch))
        return 0
    errors, target = gate_errors(state, ledger, level, head, dirty)
    if errors:
        return print_errors(errors)
    print(OK_GATE.format(level=level, candidate=target))
    return 0

def open_decisions(state: dict) -> list[dict]:
    return [d for d in dicts(state.get("ownerDecisions")) if d.get("status") == "open"]

def status() -> int:
    state, ledger, errors = analyze()
    if state is None:
        return print_errors(errors)
    branch, head, dirty = current()
    active = state.get("activeChange") or "None"
    objective = state.get("objective") if isinstance(state.get("objective"), dict) else {}
    why, bad = invalid_evidence(state, ledger, errors, head)
    lines = [
        f"Phase: {state.get('phase', 'unknown')}",
        f"Branch: {branch}",
        f"HEAD: {head}",
        f"Candidate: {state.get('candidate') or 'None'}",
        f"Objective: {objective.get('id')} ({objective.get('status')})",
    ]
    for label, group in (("Required paths", "requiredPaths"), ("Deliverables", "deliverables")):
        tally = Counter(item.get("status") for item in dicts(objective.get(group)))
        lines.append(f"{label}: " + ", ".join(f"{tally[s]} {s}" for s in ("verified", "in-progress", "pending")))
    lines += [
        f"Active change: {active.get('id', 'unnamed change') if isinstance(active, dict) else active}",
        f"Blocker: {(state.get('openBlockers') or ['None'])[0]}",
        "Open owner decisions: " + (", ".join(str(d.get("id")) for d in open_decisions(state)) or "None"),
        "Invalid evidence: " + (why or f"{len(bad)}" + (f" ({', '.join(e for e, _ in bad)})" if bad else "")),
        f"Working tree: {'dirty' if dirty else 'clean'}",
        f"Next: {state.get('nextAction', 'Not recorded')}",
    ]
    print("\n".join(lines))
    return 0

def evidence_report() -> int:
    state, ledger, errors = analyze()
    if errors:
        return print_errors(errors)
    _, head, _ = current()
    memo: dict = {}
    for eid, rec in ledger["evidence"].items():
        ok, reason = (False, "repository has no commits") if head == UNBORN else _validity(eid, head, state, ledger, memo, [])
        extras = [f"reviewer {rec['reviewer']}"] if rec["kind"] in INDEPENDENT_KINDS else []
        extras += [f"report {rec['report']['path']}"] if rec.get("report") else []
        extras += [f"carries {','.join(rec['carries'])}"] if rec.get("carries") else []
        extras += [
            f"changed under {cid} scope: {fmt_paths(paths)}"
            for cid, paths in carried_changes(rec, ledger, state).items() if paths
        ]
        claim = rec["claim"] if len(rec["claim"]) <= 70 else rec["claim"][:67] + "..."
        print(f"{eid}  {'valid' if ok else 'invalid'}  {rec['result']}  {reason}" + "".join(f"  {e}" for e in extras) + f"  | {claim}")
    return 0

def handoff() -> int:
    state, ledger, errors = analyze()
    if state is None:
        return print_errors(errors)
    branch, head, dirty = current()
    docs = state.get("documents")
    reads = [STATE_REL] + [p for k, p in (docs.items() if isinstance(docs, dict) else []) if k != "decisionIdPattern" and isinstance(p, str)]
    reads += [name for name in ("AGENTS.md", "CLAUDE.md") if (ROOT / name).is_file()]
    objective = state.get("objective") if isinstance(state.get("objective"), dict) else {}
    unfinished = [i for i in objective_items(state) if i.get("status") != "verified"]
    why, bad = invalid_evidence(state, ledger, errors, head)
    lines = ["Resume as the sole active product director.", "", "Read:"] + [f"- {p}" for p in dict.fromkeys(reads)]
    lines += [
        "",
        f"Verify branch {branch} and HEAD {head}, then run `python3 script/director.py status`.",
        f"Phase: {state.get('phase', 'unknown')}.",
        f"Candidate: {state.get('candidate') or 'none'}.",
        f"Active change: {state.get('activeChange') or 'none'}.",
        "",
        f"Objective {objective.get('id')} ({objective.get('status')}): {objective.get('statement')}",
        f"Authority: {objective.get('authority')}",
        "Unfinished required paths and deliverables:" + ("" if unfinished else " none"),
    ]
    lines += [f"- {i.get('id')} [{i.get('status')}]: {i.get('description')}" for i in unfinished]
    lines += ["", "Structural errors:"] * bool(errors) + [f"- {e}" for e in errors]
    lines += ["Invalid evidence:" + (f" {why}" if why else "" if bad else " none")]
    lines += [f"- {eid}: {reason}" for eid, reason in bad]
    pending = open_decisions(state)
    lines += ["Open owner decisions:" + ("" if pending else " none")]
    lines += [f"- {d.get('id')} (blocks {', '.join(d.get('blocks', [])) or 'nothing'}): {d.get('question')}" for d in pending]
    lines += ["", f"Exact next action: {state.get('nextAction', 'not recorded')}"]
    lines += ["WARNING: The working tree is dirty; inspect it before acting."] * dirty + [HANDOFF_RULE]
    print("\n".join(lines))
    return 0

def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check").add_argument("--gate", choices=["working", "freeze", "deploy"], required=True)
    sub.add_parser("freeze").add_argument("commit")
    for name in ("status", "evidence", "handoff"):
        sub.add_parser(name)
    args = parser.parse_args()
    commands = {
        "status": status,
        "evidence": evidence_report,
        "handoff": handoff,
        "check": lambda: check_gate(args.gate),
        "freeze": lambda: freeze_candidate(args.commit),
    }
    try:
        return commands[args.command]()
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
