#!/usr/bin/env bash
# Proves the checks actually fail on bad input. Run it in CI next to the real
# validation — a validator nobody tests is a validator that silently stops
# working.
set -uo pipefail
cd "$(dirname "$0")/.."

# Always clean up the injected template, even if validate.sh dies mid-run.
trap 'rm -f templates/haproxy/__selftest.cfg.template' EXIT

fail=0
for case_file in examples/broken/*.cfg.template; do
  name=$(basename "$case_file")
  cp "$case_file" "templates/haproxy/__selftest.cfg.template"
  if ./scripts/validate.sh haproxy >/dev/null 2>&1; then
    echo "SELFTEST FAIL: ${name} was accepted but should have been rejected" >&2
    fail=1
  else
    echo "  ok   ${name} correctly rejected"
  fi
  rm -f "templates/haproxy/__selftest.cfg.template"
done

[ "$fail" = 0 ] && echo && echo "Self-test passed: every broken template was rejected."
exit "$fail"
