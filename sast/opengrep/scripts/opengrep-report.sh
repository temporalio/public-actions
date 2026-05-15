#!/usr/bin/env bash
# opengrep-report.sh — Parse Opengrep JSON results, write a GitHub job summary
# with ::error:: annotations for new findings.
#
# Usage:
#   opengrep-report.sh <new-findings.json> <all-findings.json>
#
# Environment variables (set automatically by GitHub Actions):
#   GITHUB_STEP_SUMMARY — path to the job summary file (falls back to stdout)
#   GITHUB_OUTPUT       — path to expose step outputs
#
# Local testing:
#   opengrep scan --config rules/ --json --error . > /tmp/new.json 2>/dev/null; true
#   opengrep scan --config rules/ --json . > /tmp/all.json
#   ./opengrep-report.sh /tmp/new.json /tmp/all.json
#
# Expected Opengrep JSON format (same as Semgrep):
#   {
#     "results": [
#       {
#         "check_id": "rule.id",
#         "path": "file.yml",
#         "start": {"line": 9, "col": 1},
#         "end":   {"line": 9, "col": 40},
#         "extra": {
#           "severity": "WARNING",
#           "message": "Rule message text",
#           "fingerprint": "...",
#           "lines": "    matching source line"
#         }
#       }
#     ],
#     "errors": [],
#     "paths": { "scanned": ["file1.yml", "file2.go"] }
#   }
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Count findings in a JSON results file. Returns 0 for empty/missing/malformed.
count_findings() {
  local json_file=$1
  if [ ! -s "$json_file" ]; then
    echo 0
    return
  fi
  jq '.results | length' "$json_file" 2>/dev/null || echo 0
}

# Count scanned files. Returns 0 for empty/missing/malformed.
count_scanned() {
  local json_file=$1
  if [ ! -s "$json_file" ]; then
    echo 0
    return
  fi
  jq '.paths.scanned | length' "$json_file" 2>/dev/null || echo 0
}

# Emit ::error:: annotations for each finding (visible on PR diff).
emit_annotations() {
  local json_file=$1
  if [ ! -s "$json_file" ]; then
    return
  fi
  jq -r '
    .results[] |
    "::error file=\(.path),line=\(.start.line)::\(.check_id): \(.extra.message)"
  ' "$json_file" 2>/dev/null || true
}

# Emit a markdown table of findings. Escapes pipe characters in messages.
findings_table() {
  local json_file=$1
  jq -r '
    .results[] |
    "| `\(.check_id)` | `\(.path)` | \(.start.line) | \(.extra.severity) | \(.extra.message | gsub("\\|"; "\\|")) |"
  ' "$json_file"
}

# ---------------------------------------------------------------------------
# Render: write the GitHub job summary
# ---------------------------------------------------------------------------

write_summary() {
  local new_json=$1
  local all_json=$2
  local new_count=$3
  local all_count=$4
  local scanned_count=$5
  local summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

  {
    echo "## SAST Scan"
    echo ""

    if [ "$scanned_count" -eq 0 ]; then
      echo "No files matched configured rules."
      return
    fi

    if [ "$new_count" -gt 0 ]; then
      echo "### :warning: New findings ($new_count)"
      echo ""
      echo "| Rule | File | Line | Severity | Message |"
      echo "|------|------|------|----------|---------|"
      findings_table "$new_json" 2>/dev/null || true
      echo ""
    else
      echo "### :white_check_mark: No new findings"
      echo ""
      echo "This change does not introduce any new SAST findings."
      echo ""
    fi

    if [ "$all_count" -gt 0 ]; then
      echo "### Total findings ($all_count)"
      echo ""
      echo "<details><summary>Click to expand</summary>"
      echo ""
      echo "| Rule | Count |"
      echo "|------|-------|"
      jq -r '
        [.results[] | .check_id] |
        group_by(.) |
        map({rule: .[0], count: length}) |
        sort_by(-.count) |
        .[] |
        "| `\(.rule)` | \(.count) |"
      ' "$all_json" 2>/dev/null || true
      echo ""
      echo "</details>"
    fi
  } >> "$summary_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local new_json="${1:?Usage: opengrep-report.sh <new-findings.json> <all-findings.json>}"
  local all_json="${2:?Usage: opengrep-report.sh <new-findings.json> <all-findings.json>}"

  if ! command -v jq &>/dev/null; then
    echo "::error::jq is required but not installed — use a GitHub-hosted runner or install jq"
    exit 1
  fi

  local new_count all_count scanned_count
  new_count=$(count_findings "$new_json")
  all_count=$(count_findings "$all_json")
  scanned_count=$(count_scanned "$all_json")

  # Emit ::error:: annotations for new findings (visible on PR diff).
  if [ "$new_count" -gt 0 ]; then
    emit_annotations "$new_json"
  fi

  # Write GitHub job summary.
  write_summary "$new_json" "$all_json" "$new_count" "$all_count" "$scanned_count"

  # Expose outputs for downstream workflow steps.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "new-count=${new_count}" >> "$GITHUB_OUTPUT"
    echo "has-new-findings=$([ "$new_count" -gt 0 ] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  fi

  # Fail the check when new findings are introduced.
  if [ "$new_count" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
