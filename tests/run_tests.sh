#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWITCH_SCRIPT="${ADAPTER_DIR}/switch_to_ark.sh"
SMOKE_SCRIPT="${ADAPTER_DIR}/smoke_test_ark_responses.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/volcano-codex-adapter-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

ARK_MODEL="ep-test"
ARK_API_KEY="test-key"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -q "$pattern" "$file"; then
    pass "$message"
  else
    printf 'Expected pattern not found: %s\nFile: %s\n' "$pattern" "$file" >&2
    exit 1
  fi
}

assert_file_missing() {
  local file="$1"
  local message="$2"
  if [[ ! -e "$file" ]]; then
    pass "$message"
  else
    printf 'Expected file to be absent: %s\n' "$file" >&2
    exit 1
  fi
}

run_switch() {
  local project_dir="$1"
  shift
  PROJECT_DIR="$project_dir" \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    "$SWITCH_SCRIPT" "$@"
}

run_switch_home_scope() {
  local project_dir="$1"
  local codex_home="$2"
  shift 2
  PROJECT_DIR="$project_dir" \
    CODEX_HOME="$codex_home" \
    SCOPE=home \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    "$SWITCH_SCRIPT" "$@"
}

make_codex_fixture() {
  local dir="$1"
  mkdir -p "$dir/codex-rs" "$dir/codex-cli"
  printf '[workspace]\nmembers = []\n' > "$dir/codex-rs/Cargo.toml"
  printf '{"name":"codex-cli-fixture","version":"0.0.0"}\n' > "$dir/codex-cli/package.json"
}

test_syntax() {
  bash -n "$SWITCH_SCRIPT"
  bash -n "$SMOKE_SCRIPT"
  pass "scripts pass bash syntax check"
}

test_codex_new_config_rollback() {
  local dir="$TEST_ROOT/codex-new"
  make_codex_fixture "$dir"

  run_switch "$dir" apply >/dev/null
  assert_file_contains "$dir/.codex/config.toml" 'model_provider = "volcengine-ark"' "codex apply writes provider"
  assert_file_contains "$dir/.codex/config.toml" 'User-Agent' "codex apply writes user-agent header"

  run_switch "$dir" rollback >/dev/null
  assert_file_missing "$dir/.codex/config.toml" "codex rollback removes newly-created config"
}

test_codex_existing_config_rollback() {
  local dir="$TEST_ROOT/codex-existing"
  make_codex_fixture "$dir"
  mkdir -p "$dir/.codex"
  printf 'model = "gpt-5.1"\nmodel_provider = "openai"\n' > "$dir/.codex/config.toml"

  run_switch "$dir" apply >/dev/null
  run_switch "$dir" rollback >/dev/null

  if cmp -s "$dir/.codex/config.toml" <(printf 'model = "gpt-5.1"\nmodel_provider = "openai"\n'); then
    pass "codex rollback restores existing config"
  else
    printf 'Existing Codex config was not restored.\n' >&2
    exit 1
  fi
}

test_codex_home_scope_rollback() {
  local dir="$TEST_ROOT/codex-home-scope"
  local codex_home="$TEST_ROOT/codex-home"
  make_codex_fixture "$dir"
  mkdir -p "$codex_home"
  printf 'model = "gpt-5.1"\nmodel_provider = "openai"\n' > "$codex_home/config.toml"

  run_switch_home_scope "$dir" "$codex_home" apply >/dev/null
  assert_file_contains "$codex_home/config.toml" 'model_provider = "volcengine-ark"' "codex home-scope apply writes provider"
  assert_file_contains "$codex_home/config.toml" 'User-Agent' "codex home-scope apply writes user-agent header"

  run_switch_home_scope "$dir" "$codex_home" rollback >/dev/null
  if cmp -s "$codex_home/config.toml" <(printf 'model = "gpt-5.1"\nmodel_provider = "openai"\n'); then
    pass "codex home-scope rollback restores existing config"
  else
    printf 'Existing CODEX_HOME config was not restored.\n' >&2
    exit 1
  fi
}

test_home_scope_unknown_project_writes_codex_home() {
  local dir="$TEST_ROOT/home-scope-unknown"
  local codex_home="$TEST_ROOT/home-scope-unknown-codex-home"
  mkdir -p "$dir" "$codex_home"

  run_switch_home_scope "$dir" "$codex_home" apply >/dev/null
  assert_file_contains "$codex_home/config.toml" 'model_provider = "volcengine-ark"' "home-scope unknown project writes Codex home provider"

  run_switch_home_scope "$dir" "$codex_home" rollback >/dev/null
  assert_file_missing "$codex_home/config.toml" "home-scope unknown project rollback removes new Codex home config"
}

test_observer_mode_writes_local_base_url() {
  local dir="$TEST_ROOT/observer-mode"
  local codex_home="$TEST_ROOT/observer-mode-codex-home"
  mkdir -p "$dir" "$codex_home"

  PROJECT_DIR="$dir" \
    CODEX_HOME="$codex_home" \
    SCOPE=home \
    OBSERVER=1 \
    OBSERVER_BASE_URL="http://127.0.0.1:17860/api/v3" \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    "$SWITCH_SCRIPT" apply >/dev/null

  assert_file_contains "$codex_home/config.toml" 'base_url = "http://127.0.0.1:17860/api/v3"' "observer mode writes local proxy base URL"

  PROJECT_DIR="$dir" \
    CODEX_HOME="$codex_home" \
    SCOPE=home \
    OBSERVER=1 \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    "$SWITCH_SCRIPT" rollback >/dev/null
}

test_node_env_rollback() {
  local dir="$TEST_ROOT/node"
  mkdir -p "$dir"
  printf '{"dependencies":{"openai":"latest"}}\n' > "$dir/package.json"

  run_switch "$dir" apply >/dev/null
  assert_file_contains "$dir/.env" 'OPENAI_BASE_URL=https://ark.cn-beijing.volces.com/api/v3' "node apply writes OpenAI-compatible base URL"

  run_switch "$dir" rollback >/dev/null
  assert_file_missing "$dir/.env" "node rollback removes newly-created env"
}

test_python_env_rollback() {
  local dir="$TEST_ROOT/python"
  mkdir -p "$dir"
  printf 'openai>=1.0.0\n' > "$dir/requirements.txt"

  run_switch "$dir" apply >/dev/null
  assert_file_contains "$dir/.env" 'OPENAI_MODEL=ep-test' "python apply writes model"

  run_switch "$dir" rollback >/dev/null
  assert_file_missing "$dir/.env" "python rollback removes newly-created env"
}

test_dry_run_no_write() {
  local dir="$TEST_ROOT/dry-run"
  mkdir -p "$dir"
  printf '{"dependencies":{"openai":"latest"}}\n' > "$dir/package.json"

  run_switch "$dir" apply --dry-run >/dev/null
  assert_file_missing "$dir/.env" "dry-run does not create env"
}

test_status() {
  local dir="$TEST_ROOT/status"
  make_codex_fixture "$dir"

  local output
  output="$(run_switch "$dir" status)"
  if printf '%s\n' "$output" | grep -q 'Detected project type: codex'; then
    pass "status detects codex project"
  else
    printf 'Unexpected status output:\n%s\n' "$output" >&2
    exit 1
  fi
}

test_syntax
test_codex_new_config_rollback
test_codex_existing_config_rollback
test_codex_home_scope_rollback
test_home_scope_unknown_project_writes_codex_home
test_observer_mode_writes_local_base_url
test_node_env_rollback
test_python_env_rollback
test_dry_run_no_write
test_status

printf '\nAll volcano-codex-adapter tests passed.\n'
