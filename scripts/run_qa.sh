#!/bin/bash
# Run the QA test pass for the checked-out PR and save logs for the PR comment.
# Exit 0 = all green, 1 = failures (see the log paths printed at the end).
#
# Usage: run_qa.sh [--quick] [test files ...]   (run from the PR worktree)
#   --quick   targeted files + system tests only, skipping full bin/ci
source "$(dirname "$0")/lib/common.sh"

quick=0
[[ ${1:-} == --quick ]] && { quick=1; shift; }
out="tmp/qa"
mkdir -p "$out"
status=0

step() {
  local name=$1; shift
  log "▶ $name"
  if "$@" >"$out/$name.log" 2>&1; then
    log "✔ $name"
  else
    log "✘ $name (see $out/$name.log)"
    status=1
  fi
}

[[ $# -gt 0 ]] && step targeted bin/rails test "$@"

if [[ $quick -eq 1 ]]; then
  step system bin/rails test:system
else
  step ci bin/ci
fi

# Re-run failures once to separate flakes from real failures (per qa-tester rules).
if [[ $status -ne 0 ]]; then
  failed=$(grep -hoE 'bin/rails test [^ ]+:[0-9]+' "$out"/*.log | sort -u | cut -d' ' -f3 || true)
  if [[ -n $failed ]]; then
    log "re-running failed tests once to check for flakiness"
    # shellcheck disable=SC2086
    if bin/rails test $failed >"$out/rerun.log" 2>&1; then
      log "failures passed on re-run: likely flaky, see $out/rerun.log"
      status=2
    fi
  fi
fi

ls tmp/screenshots/*.png >/dev/null 2>&1 && log "screenshots: tmp/screenshots/"
log "logs: $out/"
exit $status
