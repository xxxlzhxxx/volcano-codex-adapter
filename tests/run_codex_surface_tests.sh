#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWITCH_SCRIPT="${ADAPTER_DIR}/switch_to_ark.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/volcano-codex-surface-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

ARK_MODEL="${ARK_MODEL:-ep-test}"
ARK_API_KEY="${ARK_API_KEY:-test-key}"

pass() {
  printf 'ok - %s\n' "$1"
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

run_switch() {
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

run_switch_project_scope() {
  local project_dir="$1"
  shift
  PROJECT_DIR="$project_dir" \
    ARK_MODEL="$ARK_MODEL" \
    ARK_API_KEY="$ARK_API_KEY" \
    "$SWITCH_SCRIPT" "$@"
}

make_codex_fixture() {
  local dir="$1"
  mkdir -p "$dir/codex-rs" "$dir/codex-cli" "$dir/sdk/typescript" "$dir/sdk/python"
  printf '[workspace]\nmembers = []\n' > "$dir/codex-rs/Cargo.toml"
  printf '{"name":"codex-cli-fixture","version":"0.0.0"}\n' > "$dir/codex-cli/package.json"
  printf '{"name":"@openai/codex-sdk","version":"0.0.0"}\n' > "$dir/sdk/typescript/package.json"
  printf '[project]\nname = "openai-codex"\n' > "$dir/sdk/python/pyproject.toml"
}

render_codex_exec_command() {
  local project_dir="$1"
  printf 'cd %q && ARK_API_KEY=*** codex exec --skip-git-repo-check %q\n' \
    "$project_dir" "只回复 OK"
}

render_app_server_command() {
  local project_dir="$1"
  printf 'cd %q && ARK_API_KEY=*** codex app-server --listen stdio://\n' "$project_dir"
}

render_ts_sdk_config_probe() {
  local project_dir="$1"
  cat <<EOF
// TypeScript SDK wraps: codex exec --experimental-json.
// Run from project root so project-local .codex/config.toml is visible.
process.chdir("$project_dir");
process.env.ARK_API_KEY = "***";
// Expected effective config: CODEX_HOME/config.toml contains the Ark provider.
EOF
}

render_python_sdk_config_probe() {
  local project_dir="$1"
  cat <<EOF
# Python SDK starts: codex app-server --listen stdio://.
# Run with cwd set to project root so project-local .codex/config.toml is visible.
cwd = "$project_dir"
env = {"ARK_API_KEY": "***"}
# Expected effective config: CODEX_HOME/config.toml contains the Ark provider.
EOF
}

test_codex_cli_surface() {
  local dir="$TEST_ROOT/codex-cli"
  local codex_home="$TEST_ROOT/codex-cli-home"
  make_codex_fixture "$dir"
  mkdir -p "$codex_home"

  run_switch "$dir" "$codex_home" apply >/dev/null

  assert_file_contains "$codex_home/config.toml" 'model = "ep-test"' "cli surface config writes Ark model"
  assert_file_contains "$codex_home/config.toml" 'model_provider = "volcengine-ark"' "cli surface config writes Ark provider"
  assert_file_contains "$codex_home/config.toml" 'wire_api = "responses"' "cli surface config uses Responses API"
  assert_file_contains "$codex_home/config.toml" 'env_key = "ARK_API_KEY"' "cli surface config reads Ark key from env"
  assert_file_contains "$codex_home/config.toml" 'User-Agent' "cli surface config injects User-Agent header"

  render_codex_exec_command "$dir" > "$dir/codex_exec_command.txt"
  assert_file_contains "$dir/codex_exec_command.txt" 'codex exec' "cli surface renders codex exec command"
}

test_app_server_surface() {
  local dir="$TEST_ROOT/app-server"
  local codex_home="$TEST_ROOT/app-server-home"
  make_codex_fixture "$dir"
  mkdir -p "$codex_home"

  run_switch "$dir" "$codex_home" apply >/dev/null

  render_app_server_command "$dir" > "$dir/app_server_command.txt"
  assert_file_contains "$dir/app_server_command.txt" 'codex app-server --listen stdio://' "app-server surface renders stdio command"
  assert_file_contains "$codex_home/config.toml" 'http_headers = { "User-Agent"' "app-server surface shares provider headers"
}

test_typescript_sdk_surface() {
  local dir="$TEST_ROOT/ts-sdk"
  local codex_home="$TEST_ROOT/ts-sdk-home"
  make_codex_fixture "$dir"
  mkdir -p "$codex_home"

  run_switch "$dir" "$codex_home" apply >/dev/null

  render_ts_sdk_config_probe "$dir" > "$dir/ts_sdk_probe.txt"
  assert_file_contains "$dir/ts_sdk_probe.txt" 'codex exec --experimental-json' "typescript sdk surface documents exec wrapper"
  assert_file_contains "$codex_home/config.toml" '\[profiles.ark\]' "typescript sdk surface has ark profile"
}

test_python_sdk_surface() {
  local dir="$TEST_ROOT/python-sdk"
  local codex_home="$TEST_ROOT/python-sdk-home"
  make_codex_fixture "$dir"
  mkdir -p "$codex_home"

  run_switch "$dir" "$codex_home" apply >/dev/null

  render_python_sdk_config_probe "$dir" > "$dir/python_sdk_probe.txt"
  assert_file_contains "$dir/python_sdk_probe.txt" 'codex app-server --listen stdio://' "python sdk surface documents app-server wrapper"
  assert_file_contains "$codex_home/config.toml" '\[profiles.ark\]' "python sdk surface has ark profile"
}

test_codex_cli_surface
test_app_server_surface
test_typescript_sdk_surface
test_python_sdk_surface

printf '\nAll Codex surface tests passed.\n'
