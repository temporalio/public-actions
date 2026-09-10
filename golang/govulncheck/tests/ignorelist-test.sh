#!/usr/bin/env bash
# Unit tests for the ignore-list handling in govulncheck-report.sh.
#
# These cover the parser (comments, reasons, malformed input) and the effect an
# ignore entry has on the new/pre-existing/ignored buckets and the exit code.
# Everything is driven by the scan JSON, so the tests craft that JSON directly —
# no govulncheck install, Go toolchain, or network needed.
#
# Usage: bash golang/govulncheck/tests/ignorelist-test.sh
set -uo pipefail

# >/dev/null: with CDPATH set, cd echoes the resolved directory.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)/lib.sh"

echo "govulncheck-report.sh ignore list"

# ---------------------------------------------------------------------------
# Baseline: no ignore file
# ---------------------------------------------------------------------------

ONE_VULN="$(scan GO-2026-5932)"
TWO_VULNS="$(scan GO-2026-5932 GO-2025-1234)"

run_report "$ONE_VULN" "$EMPTY_SCAN" ""
expect "no ignore file -> vuln still fails" 1 0 1

# ---------------------------------------------------------------------------
# Suppression
# ---------------------------------------------------------------------------

IGNORE="$(write_ignore 'GO-2026-5932
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "ignored new vuln -> passes" 0 1 0
expect_in "ignored vuln appears in summary" "$RUN_SUMMARY" "Ignored vulnerabilities (1)"
expect_not_in "ignored vuln absent from new section" "$RUN_SUMMARY" "New vulnerabilities"

run_report "$TWO_VULNS" "$EMPTY_SCAN" "$IGNORE"
expect "partial ignore -> remaining vuln still fails" 1 1 1

# A pre-existing (present on both branches) vuln moves to the ignored bucket.
run_report "$ONE_VULN" "$ONE_VULN" "$IGNORE"
expect "ignored pre-existing vuln -> ignored bucket" 0 1 0
expect_not_in "not double-reported as pre-existing" "$RUN_SUMMARY" "Pre-existing vulnerabilities"

# ---------------------------------------------------------------------------
# Comments and reasons
# ---------------------------------------------------------------------------

IGNORE="$(write_ignore '# This whole file is comments.

# So is this paragraph.
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "comment-only file -> no suppression" 1 0 1

IGNORE="$(write_ignore 'GO-2026-5932  # waiting on upstream fix
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "trailing-comment entry parses" 0 1 0
expect_in "trailing comment used as reason" "$RUN_SUMMARY" "waiting on upstream fix"

IGNORE="$(write_ignore '# x/crypto/openpgp is unmaintained.
# Nothing in our build imports it.
GO-2026-5932
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "preceding comment block parses" 0 1 0
expect_in "comment block joined into reason" "$RUN_SUMMARY" "x/crypto/openpgp is unmaintained. Nothing in our build imports it."

# A blank line detaches a comment paragraph from the entry below it, so an
# unrelated header comment is not misattributed as a justification.
IGNORE="$(write_ignore '# Header for the file, not a reason.

GO-2026-5932
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "blank line detaches comment block" 0 1 0
expect_in "undocumented entry marked as such" "$RUN_SUMMARY" "(no reason given)"
expect_not_in "detached comment not used as reason" "$RUN_SUMMARY" "Header for the file"

# Trailing comment wins over the block above it.
IGNORE="$(write_ignore '# block reason
GO-2026-5932 # inline reason
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect_in "inline reason overrides block reason" "$RUN_SUMMARY" "inline reason"
expect_not_in "block reason dropped when inline present" "$RUN_SUMMARY" "block reason"

# A pipe in a reason must not break the markdown table.
IGNORE="$(write_ignore 'GO-2026-5932 # accepted | see SEC-1234
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "reason containing a pipe" 0 1 0
expect_in "pipe escaped in table cell" "$RUN_SUMMARY" 'accepted \| see SEC-1234'

# CRLF line endings (file authored on Windows) must still parse.
printf 'GO-2026-5932  # windows\r\n' > "${WORK}/.govulncheck-ignore"
run_report "$ONE_VULN" "$EMPTY_SCAN" "${WORK}/.govulncheck-ignore"
expect "CRLF ignore file parses" 0 1 0

# ---------------------------------------------------------------------------
# Error and hygiene cases
# ---------------------------------------------------------------------------

IGNORE="$(write_ignore 'GO-2026-5932
CVE-2026-1111
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect_exit "malformed entry -> hard error" 1
expect_in "malformed entry annotated with line number" "$RUN_LOG" "line=2::malformed ignore entry"

run_report "$ONE_VULN" "$EMPTY_SCAN" "${WORK}/does-not-exist"
expect_exit "missing explicit ignore file -> error" 1
expect_in "missing file reported" "$RUN_LOG" "not found"

# A suppression that no longer matches anything should be surfaced, not silently
# carried forever — but it must not fail the build on its own.
IGNORE="$(write_ignore 'GO-2020-0001  # long since resolved
')"
run_report "$ONE_VULN" "$ONE_VULN" "$IGNORE"
expect "stale entry does not suppress or fail" 0 0 0
expect_in "stale entry warned about" "$RUN_LOG" "not present in this scan"

IGNORE="$(write_ignore 'GO-2026-5932 # first
GO-2026-5932 # second
')"
run_report "$ONE_VULN" "$EMPTY_SCAN" "$IGNORE"
expect "duplicate entries counted once" 0 1 0
expect_in "duplicate entries warned about" "$RUN_LOG" "duplicate entries in"
expect_in "first duplicate's reason wins" "$RUN_SUMMARY" "first"

finish_tests
