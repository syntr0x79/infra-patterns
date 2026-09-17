#!/usr/bin/env bash
# Tests for watchdog.sh.
#
# The script's whole job is deciding whether to touch production, so the
# decisions are what get tested. `kubectl` and `curl` are replaced with stubs
# that serve fixture JSON and record what they were asked to do; each scenario
# then asserts on the decision, not on the plumbing.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
STUBS="$PWD/stubs"
export PATH="$STUBS:$PATH"

pass=0
fail=0

check() {  # check <description> <expected substring> <output>
  if echo "$3" | grep -qF "$2"; then
    echo "  ok   $1"
    pass=$((pass + 1))
  else
    echo "  FAIL $1"
    echo "       expected to find: $2"
    echo "       actual output:"
    echo "$3" | sed 's/^/         /'
    fail=$((fail + 1))
  fi
}

run() {  # run <fixture dir> -> stdout+stderr; call log lands in $CALLS
  export FIXTURE="$PWD/fixtures/$1"
  CALLS="$(mktemp)"; export CALLS
  NAMESPACE=prod \
  ANCHOR_LABEL=app=queue \
  PATRONI_MEMBERS="db-1=http://db-1:8008,db-2=http://db-2:8008" \
  MEMBER_ZONES="db-1=site-a,db-2=site-b" \
  PINNED_DEPLOYMENTS="prod/api" \
  COOLDOWN_SECONDS=1800 \
  sh "$ROOT/watchdog.sh" 2>&1
}

echo "zone watchdog"

# 1. Leader already sits where the anchor is: the script must do nothing.
out=$(run aligned; echo "__CALLS__$CALLS")
calls_file=$(echo "$out" | sed -n 's/^__CALLS__//p')
out=$(echo "$out" | grep -v '^__CALLS__')
check "aligned cluster is left alone" "leader already in the anchor zone" "$out"
if grep -q switchover "$calls_file" 2>/dev/null; then
  echo "  FAIL aligned cluster must not call switchover"; fail=$((fail + 1))
else
  echo "  ok   aligned cluster made no switchover call"; pass=$((pass + 1))
fi

# 2. Anchor moved to the other site, cluster healthy: switch the leader over.
out=$(run misaligned-healthy)
check "misaligned cluster switches over" "switching over: db-1 (site-a) -> db-2 (site-b)" "$out"
check "switchover is accepted" "switchover accepted" "$out"

# 3. Same, but a replica is behind. Promoting it would trade latency for data
#    loss — the script must refuse.
out=$(run misaligned-lagging)
check "lagging replica blocks switchover" "REFUSING switchover: replication lag" "$out"

# 4. A member is not streaming: refuse for the same reason.
out=$(run misaligned-unhealthy)
check "unhealthy member blocks switchover" "REFUSING switchover:" "$out"

# 5. No leader at all — Patroni is mid-election. Interfering makes it worse.
out=$(run no-leader)
check "election in progress is left alone" "Patroni is mid-election" "$out"

# 6. Anchor pod missing: nothing to compare against, exit quietly rather than
#    guessing a zone.
out=$(run no-anchor)
check "missing anchor exits cleanly" "anchor pod not found" "$out"

# 7. Pods of a pinned deployment are in the wrong zone: restart them.
out=$(run misaligned-healthy)
check "drifted deployment is restarted" "restarting prod/api" "$out"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
