#!/usr/bin/env bash
# Unit tests for the stable-identity "new findings" diff in opengrep-report.sh.
#
# These pin the SEC-1975 fix: editing a line *inside* a pre-existing whole-block
# finding (e.g. missing-permissions over a job) must NOT re-report it as new,
# while a genuinely new finding still is. The diff is driven entirely by the
# scan JSON, so these tests craft baseline/head JSON directly — no opengrep or
# network needed — and assert the report script's new-count and exit code.
#
# Usage: bash sast/opengrep/tests/report-diff-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="${SCRIPT_DIR}/../scripts/opengrep-report.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RULE="test.rule.absence"   # the diff is rule-agnostic; any id exercises it

# finding <path> <line> <lines-text> — emit one result object (compact JSON).
finding() {
  jq -cn --arg id "$RULE" --arg p "$1" --argjson l "$2" --arg lines "$3" \
    '{check_id:$id, path:$p, start:{line:$l}, end:{line:$l},
      extra:{severity:"ERROR", message:"m", lines:$lines}}'
}

# results_doc <finding-json>... — wrap findings in a scan-results document.
results_doc() {
  printf '%s\n' "$@" | jq -cs '{results:., errors:[], paths:{scanned:["f"]}}'
}

PASS=0 FAIL=0

# expect <name> <expected-new-count> <expected-exit> <baseline-json> <head-json>
expect() {
  local name=$1 want_count=$2 want_exit=$3 baseline=$4 head=$5
  printf '%s' "$baseline" > "${WORK}/baseline.json"
  printf '%s' "$head"     > "${WORK}/head.json"

  local out; out="${WORK}/out.txt"; : > "$out"
  GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="${WORK}/summary.md" \
    bash "$REPORT" "${WORK}/baseline.json" "${WORK}/head.json" >/dev/null 2>&1
  local got_exit=$?
  local got_count; got_count=$(sed -n 's/^new-count=//p' "$out")
  got_count=${got_count:-MISSING}

  if [ "$got_count" = "$want_count" ] && [ "$got_exit" = "$want_exit" ]; then
    echo "  [PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name}: got new-count=${got_count} exit=${got_exit}, want new-count=${want_count} exit=${want_exit}"
    FAIL=$((FAIL + 1))
  fi
}

JOB_A=$'    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4'
JOB_A_PINNED=$'    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@de0fac2'
JOB_B=$'    runs-on: ubuntu-latest\n    steps:\n      - run: echo deploy'

echo "opengrep-report.sh new-findings diff"

# The SEC-1975 bug: a SHA pin edits a line inside the matched job block, so the
# match text (and opengrep's fingerprint) change while the gap is pre-existing.
expect "edit inside pre-existing block -> 0 new" 0 0 \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")" \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A_PINNED")")"

# A line shift alone (content identical, different start line) is not new.
expect "line-shifted pre-existing finding -> 0 new" 0 0 \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")" \
  "$(results_doc "$(finding wf.yml 9 "$JOB_A")")"

# A genuinely new gap (an added job with no permissions) is still reported.
expect "added job without permissions -> 1 new" 1 1 \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")" \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A_PINNED")" "$(finding wf.yml 9 "$JOB_B")")"

# Same rule+file, a second line-level finding added -> exactly one new.
expect "second finding same rule+file -> 1 new" 1 1 \
  "$(results_doc "$(finding run.yml 5 'echo a')")" \
  "$(results_doc "$(finding run.yml 5 'echo a')" "$(finding run.yml 50 'echo NEW')")"

# Same-key findings interleaved with another key in the results array must
# still group correctly (jq's group_by sorts internally; scan output order is
# not guaranteed). run.yml gains one finding; other.yml is unchanged.
expect "interleaved same-key findings -> 1 new" 1 1 \
  "$(results_doc "$(finding run.yml 5 'echo a')" "$(finding other.yml 1 'echo z')")" \
  "$(results_doc "$(finding run.yml 5 'echo a')" "$(finding other.yml 1 'echo z')" "$(finding run.yml 50 'echo NEW')")"

# Empty baseline (unavailable) -> every head finding is new (conservative).
expect "empty baseline -> all new" 2 1 \
  '{"results":[],"errors":[],"paths":{}}' \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")" "$(finding wf.yml 9 "$JOB_B")")"

# Identical scans -> nothing new.
expect "no change -> 0 new" 0 0 \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")" \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")"

# A fixed finding (present in baseline, gone in head) -> 0 new, passes.
expect "removed finding -> 0 new" 0 0 \
  "$(results_doc "$(finding wf.yml 4 "$JOB_A")")" \
  '{"results":[],"errors":[],"paths":{}}'

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
