#!/usr/bin/env bash
# gate for the deploy step: reads the freeze table in docs/STATUS.md (section 4).
# candidate row: the commit is HEAD or an ancestor of HEAD with only docs/ changed since (the freeze commit adds records).
# every other row: the commit is 7 to 40 hex characters and the result path exists in the tree.
# prints one ok or fail line per row and exits 1 on any fail or any pending cell.
set -uo pipefail
cd "$(dirname "$0")/../.."
head="$(git rev-parse HEAD)"
fail=0
while IFS='|' read -r _ gate commit result _; do
  gate="$(xargs <<<"$gate")"; commit="$(xargs <<<"$commit")"; result="$(xargs <<<"$result")"
  case "$gate" in gate|---*|"") continue ;; esac
  if [ "$gate" = candidate ]; then
    # the candidate is HEAD, or an ancestor of HEAD after which only docs/ changed (the freeze commit adds records)
    if [[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] && git merge-base --is-ancestor "$commit" "$head" 2>/dev/null \
       && [ -z "$(git diff --name-only "$commit" "$head" | grep -v '^docs/')" ]; then echo "ok   $gate $commit"
    else echo "fail $gate: commit '$commit' is not HEAD ${head:0:7} or non docs files changed after it"; fail=1; fi
  elif [[ "$commit" =~ ^[0-9a-f]{7,40}$ && -e "$result" ]]; then echo "ok   $gate $commit $result"
  else echo "fail $gate: commit '$commit' result '$result'"; fail=1; fi
done < <(awk '/^## 4\./{f=1;next} /^## /{f=0} f && /^\|/' docs/STATUS.md)
exit $fail
