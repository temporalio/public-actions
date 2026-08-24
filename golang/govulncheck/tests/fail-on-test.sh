#!/usr/bin/env bash
# Unit tests for the fail-on (reachability) threshold in govulncheck-report.sh.
#
# govulncheck reports a vulnerability at module, package, or symbol level. Only
# symbol level means "your code calls this". These tests pin which levels block
# at each threshold, that below-threshold findings are still reported, and how
# the threshold interacts with the ignore list.
#
# Usage: bash golang/govulncheck/tests/fail-on-test.sh
set -uo pipefail

# >/dev/null: with CDPATH set, cd echoes the resolved directory.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)/lib.sh"

echo "govulncheck-report.sh fail-on threshold"

MODULE_ONLY="$(scan GO-2026-5932)"                # in go.mod, package not imported
IMPORTED="$(scan GO-2026-5932:package)"           # package imported, symbol not called
CALLED="$(scan GO-2026-5932:symbol)"              # code calls the vulnerable symbol

# ---------------------------------------------------------------------------
# Default: module. Preserves the pre-existing behaviour of failing on anything.
# ---------------------------------------------------------------------------

run_report "$MODULE_ONLY" "$EMPTY_SCAN" "" "module"
expect "module threshold: module-level vuln fails" 1 0 1
expect_below "module threshold: nothing below it" 0

run_report "$CALLED" "$EMPTY_SCAN" "" "module"
expect "module threshold: called vuln fails" 1 0 1

# Omitting fail-on entirely must behave exactly like 'module'.
printf '%s\n' "$MODULE_ONLY" > "${WORK}/pr.json"
printf '%s\n' "$EMPTY_SCAN"  > "${WORK}/base.json"
GITHUB_OUTPUT="${WORK}/o.txt" GITHUB_STEP_SUMMARY="${WORK}/s.md" \
  bash "$REPORT" "${WORK}/pr.json" "${WORK}/base.json" >/dev/null 2>&1
expect_exit "omitted fail-on defaults to module" 1

# ---------------------------------------------------------------------------
# symbol: the motivating case. GO-2026-5932 is module-level only, so it stops
# blocking, but a genuinely called vulnerability still does.
# ---------------------------------------------------------------------------

run_report "$MODULE_ONLY" "$EMPTY_SCAN" "" "symbol"
expect "symbol threshold: module-level vuln passes" 0 0 0
expect_below "symbol threshold: module-level vuln reported below" 1
expect_in "below-threshold section rendered" "$RUN_SUMMARY" "Below the \`symbol\` threshold (1)"
expect_in "below-threshold vuln still named" "$RUN_SUMMARY" "GO-2026-5932"
expect_in "below-threshold wording explains why" "$RUN_SUMMARY" "does not call the vulnerable symbols"

run_report "$IMPORTED" "$EMPTY_SCAN" "" "symbol"
expect "symbol threshold: imported-but-uncalled passes" 0 0 0
expect_below "symbol threshold: imported vuln reported below" 1

run_report "$CALLED" "$EMPTY_SCAN" "" "symbol"
expect "symbol threshold: called vuln still fails" 1 0 1
expect_below "symbol threshold: called vuln not below" 0

# ---------------------------------------------------------------------------
# package: the middle setting.
# ---------------------------------------------------------------------------

run_report "$MODULE_ONLY" "$EMPTY_SCAN" "" "package"
expect "package threshold: module-level vuln passes" 0 0 0
expect_below "package threshold: module-level vuln reported below" 1

run_report "$IMPORTED" "$EMPTY_SCAN" "" "package"
expect "package threshold: imported vuln fails" 1 0 1

run_report "$CALLED" "$EMPTY_SCAN" "" "package"
expect "package threshold: called vuln fails" 1 0 1

# ---------------------------------------------------------------------------
# Level reduction: govulncheck emits module- and package-level findings
# alongside the symbol-level one for the same ID. The highest level must win,
# otherwise a called vulnerability would look unreachable and slip through.
# ---------------------------------------------------------------------------

MIXED="$(scan GO-2026-5932:symbol GO-2025-1234)"
run_report "$MIXED" "$EMPTY_SCAN" "" "symbol"
expect "mixed scan: only the called vuln fails" 1 0 1
expect_below "mixed scan: the unreachable one is reported below" 1

# ---------------------------------------------------------------------------
# Interaction with the ignore list
# ---------------------------------------------------------------------------

IGNORE="$(write_ignore 'GO-2026-5932  # accepted risk
')"

# An ignored, called vulnerability is suppressed at any threshold.
run_report "$CALLED" "$EMPTY_SCAN" "$IGNORE" "symbol"
expect "ignore beats threshold for a called vuln" 0 1 0

# An ignore entry covering a below-threshold finding is reported as ignored,
# not listed twice, and must not be flagged stale just because the threshold
# already excused it.
run_report "$MODULE_ONLY" "$EMPTY_SCAN" "$IGNORE" "symbol"
expect "ignored below-threshold vuln -> ignored bucket" 0 1 0
expect_below "ignored vuln removed from below-threshold list" 0
expect_not_in "not flagged as a stale ignore entry" "$RUN_LOG" "not present in this scan"

# A vulnerability that is only pre-existing must not resurface as new when the
# threshold changes what is counted on each side.
run_report "$CALLED" "$CALLED" "" "symbol"
expect "called vuln on both branches -> pre-existing" 0 0 0

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

run_report "$CALLED" "$EMPTY_SCAN" "" "reachable"
expect_exit "unknown fail-on level -> hard error" 1
expect_in "unknown level names the valid options" "$RUN_LOG" "expected one of: module, package, symbol"

# An empty value (someone wiring `fail-on: ''` through a workflow variable)
# falls back to the default rather than erroring.
run_report "$MODULE_ONLY" "$EMPTY_SCAN" "" ""
expect "empty fail-on falls back to module" 1 0 1

finish_tests
