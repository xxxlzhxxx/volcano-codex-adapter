# Volcano Codex Adapter

Utilities for switching a local project to Volcengine Ark / Volcano Engine
OpenAI-compatible Responses API settings, with rollback support and smoke tests
for Codex-style `User-Agent` routing.

## Files

- `switch_to_ark.sh`: detects project type and applies Ark model settings.
- `smoke_test_ark_responses.sh`: sends Codex-compatible Responses API test
  requests to Ark.
- `tests/run_tests.sh`: local shell tests for apply, status, rollback, and
  dry-run behavior.

## Supported Project Types

- Codex monorepo: detected by `codex-rs/Cargo.toml` and
  `codex-cli/package.json`.
- Node OpenAI-compatible project: detected by `package.json` dependencies on
  `openai` or `@ai-sdk/openai`.
- Python OpenAI-compatible project: detected by `requirements.txt` or
  `pyproject.toml` containing `openai`.
- Unknown project: falls back to writing OpenAI-compatible `.env` variables.

## Switch a Project to Ark

For a Codex project, the script writes project-local `.codex/config.toml`.
The config references `ARK_API_KEY` by environment variable and does not write
the key into TOML.

```bash
cd /path/to/project
export ARK_API_KEY="..."
export ARK_MODEL="ep-..."
/path/to/volcano-codex-adapter/switch_to_ark.sh apply
```

Then run Codex with the generated profile:

```bash
ARK_API_KEY="..." codex -p ark
```

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

Each `apply` creates a project-local backup under:

```text
.ark-switch/backups/<timestamp>/
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
```

The tests create temporary fixtures and do not call the network.

## Notes

- Default scope is project-local. The script intentionally does not modify
  `~/.codex/config.toml`.
- Ark may emit `response.reasoning_summary_*` SSE events even when the request
  sets `reasoning.summary = "none"`.
- The Codex provider config injects a Codex-style `User-Agent` with
  `http_headers`, which may be required for Ark compatibility routing.
