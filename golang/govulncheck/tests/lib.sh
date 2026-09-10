#!/usr/bin/env bash
# Shared fixtures and assertions for govulncheck-report.sh tests.
#
# Everything here is driven by crafted scan JSON, so the tests need no
# govulncheck install, Go toolchain, or network. Source this from a test file:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Sourcing sets up SCRIPT_DIR, REPORT, WORK (a temp dir removed on exit), and
# the PASS/FAIL counters that finish_tests reports on.

# >/dev/null: with CDPATH set, cd echoes the resolved directory and would
# otherwise end up concatenated into SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
REPORT="${SCRIPT_DIR}/../scripts/govulncheck-report.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0 FAIL=0

# ---------------------------------------------------------------------------
# Fixtures: build govulncheck's v1 JSON stream (concatenated objects, not NDJSON)
# ---------------------------------------------------------------------------

# osv <id> <summary> — vulnerability metadata object.
osv() {
  jq -n --arg id "$1" --arg summary "$2" '{osv: {id: $id, summary: $summary}}'
}

# finding <id> <level> — one finding object at module, package, or symbol level.
#
# The level is encoded by how much of trace[0] is populated, mirroring
# golang.org/x/vuln/internal/govulncheck: module+version only for module level,
# plus package for package level, plus function (and a caller frame) for symbol
# level. Frames run from the vulnerable symbol outward to the entry point.
finding() {
  local id=$1 level=$2
  case "$level" in
    module)
      jq -n --arg id "$id" '{finding: {osv: $id, fixed_version: "", trace: [
        {module: "example.com/dep", version: "v1.0.0"}]}}' ;;
    package)
      jq -n --arg id "$id" '{finding: {osv: $id, fixed_version: "", trace: [
        {module: "example.com/dep", version: "v1.0.0", package: "example.com/dep/vuln"}]}}' ;;
    symbol)
      jq -n --arg id "$id" '{finding: {osv: $id, fixed_version: "", trace: [
        {module: "example.com/dep", version: "v1.0.0", package: "example.com/dep/vuln", function: "Vulnerable"},
        {module: "example.com/app", version: "", package: "example.com/app", function: "main"}]}}' ;;
    *)
      echo "lib.sh: unknown finding level '${level}'" >&2; return 1 ;;
  esac
}

# scan <id>[:<level>]... — a full scan document. Level defaults to module.
#
# Emits the cascade govulncheck actually produces: a symbol-level vulnerability
# also yields module- and package-level findings for the same ID. That is what
# makes "reduce each ID to its highest level" the correct reading, so the
# fixtures have to reproduce it.
scan() {
  jq -n '{config: {protocol_version: "v1.0.0"}}'
  local spec id level
  for spec in "$@"; do
    id=${spec%%:*}
    level=${spec#*:}
    [ "$level" = "$id" ] && level=module
    osv "$id" "summary for ${id}"
    finding "$id" module
    case "$level" in
      package) finding "$id" package ;;
      symbol)  finding "$id" package; finding "$id" symbol ;;
    esac
  done
}

EMPTY_SCAN="$(jq -n '{config: {protocol_version: "v1.0.0"}}')"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

# run_report <pr-json> <base-json> <ignore-file-or-empty> [fail-on]
# Populates RUN_EXIT, RUN_NEW, RUN_IGNORED, RUN_BELOW, RUN_SUMMARY, RUN_LOG.
run_report() {
  printf '%s\n' "$1" > "${WORK}/pr.json"
  printf '%s\n' "$2" > "${WORK}/base.json"

  RUN_SUMMARY="${WORK}/summary.md"
  RUN_LOG="${WORK}/log.txt"
  local outputs="${WORK}/outputs.txt"
  : > "$RUN_SUMMARY"
  : > "$outputs"

  GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$RUN_SUMMARY" \
    bash "$REPORT" "${WORK}/pr.json" "${WORK}/base.json" "$3" "${4:-module}" > "$RUN_LOG" 2>&1
  RUN_EXIT=$?

  RUN_NEW=$(sed -n 's/^new-count=//p' "$outputs");              RUN_NEW=${RUN_NEW:-MISSING}
  RUN_IGNORED=$(sed -n 's/^ignored-count=//p' "$outputs");      RUN_IGNORED=${RUN_IGNORED:-MISSING}
  RUN_BELOW=$(sed -n 's/^below-threshold-count=//p' "$outputs"); RUN_BELOW=${RUN_BELOW:-MISSING}
}

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# expect <name> <want-new> <want-ignored> <want-exit>  (call after run_report)
expect() {
  local name=$1 want_new=$2 want_ignored=$3 want_exit=$4
  if [ "$RUN_NEW" = "$want_new" ] && [ "$RUN_IGNORED" = "$want_ignored" ] && [ "$RUN_EXIT" = "$want_exit" ]; then
    ok "$name"
  else
    bad "$name" "got new=${RUN_NEW} ignored=${RUN_IGNORED} exit=${RUN_EXIT}, want new=${want_new} ignored=${want_ignored} exit=${want_exit}"
  fi
}

# expect_below <name> <want-below-threshold-count>
expect_below() {
  if [ "$RUN_BELOW" = "$2" ]; then ok "$1"; else bad "$1" "got below=${RUN_BELOW}, want ${2}"; fi
}

# expect_exit <name> <want-exit>
expect_exit() {
  if [ "$RUN_EXIT" = "$2" ]; then ok "$1"; else bad "$1" "got exit=${RUN_EXIT}, want ${2}"; fi
}

# expect_in <name> <file> <fixed-string>
expect_in() {
  if grep -qF "$3" "$2"; then ok "$1"; else bad "$1" "missing \"$3\" in $(basename "$2")"; fi
}

# expect_not_in <name> <file> <fixed-string>
expect_not_in() {
  if grep -qF "$3" "$2"; then bad "$1" "unexpected \"$3\" in $(basename "$2")"; else ok "$1"; fi
}

# write_ignore <content> — write the ignore file, return its path on stdout.
write_ignore() {
  printf '%s' "$1" > "${WORK}/.govulncheck-ignore"
  echo "${WORK}/.govulncheck-ignore"
}

# finish_tests — print the tally and set the exit status.
finish_tests() {
  echo ""
  echo "${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}
