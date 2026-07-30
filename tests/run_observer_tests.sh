#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXY_SCRIPT="${ADAPTER_DIR}/observer/proxy.py"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/volcano-observer-tests.XXXXXX")"
trap 'cleanup' EXIT

MOCK_PID=""
PROXY_PID=""

cleanup() {
  if [[ -n "$PROXY_PID" ]]; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
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

if ! command -v python3 >/dev/null 2>&1; then
  printf 'skip - python3 is required for observer proxy runtime tests\n'
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required for observer tests"
fi

python3 -m py_compile "$PROXY_SCRIPT"
pass "observer proxy passes Python syntax check"

python3 "$SCRIPT_DIR/test_observer_protocol.py"
pass "observer protocol normalizer and import mapping pass unit tests"

cat > "$TEST_ROOT/mock_upstream.py" <<'EOF'
#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def send(handler, event, data):
    handler.wfile.write(f"event: {event}\n".encode())
    handler.wfile.write(f"data: {json.dumps(data)}\n\n".encode())
    handler.wfile.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/api/v3/responses":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("content-length") or "0")
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        send(self, "response.created", {
            "type": "response.created",
            "response": {"id": "resp_mock", "model": "ep-test"},
        })
        send(self, "response.output_text.delta", {
            "type": "response.output_text.delta",
            "delta": "OK",
        })
        send(self, "response.output_item.added", {
            "type": "response.output_item.added",
            "item": {
                "type": "function_call",
                "call_id": "call_mock",
                "name": "get_time",
                "status": "in_progress",
            },
        })
        send(self, "response.output_item.done", {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call",
                "call_id": "call_mock",
                "name": "get_time",
                "arguments": "{}",
                "status": "completed",
            },
        })
        send(self, "response.completed", {
            "type": "response.completed",
            "response": {
                "id": "resp_mock",
                "model": "ep-test",
                "usage": {
                    "input_tokens": 20,
                    "output_tokens": 10,
                    "total_tokens": 30,
                    "input_tokens_details": {
                        "cached_tokens": 8,
                        "cache_write_tokens": 4,
                    },
                },
            },
        })


ThreadingHTTPServer(("127.0.0.1", int(os.environ["MOCK_PORT"])), Handler).serve_forever()
EOF

MOCK_PORT=18081 python3 "$TEST_ROOT/mock_upstream.py" > "$TEST_ROOT/mock.log" 2>&1 &
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
python3 "$PROXY_SCRIPT" > "$TEST_ROOT/proxy.log" 2>&1 &
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

cat > "$TEST_ROOT/import.json" <<'EOF'
{
  "schema_version": "observer.import.v1",
  "request_id": "imported-sdk-test",
  "source": {
    "kind": "codex_sdk",
    "name": "openai-codex-python"
  },
  "thread": {
    "thread_id": "thread-import",
    "turn_id": "turn-import"
  },
  "request": {
    "method": "IMPORT",
    "path": "/api/import",
    "status": 200,
    "body": {}
  },
  "events": [
    {
      "elapsed_ms": 10,
      "event": "item/agentMessage/delta",
      "data": {
        "delta": "SDK_OK"
      }
    },
    {
      "elapsed_ms": 20,
      "event": "turn.completed",
      "data": {
        "usage": {
          "total": {
            "inputTokens": 80,
            "cachedInputTokens": 40,
            "outputTokens": 5,
            "totalTokens": 85
          }
        }
      }
    }
  ]
}
EOF

curl -fsS \
  -H 'Content-Type: application/json' \
  --data-binary "@$TEST_ROOT/import.json" \
  http://127.0.0.1:18082/api/import > "$TEST_ROOT/import-result.json"
grep -q '"status": "imported"' "$TEST_ROOT/import-result.json" || fail "import API did not accept SDK log"
curl -fsS http://127.0.0.1:18082/api/requests/imported-sdk-test > "$TEST_ROOT/import-detail.json"
grep -q '"total_tokens": 85' "$TEST_ROOT/import-detail.json" || fail "import API did not rebuild token usage"
grep -q '"cached_tokens": 40' "$TEST_ROOT/import-detail.json" || fail "import API did not rebuild cached usage"
grep -q '"output_text_preview": "SDK_OK"' "$TEST_ROOT/import-detail.json" || fail "import API did not rebuild output"
pass "observer imports SDK logs into dashboard storage"

printf '\nAll Volcano Codex Observer tests passed.\n'
