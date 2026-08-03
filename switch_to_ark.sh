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
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
OBSERVER="${OBSERVER:-0}"
OBSERVER_BASE_URL="${OBSERVER_BASE_URL:-http://127.0.0.1:17860/api/v3}"
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

if [[ "$SCOPE" == "home" ]]; then
  STATE_DIR="${CODEX_HOME_DIR}/.ark-switch"
else
  STATE_DIR="${PROJECT_DIR}/.ark-switch"
fi
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

effective_base_url() {
  if [[ "$OBSERVER" == "1" || "$OBSERVER" == "true" ]]; then
    echo "$OBSERVER_BASE_URL"
  else
    echo "$ARK_BASE_URL"
  fi
}

rewrite_codex_config() {
  local config_abs="$1"
  local backup_id="$2"
  local provider_base_url="$3"
  local env_key_line=""
  local tmp_base="${config_abs}.ark-switch.${backup_id}"
  local normalized="${tmp_base}.normalized"
  local cleaned="${tmp_base}.cleaned"

  if [[ "$OBSERVER" != "1" && "$OBSERVER" != "true" ]]; then
    env_key_line='env_key = "ARK_API_KEY"'
  fi

  if [[ -f "$config_abs" ]]; then
    awk -v model="$ARK_MODEL" '
      BEGIN {
        before_table = 1
        saw_model = 0
        saw_provider = 0
      }
      /^\[/ && before_table {
        if (!saw_model) {
          print "model = \"" model "\""
        }
        if (!saw_provider) {
          print "model_provider = \"volcengine-ark\""
        }
        before_table = 0
      }
      before_table && $0 ~ /^model[[:space:]]*=/ {
        print "model = \"" model "\""
        saw_model = 1
        next
      }
      before_table && $0 ~ /^model_provider[[:space:]]*=/ {
        print "model_provider = \"volcengine-ark\""
        saw_provider = 1
        next
      }
      { print }
      END {
        if (before_table) {
          if (!saw_model) {
            print "model = \"" model "\""
          }
          if (!saw_provider) {
            print "model_provider = \"volcengine-ark\""
          }
        }
      }
    ' "$config_abs" > "$normalized"
  else
    cat > "$normalized" <<EOF
model = "${ARK_MODEL}"
model_provider = "volcengine-ark"
EOF
  fi

  awk '
    /^# >>> ark-switch:/ {
      skip = 1
      next
    }
    /^# <<< ark-switch:/ {
      skip = 0
      next
    }
    !skip {
      print
    }
  ' "$normalized" > "$cleaned"

  cat >> "$cleaned" <<EOF

# >>> ark-switch:${backup_id}
[model_providers.volcengine-ark]
name = "Volcengine Ark"
base_url = "${provider_base_url}"
${env_key_line}
wire_api = "responses"
http_headers = { "User-Agent" = "${ARK_UA}" }

[profiles.ark]
model = "${ARK_MODEL}"
model_provider = "volcengine-ark"
# <<< ark-switch:${backup_id}
EOF

  mv "$cleaned" "$config_abs"
  rm -f "$normalized"
}

backup_file() {
  local backup_dir="$1"
  local path="$2"
  local backup_name="$3"
  local abs_path

  if [[ "$path" = /* ]]; then
    abs_path="$path"
  else
    abs_path="${PROJECT_DIR}/${path}"
  fi

  mkdir -p "$backup_dir"

  if [[ -f "$abs_path" ]]; then
    cp "$abs_path" "${backup_dir}/${backup_name}"
    echo "{\"path\":\"${path}\",\"backup\":\"${backup_name}\",\"existed\":true}"
  else
    echo "{\"path\":\"${path}\",\"backup\":\"${backup_name}\",\"existed\":false}"
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
  local config_path=".codex/config.toml"
  local config_abs="${PROJECT_DIR}/${config_path}"
  local provider_base_url
  provider_base_url="$(effective_base_url)"

  if [[ "$SCOPE" == "home" ]]; then
    config_path="${CODEX_HOME_DIR}/config.toml"
    config_abs="$config_path"
  elif [[ "$SCOPE" != "project" ]]; then
    echo "Unsupported SCOPE=${SCOPE}. Use SCOPE=project or SCOPE=home." >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would write Ark provider config to $config_abs" >&2
    return
  fi

  local change
  change="$(backup_file "$backup_dir" "$config_path" "codex_config.toml")"

  mkdir -p "$(dirname "$config_abs")"
  rewrite_codex_config "$config_abs" "$backup_id" "$provider_base_url"

  echo "$change"
}

apply_env_config() {
  local backup_id="$1"
  local backup_dir="$2"
  local env_rel=".env"
  local env_abs="${PROJECT_DIR}/${env_rel}"
  local provider_base_url
  provider_base_url="$(effective_base_url)"

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
OPENAI_BASE_URL=${provider_base_url}
OPENAI_MODEL=${ARK_MODEL}
OPENAI_USER_AGENT=${ARK_UA}
VOLCANO_CODEX_OBSERVER=${OBSERVER}
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

  if [[ "$SCOPE" == "home" ]]; then
    local change
    change="$(apply_codex_config "$backup_id" "$backup_dir")"
    [[ -n "$change" ]] && changes+=("$change")
  else
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
  fi

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
    local path backup existed abs_path backup_path
    path="$(echo "$item" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
    backup="$(echo "$item" | sed -n 's/.*"backup":"\([^"]*\)".*/\1/p')"
    existed="$(echo "$item" | sed -n 's/.*"existed":\([^}]*\).*/\1/p')"

    if [[ "$path" = /* ]]; then
      abs_path="$path"
    else
      abs_path="${PROJECT_DIR}/${path}"
    fi
    backup_path="${backup_dir}/${backup}"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would restore $path existed=$existed"
      continue
    fi

    if [[ "$existed" == "true" ]]; then
      mkdir -p "$(dirname "$abs_path")"
      cp "$backup_path" "$abs_path"
      echo "Restored: $path"
    else
      rm -f "$abs_path"
      echo "Removed newly-created file: $path"
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
