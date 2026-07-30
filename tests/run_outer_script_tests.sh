#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTER_SCRIPT="${ADAPTER_DIR}/volcano_codex.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/volcano-outer-tests.XXXXXX")"
trap 'cleanup' EXIT

MOCK_PID=""

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [[ -d "$TEST_ROOT/work" ]]; then
    "$OUTER_SCRIPT" stop-observer --work-dir "$TEST_ROOT/work" >/dev/null 2>&1 || true
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
  local attempts=60
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
  printf 'skip - python3 is required for outer script tests\n'
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required for outer script tests"
fi

bash -n "$OUTER_SCRIPT"
pass "outer script passes bash syntax check"

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
        self.end_headers()
        send(self, "response.output_text.delta", {
            "type": "response.output_text.delta",
            "delta": "OK",
        })
        send(self, "response.completed", {
            "type": "response.completed",
            "response": {
                "id": "resp_outer",
                "model": "ep-outer",
                "usage": {
                    "input_tokens": 12,
                    "output_tokens": 3,
                    "total_tokens": 15,
                    "input_tokens_details": {
                        "cached_tokens": 6
                    }
                }
            }
        })


ThreadingHTTPServer(("127.0.0.1", int(os.environ["MOCK_PORT"])), Handler).serve_forever()
EOF

MOCK_PORT=18091 python3 "$TEST_ROOT/mock_upstream.py" > "$TEST_ROOT/mock.log" 2>&1 &
MOCK_PID="$!"
wait_for_url "http://127.0.0.1:18091/health" || {
  cat "$TEST_ROOT/mock.log" >&2
  fail "mock upstream did not start"
}

WORK_DIR="$TEST_ROOT/work"
mkdir -p "$WORK_DIR"

"$OUTER_SCRIPT" apply-observed \
  --work-dir "$WORK_DIR" \
  --api-key test-key \
  --model ep-outer \
  --port 18092 \
  --upstream http://127.0.0.1:18091/api/v3 \
  >/tmp/volcano_outer_apply.log

wait_for_url "http://127.0.0.1:18092/health" || fail "observer did not start from outer script"
pass "outer script starts observer for work dir"

CONFIG_FILE="$WORK_DIR/.volcano-codex/codex-home/config.toml"
grep -q 'model = "ep-outer"' "$CONFIG_FILE" || fail "outer script did not write target EP"
grep -q 'base_url = "http://127.0.0.1:18092/api/v3"' "$CONFIG_FILE" || fail "outer script did not write observer base URL"
pass "outer script switches work dir Codex home to observed Volcano provider"

STATE_FILE="$WORK_DIR/.volcano-codex/state.env"
grep -q 'ARK_MODEL="ep-outer"' "$STATE_FILE" || fail "state file did not record EP"
grep -q 'OBSERVER_LOG_DIR="' "$STATE_FILE" || fail "state file did not record observer log dir"
pass "outer script records work-dir state"

body='{"model":"ep-outer","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":true}'
curl -fsS -N \
  -H 'Authorization: Bearer test-key' \
  -H 'Content-Type: application/json' \
  --data-binary "$body" \
  http://127.0.0.1:18092/api/v3/responses \
  > "$TEST_ROOT/response.sse"

grep -q 'response.completed' "$TEST_ROOT/response.sse" || fail "observer response did not complete"
curl -fsS http://127.0.0.1:18092/api/requests > "$TEST_ROOT/requests.json"
grep -q '"model": "ep-outer"' "$TEST_ROOT/requests.json" || fail "observer did not record modified EP"
grep -q '"total_tokens": 15' "$TEST_ROOT/requests.json" || fail "observer did not record token usage"
grep -q '"cache_hit_ratio": 0.5' "$TEST_ROOT/requests.json" || fail "observer did not record cache hit ratio"
pass "outer script observer records EP metrics under work dir"

find "$WORK_DIR/.volcano-codex/observer/requests" -name '*.summary.json' | grep -q . || fail "observer summaries were not written under work dir"
pass "observer logs are stored under target work dir"

"$OUTER_SCRIPT" status --work-dir "$WORK_DIR" > "$TEST_ROOT/status.txt"
grep -q 'Observer: running' "$TEST_ROOT/status.txt" || fail "status did not report observer running"
pass "outer script reports status"

"$OUTER_SCRIPT" rollback --work-dir "$WORK_DIR" >/dev/null
[[ ! -f "$CONFIG_FILE" ]] || fail "rollback did not remove generated Codex config"
if curl -fsS http://127.0.0.1:18092/health >/dev/null 2>&1; then
  fail "rollback did not stop observer"
fi
pass "outer script rollback restores config and stops observer"

printf '\nAll Volcano Codex outer script tests passed.\n'
