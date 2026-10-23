#!/bin/bash
# Post-deploy smoke checks: health endpoint, key pages, and (optionally) that
# Solid Queue workers are heartbeating. Exit 0 = healthy, 1 = something failed.
#
# Usage: smoke_check.sh <base-url> [--jobs] [-d <kamal-destination>]
# Env:   SMOKE_PATHS  space-separated paths to GET (default: "/up /")
source "$(dirname "$0")/lib/common.sh"
require curl

[[ $# -ge 1 ]] || die "usage: $(basename "$0") <base-url> [--jobs] [-d <destination>]"
base=${1%/}; shift
check_jobs=0 dest_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --jobs) check_jobs=1; shift ;;
    -d) dest_args=(-d "$2"); shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

failures=0

# /up can take a moment after a container swap; retry before failing.
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/up" || true)
  [[ $code == 200 ]] && break
  sleep 3
done
if [[ $code == 200 ]]; then log "✔ /up"; else log "✘ /up returned $code"; failures=1; fi

for path in ${SMOKE_PATHS:-/}; do
  [[ $path == /up ]] && continue
  code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 15 "$base$path" || true)
  if [[ $code =~ ^(200|204)$ ]]; then log "✔ $path ($code)"; else log "✘ $path returned $code"; failures=1; fi
done

if [[ $check_jobs -eq 1 ]]; then
  alive=$(bin/kamal app exec ${dest_args[@]+"${dest_args[@]}"} --reuse --quiet \
    'bin/rails runner "puts SolidQueue::Process.where(%(last_heartbeat_at > ?), 2.minutes.ago).count"' 2>/dev/null \
    | tail -n 1 | tr -dc '0-9')
  if [[ ${alive:-0} -gt 0 ]]; then log "✔ Solid Queue: $alive live process(es)"; else log "✘ no Solid Queue heartbeats"; failures=1; fi
fi

exit $failures
