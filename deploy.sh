#!/usr/bin/env bash
# Blue-green deployment driver.
#
#   ./deploy.sh deploy [version]   build + start the idle color, switch traffic once it is healthy
#   ./deploy.sh rollback           switch traffic back to the previous color
#   ./deploy.sh status             show the active color and container states
#   ./deploy.sh stop-idle          stop the color that is not receiving traffic
#
# The live color is recorded in nginx's upstream.conf (single source of truth).

set -euo pipefail
cd "$(dirname "$0")"

UPSTREAM_DIR="${UPSTREAM_DIR:-$PWD/nginx/upstream}"
export UPSTREAM_DIR
UPSTREAM_FILE="$UPSTREAM_DIR/upstream.conf"
HTTP_PORT="${HTTP_PORT:-8080}"
export HTTP_PORT
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
COMPOSE="docker compose"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

current_color() {
  [[ -f "$UPSTREAM_FILE" ]] || return 0
  grep -oE 'server app-(blue|green):' "$UPSTREAM_FILE" | head -n1 | sed -E 's/server app-(blue|green):/\1/' || true
}

other_color() {
  case "$1" in
    blue) echo green ;;
    green) echo blue ;;
    *) echo blue ;;
  esac
}

write_upstream() {
  local color=$1 tmp
  mkdir -p "$UPSTREAM_DIR"
  tmp="$(mktemp "$UPSTREAM_FILE.XXXXXX")"
  cat > "$tmp" <<EOF
upstream app {
    server app-${color}:5000;
}

map "" \$active_color {
    default ${color};
}
EOF
  chmod 644 "$tmp"
  mv "$tmp" "$UPSTREAM_FILE"   # atomic rename inside the mounted directory
}

nginx_running() {
  $COMPOSE ps --status running --services 2>/dev/null | grep -qx nginx
}

reload_nginx() {
  if nginx_running; then
    $COMPOSE exec -T nginx nginx -t >/dev/null 2>&1 || return 1
    $COMPOSE exec -T nginx nginx -s reload
  else
    $COMPOSE up -d --no-deps nginx
  fi
}

wait_healthy() {
  local color=$1 cid status running elapsed=0
  cid="$($COMPOSE ps -aq "app-$color")"
  [[ -n "$cid" ]] || return 1
  while (( elapsed < HEALTH_TIMEOUT )); do
    running="$(docker inspect --format '{{.State.Running}}' "$cid")"
    [[ "$running" == "true" ]] || return 1
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# Confirms a request through nginx is really answered by the given color.
verify_traffic() {
  local color=$1 i body
  for i in $(seq 1 10); do
    body="$(curl -fsS --max-time 3 "http://localhost:${HTTP_PORT}/health" 2>/dev/null || true)"
    if grep -Eq "\"color\": ?\"${color}\"" <<<"$body"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

switch_traffic() {
  local target=$1 previous
  previous="$(current_color)"
  write_upstream "$target"
  if ! reload_nginx; then
    if [[ -n "$previous" ]]; then write_upstream "$previous"; fi
    die "nginx rejected the new config; kept ${previous:-no color}"
  fi
  if ! verify_traffic "$target"; then
    if [[ -n "$previous" ]]; then
      log "verification failed, reverting to $previous"
      write_upstream "$previous"
      reload_nginx || true
    fi
    die "traffic check for $target failed"
  fi
}

cmd_deploy() {
  local version="${1:-${APP_VERSION:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}}"
  export APP_VERSION="$version"

  local active target
  active="$(current_color)"
  target="$(other_color "$active")"
  log "active=${active:-none} target=$target version=$version"

  $COMPOSE up -d --no-deps redis
  $COMPOSE up -d --build --no-deps --force-recreate "app-$target"

  log "waiting for app-$target to become healthy (timeout ${HEALTH_TIMEOUT}s)"
  if ! wait_healthy "$target"; then
    $COMPOSE logs --tail=40 "app-$target" || true
    $COMPOSE stop "app-$target" || true
    die "app-$target failed its healthcheck; traffic was not touched (still on ${active:-nothing})"
  fi

  log "switching traffic to $target"
  switch_traffic "$target"
  log "done: $target is live (version $version); ${active:-no previous color} kept running for rollback"
}

cmd_rollback() {
  local active target
  active="$(current_color)"
  [[ -n "$active" ]] || die "nothing is deployed yet"
  target="$(other_color "$active")"
  wait_healthy "$target" || die "$target is not running/healthy (was it stopped?); deploy instead"
  log "rolling back $active -> $target"
  switch_traffic "$target"
  log "done: $target is live"
}

cmd_status() {
  local active
  active="$(current_color)"
  echo "active color: ${active:-none}"
  $COMPOSE ps
  if curl -fsS --max-time 3 "http://localhost:${HTTP_PORT}/health" 2>/dev/null; then echo; fi
}

cmd_stop_idle() {
  local active idle
  active="$(current_color)"
  [[ -n "$active" ]] || die "nothing is deployed yet"
  idle="$(other_color "$active")"
  $COMPOSE stop "app-$idle"
  log "stopped app-$idle (rollback needs a new deploy now)"
}

case "${1:-}" in
  deploy)    shift; cmd_deploy "${1:-}" ;;
  rollback)  cmd_rollback ;;
  status)    cmd_status ;;
  stop-idle) cmd_stop_idle ;;
  *) echo "usage: $0 {deploy [version]|rollback|status|stop-idle}" >&2; exit 2 ;;
esac
