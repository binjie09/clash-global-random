#!/bin/sh
set -eu

CONFIG_PATH="${CONFIG_PATH:-/root/.config/clash/config.yaml}"
CONFIG_DIR="${CONFIG_DIR:-}"
API_SECRET="${API_SECRET:-}"
TARGET_GROUP="${TARGET_GROUP:-GLOBAL}"
CORE_BIN="${CORE_BIN:-}"
N_PROXIES="${N_PROXIES:-1}"
BASE_PORT="${BASE_PORT:-7890}"
API_BASE_PORT="${API_BASE_PORT:-19090}"

PIDS_FILE="/tmp/clash-instance-pids"
PROXY_LIST_FILE="/tmp/clash-proxy-list"
: > "$PIDS_FILE"

cleanup() {
  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r _pid; do
      [ -n "$_pid" ] || continue
      kill "$_pid" 2>/dev/null || true
    done < "$PIDS_FILE"
    while IFS= read -r _pid; do
      [ -n "$_pid" ] || continue
      wait "$_pid" 2>/dev/null || true
    done < "$PIDS_FILE"
  fi
}

trap cleanup INT TERM

detect_core_bin() {
  if [ -n "$CORE_BIN" ]; then return 0; fi
  if command -v mihomo >/dev/null 2>&1; then CORE_BIN="$(command -v mihomo)"; return 0; fi
  if [ -x /mihomo ]; then CORE_BIN="/mihomo"; return 0; fi
  if command -v clash >/dev/null 2>&1; then CORE_BIN="$(command -v clash)"; return 0; fi
  if [ -x /clash ]; then CORE_BIN="/clash"; return 0; fi
  echo "No supported Clash-compatible core binary found" >&2
  exit 1
}

init_config_dir() {
  if [ -n "$CONFIG_DIR" ]; then return 0; fi
  CONFIG_DIR="$(dirname "$CONFIG_PATH")"
}

extract_proxy_names() {
  awk '
    function trim(line) {
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    function unquote(line) {
      if (substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") {
        line = substr(line, 2, length(line) - 2)
      }
      if (substr(line, 1, 1) == "'"'"'" && substr(line, length(line), 1) == "'"'"'") {
        line = substr(line, 2, length(line) - 2)
      }
      return line
    }
    /^[^[:space:]][^:]*:/ {
      if ($1 == "proxies:") {
        in_proxies = 1
        next
      }
      if (in_proxies) {
        exit
      }
    }
    in_proxies && /^  - \{name: / {
      line = $0
      sub(/^  - \{name: /, "", line)
      if (substr(line, 1, 1) == "\"") {
        sub(/^"/, "", line)
        sub(/".*$/, "", line)
      } else {
        sub(/,.*/, "", line)
      }
      print line
      next
    }
    in_proxies && /^  - name:[[:space:]]*/ {
      line = $0
      sub(/^  - name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      print unquote(trim(line))
      next
    }
    in_proxies && /^  -[[:space:]]+name:[[:space:]]*/ {
      line = $0
      sub(/^  -[[:space:]]+name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      print unquote(trim(line))
      next
    }
  ' "$CONFIG_PATH"
}

shuffle_proxy_names() {
  extract_proxy_names | awk '
    BEGIN {
      srand()
    }
    {
      proxies[++count] = $0
    }
    END {
      while (count > 0) {
        pick = int(rand() * count) + 1
        print proxies[pick]
        proxies[pick] = proxies[count]
        count--
      }
    }
  '
}

wait_for_api_port() {
  _port="$1"
  _tries=0
  while [ "$_tries" -lt 30 ]; do
    if wget -qO- "http://127.0.0.1:${_port}/version" >/dev/null 2>&1; then
      return 0
    fi
    _tries=$((_tries + 1))
    sleep 1
  done
  return 1
}

select_proxy_on_port() {
  _api_port="$1"
  _proxy_name="$2"
  _escaped=$(printf '%s' "$_proxy_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  _payload=$(printf '{"name":"%s"}' "$_escaped")
  _len=$(printf '%s' "$_payload" | wc -c | tr -d ' ')

  _response=$(
    {
      printf 'PUT /proxies/%s HTTP/1.1\r\n' "$TARGET_GROUP"
      printf 'Host: 127.0.0.1:%s\r\n' "$_api_port"
      if [ -n "$API_SECRET" ]; then
        printf 'Authorization: Bearer %s\r\n' "$API_SECRET"
      fi
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "$_len"
      printf 'Connection: close\r\n'
      printf '\r\n'
      printf '%s' "$_payload"
    } | nc -w 3 127.0.0.1 "$_api_port" 2>/dev/null || true
  )

  printf '%s' "$_response" | grep -Eq '^HTTP/1\.[01] 204|^HTTP/1\.[01] 200'
}

create_instance_config() {
  _idx="$1"
  _http_port="$2"
  _api_port="$3"
  _dir="/tmp/clash-instance-${_idx}"
  mkdir -p "$_dir"

  awk -v http_port="$_http_port" -v api_port="$_api_port" '
    /^port:[[:space:]]/ {
      print "port: " http_port
      has_port = 1
      next
    }
    /^socks-port:[[:space:]]/ {
      print "socks-port: 0"
      next
    }
    /^mixed-port:[[:space:]]/ {
      print "mixed-port: 0"
      next
    }
    /^external-controller:[[:space:]]/ {
      print "external-controller: \"127.0.0.1:" api_port "\""
      has_controller = 1
      next
    }
    { print }
    END {
      if (!has_port) print "port: " http_port
      if (!has_controller) print "external-controller: \"127.0.0.1:" api_port "\""
    }
  ' "$CONFIG_PATH" > "${_dir}/config.yaml"

  # Symlink GeoIP/GeoSite databases so each instance can find them
  for _f in \
    "$CONFIG_DIR/Country.mmdb" \
    "$CONFIG_DIR/GeoIP.dat" \
    "$CONFIG_DIR/GeoSite.dat" \
    "$CONFIG_DIR/geoip.db" \
    "$CONFIG_DIR/geosite.db" \
    "$CONFIG_DIR/ASN.mmdb"
  do
    [ -f "$_f" ] && ln -sf "$_f" "${_dir}/$(basename "$_f")" 2>/dev/null || true
  done

  printf '%s' "$_dir"
}

# ── Main ──────────────────────────────────────────────────────────────────────

detect_core_bin
init_config_dir

shuffle_proxy_names > "$PROXY_LIST_FILE"
total_proxies=$(wc -l < "$PROXY_LIST_FILE" | tr -d ' ')

if [ "$total_proxies" -eq 0 ]; then
  echo "No proxies found in $CONFIG_PATH" >&2
  exit 1
fi

actual_n="$N_PROXIES"
if [ "$actual_n" -gt "$total_proxies" ]; then
  echo "Warning: requested $N_PROXIES proxies but only $total_proxies available. Starting $total_proxies instance(s)." >&2
  actual_n="$total_proxies"
fi

echo "Starting $actual_n clash instance(s) on ports ${BASE_PORT}–$((BASE_PORT + actual_n - 1))..."

i=0
while IFS= read -r proxy_name; do
  [ "$i" -lt "$actual_n" ] || break
  [ -n "$proxy_name" ] || continue

  http_port=$((BASE_PORT + i))
  api_port=$((API_BASE_PORT + i))

  instance_dir="$(create_instance_config "$i" "$http_port" "$api_port")"

  "$CORE_BIN" -d "$instance_dir" -f "${instance_dir}/config.yaml" &
  pid=$!
  printf '%s\n' "$pid" >> "$PIDS_FILE"

  echo "Instance $((i + 1))/$actual_n: HTTP port=$http_port  proxy=$proxy_name  pid=$pid"

  if wait_for_api_port "$api_port"; then
    if select_proxy_on_port "$api_port" "$proxy_name"; then
      echo "Instance $((i + 1)): proxy selected: $proxy_name"
    else
      echo "Instance $((i + 1)): failed to select proxy: $proxy_name" >&2
    fi
  else
    echo "Instance $((i + 1)): API did not become ready on port $api_port" >&2
  fi

  i=$((i + 1))
done < "$PROXY_LIST_FILE"

echo "All $actual_n instance(s) running."

# Wait for all instances to exit
while IFS= read -r _pid; do
  [ -n "$_pid" ] || continue
  wait "$_pid" 2>/dev/null || true
done < "$PIDS_FILE"
