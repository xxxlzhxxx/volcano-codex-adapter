#!/usr/bin/env bash
set -euo pipefail

ARK_RESPONSES_URL="${ARK_RESPONSES_URL:-https://ark.cn-beijing.volces.com/api/v3/responses}"
ARK_MODEL="${ARK_MODEL:-ep-20260709164026-mblzl}"
LLM_ENV_PATH="${LLM_ENV_PATH:-/Users/bytedance/WorkSpace/LLM_env.md}"
USER_AGENT="${USER_AGENT:-codex_exec/0.0.0 (Mac OS; arm64) dumb (codex_exec; 0.0.0)}"
MAX_TIME="${MAX_TIME:-60}"

if [[ -z "${ARK_API_KEY:-}" && -f "$LLM_ENV_PATH" ]]; then
  ARK_API_KEY="$(
    awk '
      found && /API key/ {
        sub(/^.*[：:][[:space:]]*/, "");
        print;
        exit
      }
      /以下账号/ { found = 1 }
    ' "$LLM_ENV_PATH"
  )"
fi

if [[ -z "${ARK_API_KEY:-}" ]]; then
  cat >&2 <<'EOF'
ARK_API_KEY is required.

Set it explicitly:
  export ARK_API_KEY="..."

Or point LLM_ENV_PATH to a file that contains the Ark API key:
  export LLM_ENV_PATH="/Users/bytedance/WorkSpace/LLM_env.md"
EOF
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to build JSON request bodies." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to call Ark Responses API." >&2
  exit 1
fi

make_body() {
  local prompt="$1"
  local tools="$2"
  jq -nc \
    --arg model "$ARK_MODEL" \
    --arg prompt "$prompt" \
    --argjson tools "$tools" \
    '{
      model: $model,
      instructions: "你是 Codex Responses API 兼容性测试模型。用户要求调用工具时必须调用工具；否则只回复 OK。",
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: $prompt
            }
          ]
        }
      ],
      tools: $tools,
      tool_choice: "auto",
      parallel_tool_calls: false,
      reasoning: {
        summary: "none"
      },
      store: false,
      stream: true,
      include: [
        "reasoning.encrypted_content"
      ]
    }'
}

run_case() {
  local name="$1"
  local prompt="$2"
  local tools="$3"
  local body
  local output
  local status

  body="$(make_body "$prompt" "$tools")"
  output="$(mktemp)"

  status="$(
    curl -sS -N \
      --connect-timeout 10 \
      --max-time "$MAX_TIME" \
      -o "$output" \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${ARK_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: text/event-stream" \
      -H "User-Agent: ${USER_AGENT}" \
      --data-binary "$body" \
      "$ARK_RESPONSES_URL" || true
  )"

  printf '\n== %s ==\n' "$name"
  printf 'HTTP: %s\n' "$status"
  printf 'Model: %s\n' "$ARK_MODEL"
  printf 'User-Agent: %s\n' "$USER_AGENT"

  if [[ "$status" == "200" ]]; then
    printf 'Events: '
    grep '^event:' "$output" \
      | sed 's/^event: //' \
      | sort \
      | uniq \
      | tr '\n' ',' \
      | sed 's/,$//'
    printf '\n'

    printf 'Tool markers:\n'
    grep '^data:' "$output" \
      | grep -E 'function_call|custom_tool_call|web_search_call|"name"|"arguments"|"input"' \
      | head -n 12 || true
  else
    printf 'Error body:\n'
    head -c 2000 "$output"
    printf '\n'
    rm -f "$output"
    return 1
  fi

  rm -f "$output"
}

function_tool='[
  {
    "type": "function",
    "name": "get_time",
    "description": "Return current time.",
    "strict": false,
    "parameters": {
      "type": "object",
      "properties": {},
      "additionalProperties": false
    }
  }
]'

custom_tool='[
  {
    "type": "custom",
    "name": "apply_patch",
    "description": "Apply a patch.",
    "format": {
      "type": "grammar",
      "syntax": "lark",
      "definition": "start: /(.|\\n)+/"
    }
  }
]'

namespace_tool='[
  {
    "type": "namespace",
    "name": "multi_agent_v1",
    "description": "Tools in namespace.",
    "tools": [
      {
        "type": "function",
        "name": "spawn_agent",
        "description": "Spawn an agent.",
        "strict": false,
        "parameters": {
          "type": "object",
          "properties": {
            "prompt": {
              "type": "string"
            }
          },
          "required": [
            "prompt"
          ],
          "additionalProperties": false
        }
      }
    ]
  }
]'

web_search_tool='[
  {
    "type": "web_search",
    "external_web_access": false
  }
]'

run_case "no_tools" "只回复 OK，不要调用工具。" '[]'
run_case "function_schema" "只回复 OK，不要调用工具。" "$function_tool"
run_case "custom_apply_patch_schema" "只回复 OK，不要调用工具。" "$custom_tool"
run_case "namespace_schema" "只回复 OK，不要调用工具。" "$namespace_tool"
run_case "web_search_schema" "只回复 OK，不要调用工具。" "$web_search_tool"
run_case "force_function_call" "请调用 get_time 工具，参数为空。" "$function_tool"
