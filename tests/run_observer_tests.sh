#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXY_SCRIPT="${ADAPTER_DIR}/observer/proxy.js"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/volcano-observer-tests.XXXXXX")"
trap 'cleanup' EXIT

MOCK_PID=""
PROXY_PID=""

cleanup() {
  if [[ -n "$PROXY_PID" ]]; then kill "$PROXY_PID" 2>/dev/null || true; fi
  if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  rm -rf "$TEST_ROOT"
}

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

wait_for_url() {
  local url="$1"
  local attempts=50
  while [[ "$attempts" -gt 0 ]]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

if ! command -v node >/dev/null 2>&1; then
  printf 'skip - node is required for observer proxy runtime tests\n'
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required for observer tests"
fi

bash -n "$PROXY_SCRIPT"
node --check "$PROXY_SCRIPT"
pass "observer proxy passes syntax checks"

cat > "$TEST_ROOT/mock_upstream.js" <<'EOF'
const http = require('http');

const port = Number(process.env.MOCK_PORT);

function send(res, event, data) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  if (req.method !== 'POST' || req.url !== '/api/v3/responses') {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  req.resume();
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
  });
  send(res, 'response.created', {
    type: 'response.created',
    response: { id: 'resp_mock', model: 'ep-test' },
  });
  send(res, 'response.output_text.delta', {
    type: 'response.output_text.delta',
    delta: 'OK',
  });
  send(res, 'response.output_item.added', {
    type: 'response.output_item.added',
    item: {
      type: 'function_call',
      call_id: 'call_mock',
      name: 'get_time',
      status: 'in_progress',
    },
  });
  send(res, 'response.output_item.done', {
    type: 'response.output_item.done',
    item: {
      type: 'function_call',
      call_id: 'call_mock',
      name: 'get_time',
      arguments: '{}',
      status: 'completed',
    },
  });
  send(res, 'response.completed', {
    type: 'response.completed',
    response: {
      id: 'resp_mock',
      model: 'ep-test',
      usage: {
        input_tokens: 20,
        output_tokens: 10,
        total_tokens: 30,
        input_tokens_details: {
          cached_tokens: 8,
          cache_write_tokens: 4,
        },
      },
    },
  });
  res.end();
}).listen(port, '127.0.0.1', () => {
  console.log(`mock upstream listening on ${port}`);
});
EOF

MOCK_PORT=18081 node "$TEST_ROOT/mock_upstream.js" > "$TEST_ROOT/mock.log" 2>&1 &
MOCK_PID="$!"
wait_for_url "http://127.0.0.1:18081/health" || {
  cat "$TEST_ROOT/mock.log" >&2
  fail "mock upstream did not start"
}

OBSERVER_PORT=18082 \
OBSERVER_HOST=127.0.0.1 \
ARK_UPSTREAM_BASE=http://127.0.0.1:18081/api/v3 \
OBSERVER_LOG_DIR="$TEST_ROOT/logs" \
ARK_API_KEY=test-key \
node "$PROXY_SCRIPT" > "$TEST_ROOT/proxy.log" 2>&1 &
PROXY_PID="$!"

wait_for_url "http://127.0.0.1:18082/health" || {
  cat "$TEST_ROOT/proxy.log" >&2
  fail "observer proxy did not start"
}
pass "observer proxy starts and exposes health"

body='{"model":"ep-test","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":true}'
output="$TEST_ROOT/response.sse"
status="$(
  curl -sS -N \
    -o "$output" \
    -w '%{http_code}' \
    -H 'Authorization: Bearer test-key' \
    -H 'Content-Type: application/json' \
    --data-binary "$body" \
    http://127.0.0.1:18082/api/v3/responses
)"

[[ "$status" == "200" ]] || fail "observer proxy returned HTTP $status"
grep -q 'response.completed' "$output" || fail "proxied SSE did not contain completion"
pass "observer proxies streaming Responses traffic"

requests_json="$TEST_ROOT/requests.json"
curl -fsS http://127.0.0.1:18082/api/requests > "$requests_json"

grep -q '"total_tokens": 30' "$requests_json" || fail "summary did not record total tokens"
grep -q '"cached_tokens": 8' "$requests_json" || fail "summary did not record cached tokens"
grep -q '"cache_write_tokens": 4' "$requests_json" || fail "summary did not record cache write tokens"
grep -q '"cache_hit_ratio": 0.4' "$requests_json" || fail "summary did not record cache hit ratio"
grep -q '"name": "get_time"' "$requests_json" || fail "summary did not record tool call"
pass "observer records usage, cache, and tool-call summary"

request_id="$(sed -n 's/.*"request_id": "\([^"]*\)".*/\1/p' "$requests_json" | head -n 1)"
[[ -n "$request_id" ]] || fail "request id not found"
detail_json="$TEST_ROOT/detail.json"
curl -fsS "http://127.0.0.1:18082/api/requests/${request_id}" > "$detail_json"
grep -q '"events"' "$detail_json" || fail "detail endpoint did not return events"
grep -q '"response.output_text.delta"' "$detail_json" || fail "detail endpoint missing text delta event"
pass "observer detail endpoint returns raw events"

curl -fsS http://127.0.0.1:18082/ > "$TEST_ROOT/index.html"
grep -q 'Volcano Codex Observer' "$TEST_ROOT/index.html" || fail "dashboard HTML not served"
pass "observer serves dashboard frontend"

printf '\nAll Volcano Codex Observer tests passed.\n'
