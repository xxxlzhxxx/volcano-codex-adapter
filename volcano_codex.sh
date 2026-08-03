#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH_SCRIPT="${SCRIPT_DIR}/switch_to_ark.sh"
OBSERVER_SCRIPT="${SCRIPT_DIR}/observer/proxy.py"

COMMAND="${1:-help}"
shift || true

WORK_DIR="${WORK_DIR:-}"
TARGET_SCOPE="${TARGET_SCOPE:-}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
ARK_API_KEY="${ARK_API_KEY:-}"
ARK_MODEL="${ARK_MODEL:-}"
ARK_UPSTREAM_BASE="${ARK_UPSTREAM_BASE:-https://ark.cn-beijing.volces.com/api/v3}"
OBSERVER_HOST="${OBSERVER_HOST:-127.0.0.1}"
OBSERVER_PORT="${OBSERVER_PORT:-17860}"
FILTER_REASONING_SUMMARY="${FILTER_REASONING_SUMMARY:-0}"
INTERACTIVE="${INTERACTIVE:-0}"

usage() {
  cat <<'EOF'
Usage:
  volcano_codex.sh apply-observed [--global | --work-dir DIR] [--api-key KEY] [--model EP] [--port PORT] [--upstream URL] [--interactive] [--filter-reasoning-summary]
  volcano_codex.sh status (--global | --work-dir DIR)
  volcano_codex.sh stop-observer (--global | --work-dir DIR)
  volcano_codex.sh rollback (--global | --work-dir DIR)

Environment alternatives:
  TARGET_SCOPE=global|workdir, WORK_DIR, CODEX_HOME, ARK_API_KEY, ARK_MODEL, ARK_UPSTREAM_BASE, OBSERVER_HOST, OBSERVER_PORT, INTERACTIVE=1

Work-dir state is stored under:
  <work-dir>/.volcano-codex/

Global state is stored under:
  ${CODEX_HOME:-$HOME/.codex}/.volcano-codex/
EOF
}

abs_dir() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && pwd)
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global)
        TARGET_SCOPE="global"
        shift
        ;;
      --work-dir)
        WORK_DIR="${2:-}"
        TARGET_SCOPE="workdir"
        shift 2
        ;;
      --api-key)
        ARK_API_KEY="${2:-}"
        shift 2
        ;;
      --model|--ep)
        ARK_MODEL="${2:-}"
        shift 2
        ;;
      --port)
        OBSERVER_PORT="${2:-}"
        shift 2
        ;;
      --host)
        OBSERVER_HOST="${2:-}"
        shift 2
        ;;
      --upstream)
        ARK_UPSTREAM_BASE="${2:-}"
        shift 2
        ;;
      --filter-reasoning-summary)
        FILTER_REASONING_SUMMARY="1"
        shift
        ;;
      --interactive)
        INTERACTIVE="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  if ! IFS= read -r value; then
    echo "Missing required input: ${prompt}" >&2
    exit 1
  fi

  if [[ -z "$value" ]]; then
    value="$default"
  fi

  printf '%s' "$value"
}

prompt_apply_inputs() {
  local asked="false"

  if [[ -z "$TARGET_SCOPE" && -z "$WORK_DIR" ]]; then
    echo "请选择要接入的 Codex 配置范围：" >&2
    echo "  1) 全局 ${CODEX_HOME_DIR}" >&2
    echo "  2) 指定目录" >&2
    local choice
    choice="$(prompt_value "输入 1 或 2" "1")"
    case "$choice" in
      1|global|Global|GLOBAL)
        TARGET_SCOPE="global"
        ;;
      2|dir|workdir|project)
        TARGET_SCOPE="workdir"
        ;;
      *)
        echo "Unsupported Codex scope: ${choice}" >&2
        exit 1
        ;;
    esac
    asked="true"
  fi

  if [[ "$TARGET_SCOPE" == "workdir" && -z "$WORK_DIR" ]]; then
    WORK_DIR="$(prompt_value "请输入要接入的项目目录")"
    asked="true"
  fi

  if [[ -z "$ARK_API_KEY" ]]; then
    ARK_API_KEY="$(prompt_value "请输入火山 Ark API Key")"
    asked="true"
  fi

  if [[ -z "$ARK_MODEL" ]]; then
    ARK_MODEL="$(prompt_value "请输入火山 Ark EP / 模型 ID")"
    asked="true"
  fi

  if [[ "$INTERACTIVE" == "1" || "$asked" == "true" ]]; then
    ARK_UPSTREAM_BASE="$(prompt_value "请输入火山 Ark API Base URL" "$ARK_UPSTREAM_BASE")"
  fi
}

require_target() {
  if [[ -z "$TARGET_SCOPE" && -n "$WORK_DIR" ]]; then
    TARGET_SCOPE="workdir"
  fi

  case "$TARGET_SCOPE" in
    global)
      ;;
    workdir|"")
      if [[ -z "$WORK_DIR" ]]; then
        echo "--global or --work-dir is required." >&2
        exit 1
      fi
      TARGET_SCOPE="workdir"
      WORK_DIR="$(abs_dir "$WORK_DIR")"
      ;;
    *)
      echo "Unsupported TARGET_SCOPE=${TARGET_SCOPE}. Use global or workdir." >&2
      exit 1
      ;;
  esac
}

state_dir() {
  if [[ "$TARGET_SCOPE" == "global" ]]; then
    echo "${CODEX_HOME_DIR}/.volcano-codex"
  else
    echo "${WORK_DIR}/.volcano-codex"
  fi
}

state_file() {
  echo "$(state_dir)/state.env"
}

observer_pid_file() {
  echo "$(state_dir)/observer.pid"
}

codex_home_dir() {
  if [[ "$TARGET_SCOPE" == "global" ]]; then
    echo "$CODEX_HOME_DIR"
  else
    echo "$(state_dir)/codex-home"
  fi
}

observer_log_dir() {
  echo "$(state_dir)/observer"
}

observer_base_url() {
  echo "http://${OBSERVER_HOST}:${OBSERVER_PORT}/api/v3"
}

dashboard_url() {
  echo "http://${OBSERVER_HOST}:${OBSERVER_PORT}/"
}

load_observer_state() {
  local file
  local value
  file="$(state_file)"
  [[ -f "$file" ]] || return 0

  value="$(sed -n 's/^OBSERVER_HOST="\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  [[ -n "$value" ]] && OBSERVER_HOST="$value"

  value="$(sed -n 's/^OBSERVER_PORT="\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  [[ -n "$value" ]] && OBSERVER_PORT="$value"
}

wait_for_observer() {
  local health_url="http://${OBSERVER_HOST}:${OBSERVER_PORT}/health"
  local attempts=80
  while [[ "$attempts" -gt 0 ]]; do
    if curl -fsS "$health_url" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

current_observer_pid() {
  local pid_file
  pid_file="$(observer_pid_file)"
  [[ -f "$pid_file" ]] && sed -n '1p' "$pid_file" || true
}

start_observer() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to run observer/proxy.py" >&2
    exit 1
  fi

  local existing_pid
  existing_pid="$(current_observer_pid)"
  if is_pid_running "$existing_pid"; then
    echo "Observer already running: pid=${existing_pid}"
    return
  fi

  mkdir -p "$(state_dir)" "$(observer_log_dir)"

  OBSERVER_HOST="$OBSERVER_HOST" \
    OBSERVER_PORT="$OBSERVER_PORT" \
    ARK_UPSTREAM_BASE="$ARK_UPSTREAM_BASE" \
    ARK_MODEL="$ARK_MODEL" \
    OBSERVER_LOG_DIR="$(observer_log_dir)" \
    OBSERVER_FILTER_REASONING_SUMMARY="$FILTER_REASONING_SUMMARY" \
    ARK_API_KEY="$ARK_API_KEY" \
    python3 "$OBSERVER_SCRIPT" > "$(state_dir)/observer.stdout.log" 2> "$(state_dir)/observer.stderr.log" &

  local pid="$!"
  echo "$pid" > "$(observer_pid_file)"

  if ! wait_for_observer; then
    echo "Observer failed to start. stderr:" >&2
    sed -n '1,120p' "$(state_dir)/observer.stderr.log" >&2 || true
    exit 1
  fi
  echo "Observer started: pid=${pid}, dashboard=$(dashboard_url)"
}

stop_observer() {
  require_target
  local pid
  pid="$(current_observer_pid)"
  if is_pid_running "$pid"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "Observer stopped: pid=${pid}"
  else
    echo "Observer is not running."
  fi
  rm -f "$(observer_pid_file)"
}

write_state() {
  mkdir -p "$(state_dir)"
  cat > "$(state_file)" <<EOF
TARGET_SCOPE="${TARGET_SCOPE}"
WORK_DIR="${WORK_DIR}"
CODEX_HOME="$(codex_home_dir)"
ARK_MODEL="${ARK_MODEL}"
ARK_UPSTREAM_BASE="${ARK_UPSTREAM_BASE}"
OBSERVER_HOST="${OBSERVER_HOST}"
OBSERVER_PORT="${OBSERVER_PORT}"
OBSERVER_BASE_URL="$(observer_base_url)"
DASHBOARD_URL="$(dashboard_url)"
OBSERVER_LOG_DIR="$(observer_log_dir)"
FILTER_REASONING_SUMMARY="${FILTER_REASONING_SUMMARY}"
EOF
}

apply_observed() {
  parse_args "$@"
  prompt_apply_inputs
  require_target
  if [[ -z "$ARK_API_KEY" ]]; then
    echo "--api-key or ARK_API_KEY is required." >&2
    exit 1
  fi
  if [[ -z "$ARK_MODEL" ]]; then
    echo "--model/--ep or ARK_MODEL is required." >&2
    exit 1
  fi

  mkdir -p "$(codex_home_dir)" "$(observer_log_dir)"
  start_observer

  PROJECT_DIR="${WORK_DIR:-$PWD}" \
    CODEX_HOME="$(codex_home_dir)" \
    SCOPE=home \
    OBSERVER=1 \
    OBSERVER_BASE_URL="$(observer_base_url)" \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    ARK_BASE_URL="$ARK_UPSTREAM_BASE" \
    "$SWITCH_SCRIPT" apply

  write_state

  cat <<EOF

Applied observed Volcano Codex config.
Scope:         ${TARGET_SCOPE}
Work dir:      ${WORK_DIR:-<global>}
Codex home:    $(codex_home_dir)
Model / EP:    ${ARK_MODEL}
Proxy base:    $(observer_base_url)
Dashboard:     $(dashboard_url)
Observer logs: $(observer_log_dir)/requests

Run Codex with:
  cd "${WORK_DIR:-$PWD}"
  CODEX_HOME="$(codex_home_dir)" ARK_API_KEY="***" codex

Rollback with:
  ${SCRIPT_DIR}/volcano_codex.sh rollback $(if [[ "$TARGET_SCOPE" == "global" ]]; then echo "--global"; else printf '%s %q' "--work-dir" "$WORK_DIR"; fi)
EOF
}

status() {
  parse_args "$@"
  require_target
  load_observer_state
  local pid
  pid="$(current_observer_pid)"
  echo "Scope: ${TARGET_SCOPE}"
  echo "Work dir: ${WORK_DIR:-<global>}"
  echo "Codex home: $(codex_home_dir)"
  echo "State dir: $(state_dir)"
  if [[ -f "$(state_file)" ]]; then
    echo
    echo "State:"
    sed 's/ARK_API_KEY=.*/ARK_API_KEY="<redacted>"/' "$(state_file)"
  else
    echo "State: not configured"
  fi
  echo
  if is_pid_running "$pid"; then
    echo "Observer: running pid=${pid}"
  else
    echo "Observer: stopped"
  fi
  echo "Dashboard: $(dashboard_url)"
  echo "Requests API: http://${OBSERVER_HOST}:${OBSERVER_PORT}/api/requests"
}

rollback() {
  parse_args "$@"
  require_target
  PROJECT_DIR="${WORK_DIR:-$PWD}" \
    CODEX_HOME="$(codex_home_dir)" \
    SCOPE=home \
    "$SWITCH_SCRIPT" rollback
  if [[ "$TARGET_SCOPE" == "global" ]]; then
    stop_observer --global
  else
    stop_observer --work-dir "$WORK_DIR"
  fi
  echo "Rolled back observed Volcano Codex config."
}

case "$COMMAND" in
  apply-observed)
    apply_observed "$@"
    ;;
  status)
    status "$@"
    ;;
  stop-observer)
    parse_args "$@"
    stop_observer
    ;;
  rollback)
    rollback "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
