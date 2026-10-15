#!/usr/bin/env bash
# End-to-end test of the blue-green flow. Runs in an isolated compose project,
# on its own port and upstream dir, so it never touches a real deployment.
#
# Verifies: first deploy -> blue; second deploy -> green with ZERO failed requests
# during the switch; data (hit counter) survives; rollback works; a broken release
# is rejected without affecting live traffic.

set -euo pipefail
cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME=bgd-e2e
export HTTP_PORT=18080
export UPSTREAM_DIR
UPSTREAM_DIR="$PWD/.e2e-upstream"; rm -rf "$UPSTREAM_DIR"; mkdir -p "$UPSTREAM_DIR"
chmod 755 "$UPSTREAM_DIR"
URL="http://localhost:${HTTP_PORT}"
LOG="$(mktemp)"
LOOP_PID=""

fail() { echo "E2E FAIL: $*" >&2; exit 1; }
pass() { echo "E2E ok: $*"; }

cleanup() {
  [[ -n "$LOOP_PID" ]] && kill "$LOOP_PID" 2>/dev/null || true
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$UPSTREAM_DIR" "$LOG"
}
trap cleanup EXIT

json_field() { python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
live_color()   { curl -fsS "$URL/health" | json_field color; }
live_version() { curl -fsS "$URL/health" | json_field version; }
hits()         { curl -fsS "$URL/" | json_field hits; }

# 1. First deploy goes to blue
./deploy.sh deploy v1
[[ "$(live_color)" == "blue" ]] || fail "expected blue after first deploy"
[[ "$(live_version)" == "v1" ]] || fail "expected version v1"
H1="$(hits)"
pass "v1 live on blue (hits=$H1)"

# 2. Second deploy under continuous traffic: must switch to green with no failed requests
(
  while true; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "$URL/" >> "$LOG" || echo 000 >> "$LOG"
    sleep 0.05
  done
) &
LOOP_PID=$!

./deploy.sh deploy v2

kill "$LOOP_PID" 2>/dev/null || true
wait "$LOOP_PID" 2>/dev/null || true
LOOP_PID=""

TOTAL="$(wc -l < "$LOG")"
BAD="$(grep -vc '^200$' "$LOG" || true)"
(( TOTAL > 20 )) || fail "traffic loop sent too few requests ($TOTAL)"
[[ "$BAD" == "0" ]] || fail "$BAD of $TOTAL requests failed during the switch"
[[ "$(live_color)" == "green" ]] || fail "expected green after second deploy"
[[ "$(live_version)" == "v2" ]] || fail "expected version v2"
pass "v2 live on green, $TOTAL requests during switch, 0 failed"

# 3. Data survived the switch
H2="$(hits)"
(( H2 > H1 )) || fail "hit counter did not persist across colors ($H1 -> $H2)"
pass "data persisted (hits $H1 -> $H2)"

# 4. Rollback
./deploy.sh rollback
[[ "$(live_color)" == "blue" ]] || fail "expected blue after rollback"
[[ "$(live_version)" == "v1" ]] || fail "rollback should serve v1"
pass "rollback to blue/v1 works"

# 5. A broken release must be rejected and leave live traffic alone
if REDIS_HOST=does-not-exist HEALTH_TIMEOUT=60 ./deploy.sh deploy v3-broken; then
  fail "broken release was accepted"
fi
[[ "$(live_color)" == "blue" ]] || fail "live color changed after a failed deploy"
curl -fsS "$URL/" >/dev/null || fail "live traffic broken after a failed deploy"
pass "broken release rejected, blue still serving"

echo "E2E PASSED"
