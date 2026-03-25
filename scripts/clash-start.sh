#!/bin/sh
set -eu

CONFIG_PATH="${CONFIG_PATH:-/root/.config/clash/config.yaml}"
API_HOST="${API_HOST:-}"
API_PORT="${API_PORT:-}"
API_SECRET="${API_SECRET:-}"
TARGET_GROUP="${TARGET_GROUP:-GLOBAL}"
TEST_URL_ENCODED="${TEST_URL_ENCODED:-https:%2F%2Fwww.gstatic.com%2Fgenerate_204}"
TEST_TIMEOUT_MS="${TEST_TIMEOUT_MS:-5000}"
MAX_DELAY_MS="${MAX_DELAY_MS:-0}"

cleanup() {
  if [ "${clash_pid:-}" != "" ]; then
    kill "$clash_pid" 2>/dev/null || true
    wait "$clash_pid" 2>/dev/null || true
  fi
}

trap cleanup INT TERM

trim_quotes() {
  value="$1"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

read_top_level_value() {
  key="$1"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      line = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH"
}

init_api_settings() {
  controller_value="$(trim_quotes "$(read_top_level_value external-controller || true)")"
  secret_value="$(trim_quotes "$(read_top_level_value secret || true)")"

  if [ -z "$API_PORT" ] && [ -n "$controller_value" ]; then
    API_PORT="${controller_value##*:}"
  fi

  if [ -z "$API_PORT" ]; then
    API_PORT="9090"
  fi

  if [ -z "$API_HOST" ]; then
    API_HOST="127.0.0.1"
  fi

  if [ -z "$API_SECRET" ] && [ -n "$secret_value" ]; then
    API_SECRET="$secret_value"
  fi
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

wait_for_api() {
  tries=0
  while [ "$tries" -lt 30 ]; do
    if wget -qO- "http://${API_HOST}:${API_PORT}/version" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

request_headers() {
  printf 'Host: %s:%s\r\n' "$API_HOST" "$API_PORT"
  if [ -n "$API_SECRET" ]; then
    printf 'Authorization: Bearer %s\r\n' "$API_SECRET"
  fi
}

select_proxy() {
  proxy_name="$1"
  escaped_name=$(printf '%s' "$proxy_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  payload=$(printf '{"name":"%s"}' "$escaped_name")
  payload_length=$(printf '%s' "$payload" | wc -c | tr -d ' ')

  response=$(
    {
      printf 'PUT /proxies/%s HTTP/1.1\r\n' "$TARGET_GROUP"
      request_headers
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "$payload_length"
      printf 'Connection: close\r\n'
      printf '\r\n'
      printf '%s' "$payload"
    } | nc -w 3 "$API_HOST" "$API_PORT" 2>/dev/null || true
  )

  printf '%s' "$response" | grep -Eq '^HTTP/1\.[01] 204|^HTTP/1\.[01] 200'
}

test_current_proxy() {
  if [ -n "$API_SECRET" ]; then
    response=$(
      wget --header="Authorization: Bearer ${API_SECRET}" -qO- "http://${API_HOST}:${API_PORT}/proxies/${TARGET_GROUP}/delay?url=${TEST_URL_ENCODED}&timeout=${TEST_TIMEOUT_MS}" 2>/dev/null || true
    )
  else
    response=$(
      wget -qO- "http://${API_HOST}:${API_PORT}/proxies/${TARGET_GROUP}/delay?url=${TEST_URL_ENCODED}&timeout=${TEST_TIMEOUT_MS}" 2>/dev/null || true
    )
  fi

  delay_value=$(printf '%s' "$response" | sed -n 's/.*"delay":\([0-9][0-9]*\).*/\1/p')
  if [ -z "$delay_value" ]; then
    return 1
  fi

  if [ "$MAX_DELAY_MS" -gt 0 ] && [ "$delay_value" -gt "$MAX_DELAY_MS" ]; then
    return 1
  fi

  echo "$delay_value"
}

init_api_settings

/clash &
clash_pid=$!

if wait_for_api; then
  proxy_candidates="$(shuffle_proxy_names || true)"
  if [ -z "$proxy_candidates" ]; then
    echo "No proxies found in $CONFIG_PATH" >&2
  else
    selected_proxy=""
    selected_delay=""
    while IFS= read -r proxy_name; do
      [ -n "$proxy_name" ] || continue

      if ! select_proxy "$proxy_name"; then
        echo "Failed to switch ${TARGET_GROUP} to proxy: $proxy_name" >&2
        continue
      fi

      delay_value="$(test_current_proxy || true)"
      if [ -n "$delay_value" ]; then
        selected_proxy="$proxy_name"
        selected_delay="$delay_value"
        break
      fi

      echo "Proxy check failed for ${proxy_name}, trying another proxy" >&2
    done <<EOF
$proxy_candidates
EOF

    if [ -n "$selected_proxy" ]; then
      echo "Healthy proxy selected for ${TARGET_GROUP}: ${selected_proxy} (${selected_delay} ms)"
    else
      echo "No healthy proxy found for ${TARGET_GROUP}" >&2
    fi
  fi
else
  echo "Clash management API did not become ready in time" >&2
fi

wait "$clash_pid"
