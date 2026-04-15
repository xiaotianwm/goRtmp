#!/usr/bin/env bash
set -u

INSTALL_DIR="${INSTALL_DIR:-/opt/goRtmp}"
SERVICE_NAME="${SERVICE_NAME:-goRtmp}"
SERVER_DIR="${INSTALL_DIR}/server"
WEB_DIR="${INSTALL_DIR}/web"
TIMESTAMP="$(date +%F_%H%M%S)"
OUT_FILE="${OUT_FILE:-/tmp/goRtmp_diag_${TIMESTAMP}.log}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
AUTH_COOKIE="${AUTH_COOKIE:-}"

mkdir -p "$(dirname "$OUT_FILE")"
exec > >(tee "$OUT_FILE") 2>&1

read_env_value() {
  local env_file="$1"
  local key="$2"
  local fallback="$3"

  if [[ ! -f "$env_file" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$env_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  local value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s\n' "$value"
}

resolve_path() {
  local value="$1"
  local base_dir="$2"

  if [[ -z "$value" ]]; then
    return 1
  fi
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' "${base_dir}/${value}"
}

section() {
  printf '\n=== %s ===\n' "$1"
}

run_cmd() {
  local title="$1"
  shift
  section "$title"
  "$@" || true
}

curl_timed() {
  local label="$1"
  local url="$2"
  shift 2
  local extra_args=("$@")
  printf '%s ' "$label"
  curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' "${extra_args[@]}" "$url" || true
}

auth_args=()
if [[ -n "$AUTH_TOKEN" ]]; then
  auth_args=(-H "Authorization: Bearer ${AUTH_TOKEN}")
elif [[ -n "$AUTH_COOKIE" ]]; then
  auth_args=(-H "Cookie: go_rtmp_auth=${AUTH_COOKIE}")
fi

HTTP_ADDR="$(read_env_value "${SERVER_DIR}/app.env" "HTTP_ADDR" "127.0.0.1:8080")"
WEB_ADDR="$(read_env_value "${WEB_DIR}/app.env" "WEB_ADDR" "0.0.0.0:8081")"
SQLITE_VALUE="$(read_env_value "${SERVER_DIR}/app.env" "SQLITE_PATH" "data/app.db")"
SQLITE_PATH="$(resolve_path "$SQLITE_VALUE" "$SERVER_DIR")"
SERVER_LOG="${SERVER_DIR}/server.log"
WEB_LOG="${WEB_DIR}/web.log"

section "SUMMARY"
printf 'time: %s\n' "$(date -Is)"
printf 'install_dir: %s\n' "$INSTALL_DIR"
printf 'service_name: %s\n' "$SERVICE_NAME"
printf 'server_dir: %s\n' "$SERVER_DIR"
printf 'web_dir: %s\n' "$WEB_DIR"
printf 'http_addr: %s\n' "$HTTP_ADDR"
printf 'web_addr: %s\n' "$WEB_ADDR"
printf 'sqlite_path: %s\n' "$SQLITE_PATH"
printf 'output_file: %s\n' "$OUT_FILE"
if [[ "${EUID}" -ne 0 ]]; then
  printf 'warning: not running as root; journal/systemd output may be incomplete\n'
fi
if [[ ${#auth_args[@]} -eq 0 ]]; then
  printf 'protected endpoint test: skipped, set AUTH_TOKEN or AUTH_COOKIE if needed\n'
else
  printf 'protected endpoint test: enabled\n'
fi

run_cmd "SERVICE STATUS" systemctl status "${SERVICE_NAME}" --no-pager
run_cmd "JOURNAL LAST 200" journalctl -u "${SERVICE_NAME}" -n 200 --no-pager
run_cmd "PORTS" sh -c "ss -ltnp | egrep '1935|8080|8081' || true"
run_cmd "PROCESS" sh -c "ps -ef | egrep 'go-rtmp-server|server|web|ffmpeg' | grep -v grep || true"

section "LOCAL CURL"
curl_timed "ping" "http://127.0.0.1:8080/ping"
curl_timed "auth" "http://127.0.0.1:8080/api/auth/status"
curl_timed "web" "http://127.0.0.1:8081/"
if [[ ${#auth_args[@]} -gt 0 ]]; then
  curl_timed "rooms" "http://127.0.0.1:8080/api/rooms?limit=1&offset=0" "${auth_args[@]}"
  curl_timed "rtmp" "http://127.0.0.1:8080/api/rtmp/channels?limit=1&offset=0" "${auth_args[@]}"
fi

run_cmd "SERVER LOG LAST 120" tail -n 120 "$SERVER_LOG"
run_cmd "WEB LOG LAST 120" tail -n 120 "$WEB_LOG"
run_cmd "DB FILES" sh -c "ls -lh \"${SQLITE_PATH}\"* 2>/dev/null || true"

if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$SQLITE_PATH" ]]; then
  run_cmd "DB COUNTS" sqlite3 "$SQLITE_PATH" "
    select 'rooms', count(*) from rooms;
    select 'room_logs', count(*) from room_logs;
    select 'rtmp_channels', count(*) from rtmp_channels;
    select 'rtmp_channel_logs', count(*) from rtmp_channel_logs;
    select 'audit_logs', count(*) from audit_logs;
    select 'auth_sessions', count(*) from auth_sessions;
  "
  run_cmd "TOP ROOM LOG WRITERS" sqlite3 "$SQLITE_PATH" "
    select room_id, count(*) as c
    from room_logs
    group by room_id
    order by c desc
    limit 20;
  "
  run_cmd "TOP RTMP LOG WRITERS" sqlite3 "$SQLITE_PATH" "
    select channel_id, count(*) as c
    from rtmp_channel_logs
    group by channel_id
    order by c desc
    limit 20;
  "
  run_cmd "RECENT ROOM LOGS" sqlite3 "$SQLITE_PATH" "
    select created_at, room_id, substr(line, 1, 180)
    from room_logs
    order by id desc
    limit 50;
  "
  run_cmd "RECENT RTMP LOGS" sqlite3 "$SQLITE_PATH" "
    select created_at, channel_id, substr(line, 1, 180)
    from rtmp_channel_logs
    order by id desc
    limit 50;
  "
  run_cmd "RECENT AUDIT LOGS" sqlite3 "$SQLITE_PATH" "
    select created_at, actor_username, action, resource_type, resource_id, status
    from audit_logs
    order by id desc
    limit 50;
  "
else
  section "SQLITE"
  echo "sqlite3 not found or db missing; skip sqlite inspection"
fi

run_cmd "LOCK KEYWORDS" sh -c "journalctl -u \"${SERVICE_NAME}\" --no-pager | egrep -i 'database is locked|sqlite|busy_timeout|timeout|deadline exceeded|broken pipe|connection reset|panic|fatal' | tail -n 200 || true"
run_cmd "NGINX ERROR LAST 100" sh -c "tail -n 100 /var/log/nginx/error.log 2>/dev/null || true"
run_cmd "NGINX ACCESS LAST 100" sh -c "tail -n 100 /var/log/nginx/access.log 2>/dev/null || true"
run_cmd "SYSTEM LOAD" sh -c "uptime; echo; free -h; echo; df -h"

section "DONE"
printf 'saved to %s\n' "$OUT_FILE"
