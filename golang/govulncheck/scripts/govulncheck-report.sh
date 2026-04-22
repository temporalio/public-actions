#!/usr/bin/env bash
# govulncheck-report.sh — Compare govulncheck results between PR and base branch,
# then write a GitHub job summary with the findings.
#
# Usage:
#   govulncheck-report.sh <pr-vulns.json> <base-vulns.json>
#
# Environment variables (set automatically by GitHub Actions):
#   GITHUB_STEP_SUMMARY — path to the job summary file (falls back to stdout)
#
# Local testing:
#   # Generate sample data:
#   go run golang.org/x/vuln/cmd/govulncheck@v1.1.4 -json ./... > /tmp/pr-vulns.json 2>/dev/null || true
#   # Compare two scans:
#   ./govulncheck-report.sh /tmp/pr-vulns.json /tmp/base-vulns.json
#
# Expected govulncheck JSON format (protocol v1.0.0):
#   Stream of pretty-printed JSON objects, each with exactly one field populated:
#     {"config":   {"protocol_version": "v1.0.0", ...}}  — first object
#     {"progress": {"message": "..."}}                    — optional status
#     {"osv":      {"id": "GO-...", "summary": "...", ...}} — vuln metadata
#     {"finding":  {"osv": "GO-...", "fixed_version": "v...", "trace": [...]}} — affected code
#   Note: output is NOT NDJSON — objects span multiple lines. jq handles this
#   natively when reading from a file, but piping through line-based tools won't work.
#   See: https://pkg.go.dev/golang.org/x/vuln/internal/govulncheck
#
# Works for both pull_request and merge_group events — the calling workflow just
# needs to supply the correct base SHA for each event type.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Validate that govulncheck output uses the expected v1 JSON protocol.
# Emits a GitHub Actions warning annotation if the format looks wrong.
validate_format() {
  local json_file=$1

  if [ ! -s "$json_file" ]; then
    echo "::warning::govulncheck produced no output ($(basename "$json_file")) — the scan may have failed, check the step logs"
    return 0
  fi

  local protocol_version
  # jq streams through all JSON values; head -1 takes the first match.
  # || true guards against SIGPIPE from head closing the pipe early.
  protocol_version=$(jq -r 'select(.config) | .config.protocol_version // empty' "$json_file" 2>/dev/null | head -1 || true)

  if [ -z "$protocol_version" ]; then
    echo "::warning::govulncheck output missing config message — JSON format may have changed, details may be incomplete"
    return 0
  fi

  if [[ "$protocol_version" != v1.* ]]; then
    echo "::warning::govulncheck protocol ${protocol_version} detected — this script expects v1.x, details may be incomplete"
  fi
}

# Extract unique OSV vulnerability IDs from govulncheck's JSON stream.
# Reads "finding" objects, which link source code to a vulnerability.
extract_ids() {
  local json_file=$1
  jq -r 'select(.finding) | .finding.osv // empty' "$json_file" 2>/dev/null \
    | sort -u \
    | grep . \
    || true  # grep exits 1 when no matches — don't let set -e kill us
}

# Count non-empty lines in a string. Returns 0 for empty input.
count_lines() {
  local input=$1
  if [ -z "$input" ]; then
    echo 0
  else
    echo "$input" | grep -c .
  fi
}

# Build a JSON lookup keyed by vuln ID: { "GO-...": { summary, module, fixed } }
# Combines OSV entries (for human-readable summary) with finding entries
# (for the actual module/version in use and the fixed version).
build_detail_lookup() {
  local json_file=$1
  # Joins two data sources from the govulncheck JSON stream:
  #   - OSV entries provide the human-readable summary for each vuln.
  #   - Finding entries provide the module/version actually used and the fix version.
  #     trace[0] is the vulnerable dependency as resolved in this codebase.
  # -s (slurp): read the entire multi-object JSON stream into a single array.
  # 2>/dev/null: suppress jq errors on malformed JSON — the fallback handles it.
  jq -s '
    # Pass 1: build { "GO-xxxx": "summary text" } from OSV metadata entries.
    ([.[] | select(.osv) | .osv | {(.id): .summary}] | add // {}) as $summaries |

    # Pass 2: extract module/version/fix from finding entries.
    # trace[0] is the vulnerable dependency as resolved in this codebase.
    [.[] | select(.finding) | .finding | {
      osv,
      module: (.trace[0].module // "unknown"),
      version: (.trace[0].version // "unknown"),
      fixed: (.fixed_version // "no fix available")
    }] | unique_by(.osv) |

    # Merge: combine summaries with findings into a single lookup object.
    map({
      (.osv): {
        summary: ($summaries[.osv] // ""),
        module: .module,
        version: .version,
        fixed: .fixed
      }
    }) | add // {}
  ' "$json_file" 2>/dev/null || {
    # Warning to stderr (visible in CI logs); empty JSON to stdout (consumed by caller).
    echo "::warning::Failed to parse govulncheck JSON — vulnerability details will be incomplete" >&2
    echo '{}'
  }
}

# Emit a single markdown table row for a vulnerability.
# --arg passes the ID safely (no injection risk even if the ID contained special chars).
# Falls back to a minimal row with dashes if the lookup fails.
vuln_row() {
  local id=$1
  local details_file=$2
  local row
  row=$(jq -r --arg id "$id" '
    .[$id] // null |
    if .
    then "[\($id)](https://pkg.go.dev/vuln/\($id)) | \(.summary) | `\(.module)@\(.version)` | `\(.fixed)`"
    else "[\($id)](https://pkg.go.dev/vuln/\($id)) | — | — | —"
    end
  ' "$details_file" 2>/dev/null || echo "[$id](https://pkg.go.dev/vuln/$id) | — | — | —")
  echo "| ${row} |"
}

# Emit a full markdown table for a newline-separated list of vuln IDs.
vuln_table() {
  local ids=$1
  local details_file=$2
  echo "| Vulnerability | Summary | Module | Fixed in |"
  echo "|---|---|---|---|"
  local id
  while IFS= read -r id; do
    [ -n "$id" ] && vuln_row "$id" "$details_file"
  done <<< "$ids"
}

# ---------------------------------------------------------------------------
# Diff: compute new / resolved / pre-existing vulnerability sets
# ---------------------------------------------------------------------------

diff_vuln_ids() {
  local pr_ids=$1
  local base_ids=$2

  # comm requires sorted input (extract_ids already sorts).
  #   -23: lines only in first input  → new in PR
  #   -13: lines only in second input → resolved (were in base, not in PR)
  #   -12: lines in both inputs       → pre-existing
  NEW_IDS=$(comm -23 <(echo "$pr_ids") <(echo "$base_ids") | grep . || true)
  RESOLVED_IDS=$(comm -13 <(echo "$pr_ids") <(echo "$base_ids") | grep . || true)
  EXISTING_IDS=$(comm -12 <(echo "$pr_ids") <(echo "$base_ids") | grep . || true)
}

# ---------------------------------------------------------------------------
# Render: write the GitHub job summary
# ---------------------------------------------------------------------------

# Render the full GitHub job summary. Reads global state set by main():
#   NEW_IDS, RESOLVED_IDS, EXISTING_IDS — newline-separated vuln ID lists
#   new_count, resolved_count, existing_count — integer counts
# Falls back to stdout when GITHUB_STEP_SUMMARY is unset (local testing).
write_summary() {
  local details_file=$1
  local summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

  {
    echo "## Vulnerability Check"
    echo ""

    if [ "$new_count" -gt 0 ]; then
      echo "### :warning: New vulnerabilities ($new_count)"
      echo ""
      echo "These vulnerabilities were not present on the base branch."
      echo ""
      vuln_table "$NEW_IDS" "$details_file"
      echo ""
    else
      echo "### :white_check_mark: No new vulnerabilities"
      echo ""
      echo "This PR does not introduce any new vulnerability findings."
      echo ""
    fi

    if [ "$resolved_count" -gt 0 ]; then
      echo "### :tada: Resolved vulnerabilities ($resolved_count)"
      echo ""
      echo "<details><summary>Click to expand</summary>"
      echo ""
      vuln_table "$RESOLVED_IDS" "$details_file"
      echo ""
      echo "</details>"
      echo ""
    fi

    if [ "$existing_count" -gt 0 ]; then
      echo "### Pre-existing vulnerabilities ($existing_count)"
      echo ""
      echo "<details><summary>Click to expand</summary>"
      echo ""
      vuln_table "$EXISTING_IDS" "$details_file"
      echo ""
      echo "</details>"
    fi
  } >> "$summary_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Temp file for the vuln detail lookup JSON. Declared at module scope so the
# EXIT trap cleans it up even if main() fails during argument parsing.
DETAILS_FILE=$(mktemp)
trap 'rm -f "$DETAILS_FILE"' EXIT

# Algorithm:
#   1. Validate the PR scan output format (warn if protocol changed).
#   2. Extract vuln IDs from both scans → sorted, unique, newline-separated.
#   3. Set-diff the two ID lists → new / resolved / pre-existing.
#   4. Build a { id → details } JSON lookup for rendering.
#   5. Render a GitHub job summary with markdown tables.
#   6. Expose counts via GITHUB_OUTPUT for downstream workflow steps.
#   7. Exit 1 if any new vulns were introduced; 0 otherwise.
main() {
  local pr_json="${1:?Usage: govulncheck-report.sh <pr-vulns.json> <base-vulns.json>}"
  local base_json="${2:?Usage: govulncheck-report.sh <pr-vulns.json> <base-vulns.json>}"

  if ! command -v jq &>/dev/null; then
    echo "::error::jq is required but not installed — use a GitHub-hosted runner or install jq"
    exit 1
  fi

  validate_format "$pr_json"

  # Step 2: extract vuln IDs from both scans.
  PR_IDS=$(extract_ids "$pr_json")
  BASE_IDS=$(extract_ids "$base_json")

  # Step 3: compute set differences (populates NEW_IDS, RESOLVED_IDS, EXISTING_IDS).
  diff_vuln_ids "$PR_IDS" "$BASE_IDS"

  new_count=$(count_lines "$NEW_IDS")
  resolved_count=$(count_lines "$RESOLVED_IDS")
  existing_count=$(count_lines "$EXISTING_IDS")

  # Emit an annotation visible in the PR checks summary.
  if [ "$new_count" -gt 0 ]; then
    echo "::error::${new_count} new $([ "$new_count" -eq 1 ] && echo "vulnerability" || echo "vulnerabilities") introduced — see job summary for details"
  fi

  # Step 4: build the { id → details } lookup from the PR scan's JSON.
  # Only the PR scan is used here — it has the superset of findings we need
  # details for (new + pre-existing). Resolved vulns get details from the base
  # scan's OSV entries which are also present if the PR still references those
  # modules (even if the finding is gone).
  build_detail_lookup "$pr_json" > "$DETAILS_FILE"

  # Step 5: write the GitHub job summary.
  # write_summary reads the global counts and ID lists set above.
  write_summary "$DETAILS_FILE"

  # Step 6: expose counts for downstream workflow steps (e.g., conditional notifications).
  # Gated on GITHUB_OUTPUT so the script still works when run locally.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "new-count=${new_count}" >> "$GITHUB_OUTPUT"
    echo "has-new-vulns=$([ "$new_count" -gt 0 ] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  fi

  # Step 7: fail the check when new vulnerabilities are introduced.
  if [ "$new_count" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
