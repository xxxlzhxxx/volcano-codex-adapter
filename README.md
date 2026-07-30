# Volcano Codex Adapter

Utilities for switching a local project to Volcengine Ark / Volcano Engine
OpenAI-compatible Responses API settings, with rollback support and smoke tests
for Codex-style `User-Agent` routing.

## Files

- `switch_to_ark.sh`: detects project type and applies Ark model settings.
- `smoke_test_ark_responses.sh`: sends Codex-compatible Responses API test
  requests to Ark.
- `observer/proxy.py`: local Responses API proxy with token, cache, latency,
  tool-call, and raw SSE logging plus a browser dashboard.
- `observer/proxy.js`: optional Node.js implementation of the same observer.
- `tests/run_tests.sh`: local shell tests for apply, status, rollback, and
  dry-run behavior.
- `tests/run_codex_surface_tests.sh`: local shell tests for Codex CLI,
  app-server, TypeScript SDK, and Python SDK configuration surfaces.
- `tests/run_observer_tests.sh`: local mock-upstream tests for the observer
  proxy and dashboard API.

## Supported Project Types

- Codex monorepo: detected by `codex-rs/Cargo.toml` and
  `codex-cli/package.json`.
- Node OpenAI-compatible project: detected by `package.json` dependencies on
  `openai` or `@ai-sdk/openai`.
- Python OpenAI-compatible project: detected by `requirements.txt` or
  `pyproject.toml` containing `openai`.
- Unknown project: falls back to writing OpenAI-compatible `.env` variables.

## Switch a Project to Ark

For a Codex project, two scopes are supported:

- `SCOPE=project` writes project-local `.codex/config.toml`.
- `SCOPE=home` writes `${CODEX_HOME:-$HOME/.codex}/config.toml`.

For real Codex CLI, app-server, and SDK entry points, prefer `SCOPE=home`
unless you have already verified that the project config layer is enabled for
your trusted workspace. The config references `ARK_API_KEY` by environment
variable and does not write the key into TOML.

```bash
cd /path/to/project
export ARK_API_KEY="..."
export ARK_MODEL="ep-..."
SCOPE=home /path/to/volcano-codex-adapter/switch_to_ark.sh apply
```

Then run Codex:

```bash
ARK_API_KEY="..." codex
```

## Observer Dashboard

Start a local model-provider proxy:

```bash
cd /path/to/volcano-codex-adapter
export ARK_API_KEY="..."
python3 observer/proxy.py
```

Open the dashboard:

```text
http://127.0.0.1:17860/
```

Switch Codex to the observed provider endpoint:

```bash
cd /path/to/project
export ARK_API_KEY="..."
export ARK_MODEL="ep-..."
SCOPE=home OBSERVER=1 /path/to/volcano-codex-adapter/switch_to_ark.sh apply
```

Codex now sends Responses API traffic to:

```text
http://127.0.0.1:17860/api/v3/responses
```

The observer forwards traffic to Ark and records:

- request body and redacted headers
- raw SSE events
- input/output/total tokens
- cached tokens and cache hit ratio
- cache write tokens when present
- latency, first event, and TTFT
- function/tool calls
- output text preview

Logs are written under:

```text
.ark-observer/requests/
```

Useful observer variables:

```bash
export OBSERVER_HOST="127.0.0.1"
export OBSERVER_PORT="17860"
export ARK_UPSTREAM_BASE="https://ark.cn-beijing.volces.com/api/v3"
export OBSERVER_LOG_DIR="/tmp/ark-observer"
export OBSERVER_FILTER_REASONING_SUMMARY=1
```

`OBSERVER_FILTER_REASONING_SUMMARY=1` drops `response.reasoning_summary_*`
SSE events before forwarding them to Codex. This is useful for debugging Ark
compatibility issues where Codex rejects unexpected reasoning-summary event
ordering.

The observer default runtime is Python 3 with standard-library modules only. No
`pip install`, Node.js, or npm dependencies are required. The Node.js
implementation is kept as an optional fallback.

For Node, Python, and unknown projects, the script writes OpenAI-compatible
variables to `.env`:

```text
ARK_API_KEY=...
ARK_MODEL=...
ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
OPENAI_API_KEY=...
OPENAI_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
OPENAI_MODEL=...
OPENAI_USER_AGENT=...
```

`OPENAI_USER_AGENT` only takes effect if the target application reads it and
passes it to the SDK as a custom header.

## Rollback

Each `apply` creates a rollback backup. `SCOPE=project` stores it under:

```text
.ark-switch/backups/<timestamp>/
```

`SCOPE=home` stores it under:

```text
${CODEX_HOME:-$HOME/.codex}/.ark-switch/backups/<timestamp>/
```

Rollback the most recent change:

```bash
/path/to/volcano-codex-adapter/switch_to_ark.sh rollback
```

Rollback a specific backup:

```bash
/path/to/volcano-codex-adapter/switch_to_ark.sh rollback --backup 20260730-113804
```

Check state:

```bash
/path/to/volcano-codex-adapter/switch_to_ark.sh status
```

Preview without writing files:

```bash
ARK_API_KEY="..." ARK_MODEL="ep-..." \
  /path/to/volcano-codex-adapter/switch_to_ark.sh apply --dry-run
```

## Ark Responses Smoke Test

Use this to verify Ark accepts Codex-style Responses API requests and tool
schemas.

```bash
export ARK_API_KEY="..."
export ARK_MODEL="ep-..."
./smoke_test_ark_responses.sh
```

Optional variables:

```bash
export ARK_RESPONSES_URL="https://ark.cn-beijing.volces.com/api/v3/responses"
export USER_AGENT="codex_exec/0.0.0 (Mac OS; arm64) dumb (codex_exec; 0.0.0)"
export MAX_TIME=60
```

If `ARK_API_KEY` is not set, the script can read from `LLM_ENV_PATH`:

```bash
export LLM_ENV_PATH="/Users/bytedance/WorkSpace/LLM_env.md"
./smoke_test_ark_responses.sh
```

## Local Tests

Run:

```bash
./tests/run_tests.sh
./tests/run_codex_surface_tests.sh
./tests/run_observer_tests.sh
```

The tests create temporary fixtures and do not call the network.

## Notes

- Default scope is project-local. Use `SCOPE=home` explicitly when you want to
  modify `${CODEX_HOME:-$HOME/.codex}/config.toml`.
- Ark may emit `response.reasoning_summary_*` SSE events even when the request
  sets `reasoning.summary = "none"`.
- The Codex provider config injects a Codex-style `User-Agent` with
  `http_headers`, which may be required for Ark compatibility routing.
