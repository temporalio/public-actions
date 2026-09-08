#!/usr/bin/env bash
# Black-box regression tests for the reusable .mise/tasks/opengrep.toml task.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
task_file="${repo_root}/.mise/tasks/opengrep.toml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export MISE_STATE_DIR="${work}/mise-state"
export SEMGREP_LOG_FILE="${work}/opengrep.log"

pass=0
fail=0

check() {
  local name=$1
  shift
  if "$@"; then
    printf '  [PASS] %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  [FAIL] %s\n' "$name"
    fail=$((fail + 1))
  fi
}

new_client() {
  local client=$1
  mkdir -p "${client}/.github/workflows" "${client}/nested/directory"
  printf '[task_config]\nincludes = ["%s"]\n' "$task_file" > "${client}/mise.toml"
}

task_is_listed() {
  local client=$1
  MISE_TRUSTED_CONFIG_PATHS="$client" mise -C "$client" tasks ls --no-header \
    | awk '$1 == "opengrep" { found=1 } END { exit !found }'
}

run_task() {
  local client=$1
  shift
  MISE_TRUSTED_CONFIG_PATHS="$client" mise -C "$client" run opengrep "$@"
}

echo "OpenGrep Mise task tests"

check "repository discovers and validates task" \
  mise -C "$repo_root" tasks validate opengrep
check "documented include uses the remote Git task format" \
  grep -Fq 'git::https://github.com/temporalio/public-actions.git//.mise/tasks/opengrep.toml?ref=main' \
  "${repo_root}/sast/opengrep/README.md"

safe_client="${work}/safe-client"
new_client "$safe_client"
cat > "${safe_client}/.github/workflows/safe.yml" <<'EOF'
name: safe
on: push
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo safe
EOF

check "client include exposes task" task_is_listed "$safe_client"
check "safe client succeeds" run_task "$safe_client"

vulnerable_client="${work}/vulnerable-client"
new_client "$vulnerable_client"
cat > "${vulnerable_client}/.github/workflows/vulnerable.yml" <<'EOF'
name: vulnerable
on: pull_request
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ${{ github.event.pull_request.title }}
EOF

vulnerable_output="${work}/vulnerable.out"
if run_task "$vulnerable_client" >"$vulnerable_output" 2>&1; then
  printf '  [FAIL] vulnerable client fails\n'
  fail=$((fail + 1))
elif grep -q 'security.gha.run-shell-injection' "$vulnerable_output"; then
  printf '  [PASS] vulnerable client fails with built-in rule\n'
  pass=$((pass + 1))
else
  printf '  [FAIL] vulnerable client did not report expected rule\n'
  sed -n '1,160p' "$vulnerable_output"
  fail=$((fail + 1))
fi

nested_output="${work}/nested.out"
if MISE_TRUSTED_CONFIG_PATHS="$vulnerable_client" \
    mise -C "${vulnerable_client}/nested/directory" run opengrep \
    >"$nested_output" 2>&1; then
  printf '  [FAIL] nested invocation scans client root\n'
  fail=$((fail + 1))
elif grep -q 'security.gha.run-shell-injection' "$nested_output"; then
  printf '  [PASS] nested invocation scans client root\n'
  pass=$((pass + 1))
else
  printf '  [FAIL] nested invocation did not report root workflow\n'
  sed -n '1,160p' "$nested_output"
  fail=$((fail + 1))
fi

additional_client="${work}/additional-client"
new_client "$additional_client"
mkdir -p "${additional_client}/.opengrep/rules"
cat > "${additional_client}/.github/workflows/additional.yml" <<'EOF'
name: additional
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo LOCAL_RULE_MARKER
EOF
cat > "${additional_client}/.opengrep/rules/local.yml" <<'EOF'
rules:
  - id: test.additional-config
    languages: [yaml]
    severity: ERROR
    message: Repository-local rule loaded
    pattern: LOCAL_RULE_MARKER
EOF

additional_output="${work}/additional.out"
if run_task "$additional_client" --config .opengrep/rules \
    >"$additional_output" 2>&1; then
  printf '  [FAIL] additional config produces findings\n'
  fail=$((fail + 1))
elif grep -q 'test.additional-config' "$additional_output" && \
    grep -q 'security.gha.missing-explicit-permissions' "$additional_output"; then
  printf '  [PASS] additional config keeps built-in rules enabled\n'
  pass=$((pass + 1))
else
  printf '  [FAIL] additional config did not load both rule sets\n'
  sed -n '1,160p' "$additional_output"
  fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0
