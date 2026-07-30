#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-status}"
shift || true

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
ARK_API_KEY="${ARK_API_KEY:-}"
ARK_MODEL="${ARK_MODEL:-}"
ARK_BASE_URL="${ARK_BASE_URL:-https://ark.cn-beijing.volces.com/api/v3}"
ARK_UA="${ARK_UA:-codex_exec/0.0.0 (Mac OS; arm64) dumb (codex_exec; 0.0.0)}"
SCOPE="${SCOPE:-project}"
DRY_RUN="false"
BACKUP_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --backup)
      BACKUP_ID="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

STATE_DIR="${PROJECT_DIR}/.ark-switch"
BACKUP_ROOT="${STATE_DIR}/backups"
CURRENT_FILE="${STATE_DIR}/current.json"

timestamp() {
  date +%Y%m%d-%H%M%S
}

is_codex_project() {
  [[ -f "$PROJECT_DIR/codex-rs/Cargo.toml" && -f "$PROJECT_DIR/codex-cli/package.json" ]]
}

is_node_openai_project() {
  [[ -f "$PROJECT_DIR/package.json" ]] && grep -Eq '"(@ai-sdk/openai|openai)"' "$PROJECT_DIR/package.json"
}

is_python_openai_project() {
  {
    [[ -f "$PROJECT_DIR/requirements.txt" ]] && grep -Eq '(^|[<=> ])openai([<=> ]|$)' "$PROJECT_DIR/requirements.txt"
  } || {
    [[ -f "$PROJECT_DIR/pyproject.toml" ]] && grep -Eq 'openai' "$PROJECT_DIR/pyproject.toml"
  }
}

detect_project_type() {
  if is_codex_project; then
    echo "codex"
  elif is_node_openai_project; then
    echo "node-openai"
  elif is_python_openai_project; then
    echo "python-openai"
  else
    echo "unknown"
  fi
}

backup_file() {
  local backup_dir="$1"
  local rel_path="$2"
  local backup_name="$3"
  local abs_path="${PROJECT_DIR}/${rel_path}"

  mkdir -p "$backup_dir"

  if [[ -f "$abs_path" ]]; then
    cp "$abs_path" "${backup_dir}/${backup_name}"
    echo "{\"path\":\"${rel_path}\",\"backup\":\"${backup_name}\",\"existed\":true}"
  else
    echo "{\"path\":\"${rel_path}\",\"backup\":\"${backup_name}\",\"existed\":false}"
  fi
}

write_manifest() {
  local backup_dir="$1"
  local backup_id="$2"
  local project_type="$3"
  local changes_json="$4"

  cat > "${backup_dir}/manifest.json" <<EOF
{
  "timestamp": "${backup_id}",
  "project_dir": "${PROJECT_DIR}",
  "project_type": "${project_type}",
  "changes": [
${changes_json}
  ]
}
EOF

  cat > "$CURRENT_FILE" <<EOF
{
  "latest_backup": "${backup_id}"
}
EOF
}

apply_codex_config() {
  local backup_id="$1"
  local backup_dir="$2"
  local config_rel=".codex/config.toml"
  local config_abs="${PROJECT_DIR}/${config_rel}"

  if [[ "$SCOPE" != "project" ]]; then
    echo "Only SCOPE=project is supported by this rollback-safe script." >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would append Ark provider config to $config_abs" >&2
    return
  fi

  local change
  change="$(backup_file "$backup_dir" "$config_rel" "codex_config.toml")"

  mkdir -p "$(dirname "$config_abs")"

  cat >> "$config_abs" <<EOF

# >>> ark-switch:${backup_id}
model = "${ARK_MODEL}"
model_provider = "volcengine-ark"

[model_providers.volcengine-ark]
name = "Volcengine Ark"
base_url = "${ARK_BASE_URL}"
env_key = "ARK_API_KEY"
wire_api = "responses"
http_headers = { "User-Agent" = "${ARK_UA}" }

[profiles.ark]
model = "${ARK_MODEL}"
model_provider = "volcengine-ark"
# <<< ark-switch:${backup_id}
EOF

  echo "$change"
}

apply_env_config() {
  local backup_id="$1"
  local backup_dir="$2"
  local env_rel=".env"
  local env_abs="${PROJECT_DIR}/${env_rel}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would append Ark env vars to $env_abs" >&2
    return
  fi

  local change
  change="$(backup_file "$backup_dir" "$env_rel" "env")"

  cat >> "$env_abs" <<EOF

# >>> ark-switch:${backup_id}
ARK_API_KEY=${ARK_API_KEY}
ARK_MODEL=${ARK_MODEL}
ARK_BASE_URL=${ARK_BASE_URL}
OPENAI_API_KEY=${ARK_API_KEY}
OPENAI_BASE_URL=${ARK_BASE_URL}
OPENAI_MODEL=${ARK_MODEL}
OPENAI_USER_AGENT=${ARK_UA}
# <<< ark-switch:${backup_id}
EOF

  echo "$change"
}

apply() {
  if [[ -z "$ARK_MODEL" ]]; then
    echo "ARK_MODEL is required, e.g. export ARK_MODEL=ep-..." >&2
    exit 1
  fi

  if [[ -z "$ARK_API_KEY" ]]; then
    echo "ARK_API_KEY is required. Prefer exporting it instead of hardcoding it." >&2
    exit 1
  fi

  local project_type
  project_type="$(detect_project_type)"

  local backup_id
  backup_id="$(timestamp)"

  local backup_dir="${BACKUP_ROOT}/${backup_id}"

  echo "Detected project type: ${project_type}"
  echo "Backup id: ${backup_id}"

  if [[ "$DRY_RUN" == "false" ]]; then
    mkdir -p "$backup_dir"
  fi

  local changes=()

  case "$project_type" in
    codex)
      local change
      change="$(apply_codex_config "$backup_id" "$backup_dir")"
      [[ -n "$change" ]] && changes+=("$change")
      ;;
    node-openai|python-openai|unknown)
      local change
      change="$(apply_env_config "$backup_id" "$backup_dir")"
      [[ -n "$change" ]] && changes+=("$change")
      ;;
  esac

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] No files changed."
    exit 0
  fi

  local changes_json=""
  local first="true"
  for change in "${changes[@]}"; do
    if [[ "$first" == "true" ]]; then
      changes_json="    ${change}"
      first="false"
    else
      changes_json="${changes_json},
    ${change}"
    fi
  done

  write_manifest "$backup_dir" "$backup_id" "$project_type" "$changes_json"

  echo "Applied Ark switch."
  echo "Rollback with: $0 rollback --backup ${backup_id}"
}

latest_backup_id() {
  if [[ -n "$BACKUP_ID" ]]; then
    echo "$BACKUP_ID"
    return
  fi

  if [[ -f "$CURRENT_FILE" ]]; then
    sed -n 's/.*"latest_backup"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CURRENT_FILE" | head -n 1
    return
  fi

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tail -n 1
}

rollback() {
  local backup_id
  backup_id="$(latest_backup_id)"

  if [[ -z "$backup_id" ]]; then
    echo "No backup found." >&2
    exit 1
  fi

  local backup_dir="${BACKUP_ROOT}/${backup_id}"
  local manifest="${backup_dir}/manifest.json"

  if [[ ! -f "$manifest" ]]; then
    echo "Backup manifest not found: $manifest" >&2
    exit 1
  fi

  echo "Rolling back backup: ${backup_id}"

  grep -o '{"path":"[^"]*","backup":"[^"]*","existed":[^}]*}' "$manifest" | while read -r item; do
    local rel_path backup existed abs_path backup_path
    rel_path="$(echo "$item" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
    backup="$(echo "$item" | sed -n 's/.*"backup":"\([^"]*\)".*/\1/p')"
    existed="$(echo "$item" | sed -n 's/.*"existed":\([^}]*\).*/\1/p')"

    abs_path="${PROJECT_DIR}/${rel_path}"
    backup_path="${backup_dir}/${backup}"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would restore $rel_path existed=$existed"
      continue
    fi

    if [[ "$existed" == "true" ]]; then
      mkdir -p "$(dirname "$abs_path")"
      cp "$backup_path" "$abs_path"
      echo "Restored: $rel_path"
    else
      rm -f "$abs_path"
      echo "Removed newly-created file: $rel_path"
    fi
  done

  echo "Rollback complete."
}

status() {
  echo "Project dir: $PROJECT_DIR"
  echo "Detected project type: $(detect_project_type)"
  echo

  if [[ -f "$CURRENT_FILE" ]]; then
    echo "Current:"
    cat "$CURRENT_FILE"
    echo
  else
    echo "Current: no ark-switch state"
  fi

  echo "Backups:"
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort || true
}

case "$COMMAND" in
  apply)
    apply
    ;;
  rollback)
    rollback
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 apply|rollback|status [--dry-run] [--backup BACKUP_ID]" >&2
    exit 1
    ;;
esac
