#!/usr/bin/env bash
# PreToolUse hook for the Bash tool. Refuses a whole-suite `forge test` and any
# INVARIANT_DEEP=1 run unless the command carries CANDIDATE_RUN=1. Rule source:
# AGENTS.md, "the full suite, the deep invariants and the rehearsal run once, on the
# frozen candidate". Per change: `forge build` and `forge test --match-path <files>`.
cmd=$(jq -r '.tool_input.command // empty')
deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
case "$cmd" in *CANDIDATE_RUN=1*) exit 0 ;; esac
if printf '%s' "$cmd" | grep -Eq 'INVARIANT_DEEP=1'; then
  deny "deep invariant runs belong to the frozen candidate only. add CANDIDATE_RUN=1 only for that single candidate run (AGENTS.md)."
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])forge[[:space:]]+test([[:space:]]|$)'; then
  if ! printf '%s' "$cmd" | grep -Eq -- '--(match-path|mp|match-test|mt|match-contract|mc)([[:space:]=]|$)'; then
    deny "a whole-suite forge test runs once, on the frozen candidate. per change use forge test --match-path <the test files you touched>. the candidate run carries CANDIDATE_RUN=1 (AGENTS.md)."
  fi
fi
exit 0
