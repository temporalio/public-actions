#!/usr/bin/env bash
# govulncheck-report.sh — Compare govulncheck results between PR and base branch,
# then write a GitHub job summary with the findings.
#
# Usage:
#   govulncheck-report.sh <pr-vulns.json> <base-vulns.json> [ignore-file] [fail-on]
#
# fail-on selects the lowest govulncheck scan level that may fail the check:
#   module  (default) any vulnerability in the module graph, reachable or not
#   package           only if the vulnerable package is imported
#   symbol            only if your code actually calls the vulnerable symbol
# Findings below the threshold are still reported, in their own job-summary
# section, but never block. See extract_ids() for how levels are derived.
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
# Ignore file format (optional third argument, conventionally .govulncheck-ignore):
#   One Go vulnerability ID per line. Blank lines are skipped. Everything after
#   a '#' is a comment. A comment block directly above an entry — or a trailing
#   comment on the entry line — is captured as that entry's reason and rendered
#   in the job summary, so the "why" travels with the suppression.
#
#     # x/crypto/openpgp is unmaintained upstream and has no fix. We only
#     # require the module transitively; nothing in our build imports it.
#     GO-2026-5932
#
#     GO-2025-1234  # waiting on github.com/foo/bar#42
#
#   Ignored IDs never fail the check. They are still listed in the job summary
#   so a suppression stays visible rather than disappearing. A malformed line is
#   a hard error: a silently misparsed ignore file would weaken the gate without
#   anyone noticing.
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

# Extract unique OSV vulnerability IDs from govulncheck's JSON stream, keeping
# only those that reach at least the given scan level.
#
# govulncheck emits findings at three levels, distinguished by how much of
# trace[0] is populated (see the Frame docs linked at the top of this file):
#
#   1 module   module + version only  — the module is in the build graph
#   2 package  + package              — the vulnerable package is imported
#   3 symbol   + function             — your code calls the vulnerable symbol
#
# One vulnerability can produce findings at several levels, so each ID is
# reduced to its highest level before the threshold is applied. Level 3 is what
# govulncheck's own text output counts under "Your code is affected by"; levels
# 1 and 2 are what it reports as "your code doesn't appear to call these".
extract_ids() {
  local json_file=$1
  local min_level=$2
  jq -r --argjson min "$min_level" -s '
    [ .[]
      | select(.finding)
      | .finding
      | { osv,
          level: (
            if   (.trace[0].function // "") != "" then 3
            elif (.trace[0].package  // "") != "" then 2
            else 1
            end) } ]
    | group_by(.osv)
    | map(select((map(.level) | max) >= $min))
    | .[][0].osv
  ' "$json_file" 2>/dev/null \
    | sort -u \
    | grep . \
    || true  # grep exits 1 when no matches — don't let set -e kill us
}

# Translate a fail-on level name into its numeric rank. Exits non-zero on an
# unrecognized name so a typo fails the job instead of silently picking a
# threshold nobody intended.
level_rank() {
  case "$1" in
    module)  echo 1 ;;
    package) echo 2 ;;
    symbol)  echo 3 ;;
    *)       return 1 ;;
  esac
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

# Parse an ignore file into TAB-separated "ID<TAB>reason" lines on stdout.
# Returns non-zero (after reporting every bad line) if any entry is malformed.
#
# Interval expressions and alternation are avoided in the patterns below so the
# parser behaves identically under mawk (the default awk on Ubuntu runners),
# gawk, and BSD awk.
parse_ignorelist() {
  local ignore_file=$1
  awk -v file="$ignore_file" '
    # Tolerate CRLF files authored on Windows.
    { sub(/\r$/, "") }

    # A blank line ends the current comment block, so a comment paragraph
    # separated from an entry by whitespace is not mistaken for its reason.
    /^[ \t]*$/ { pending = ""; next }

    # Whole-line comment: accumulate as the pending reason for the next entry.
    /^[ \t]*#/ {
      text = $0
      sub(/^[ \t]*#[ \t]?/, "", text)
      pending = (pending == "" ? text : pending " " text)
      next
    }

    {
      line = $0
      reason = ""

      # A trailing comment on the entry line wins over the block above it.
      hash = index(line, "#")
      if (hash > 0) {
        reason = substr(line, hash + 1)
        line = substr(line, 1, hash - 1)
        sub(/^[ \t]+/, "", reason); sub(/[ \t]+$/, "", reason)
      }
      sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)

      if (line !~ /^GO-[0-9][0-9][0-9][0-9]-[0-9]+$/) {
        printf("::error file=%s,line=%d::malformed ignore entry \"%s\" — expected a Go vulnerability ID such as GO-2026-5932, optionally followed by \"# reason\"\n", file, NR, line) > "/dev/stderr"
        bad = 1
        pending = ""
        next
      }

      if (reason == "") reason = pending
      if (reason == "") reason = "(no reason given)"
      printf("%s\t%s\n", line, reason)
      pending = ""
    }

    END { if (bad) exit 1 }
  ' "$ignore_file"
}

# Remove ignored IDs from a newline-separated ID list.
# Both inputs are sorted and unique, so comm -23 is a plain set difference.
filter_ids() {
  local ids=$1
  local ignored=$2
  [ -z "$ignored" ] && { echo "$ids"; return 0; }
  comm -23 <(echo "$ids") <(echo "$ignored") | grep . || true
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

# Emit a markdown table for ignored vulns, carrying the reason from the
# ignore file so reviewers can see the justification without opening it.
# Input is the TAB-separated "ID<TAB>reason" list produced by parse_ignorelist,
# already restricted to IDs that actually appear in this scan.
ignored_table() {
  local entries=$1
  local details_file=$2
  echo "| Vulnerability | Summary | Module | Reason ignored |"
  echo "|---|---|---|---|"
  local id reason row
  while IFS=$'\t' read -r id reason; do
    [ -n "$id" ] || continue
    # Escape pipes so a reason containing '|' cannot break the table layout.
    reason=${reason//|/\\|}
    row=$(jq -r --arg id "$id" --arg reason "$reason" '
      .[$id] // null |
      if .
      then "[\($id)](https://pkg.go.dev/vuln/\($id)) | \(.summary) | `\(.module)@\(.version)` | \($reason)"
      else "[\($id)](https://pkg.go.dev/vuln/\($id)) | — | — | \($reason)"
      end
    ' "$details_file" 2>/dev/null || echo "[$id](https://pkg.go.dev/vuln/$id) | — | — | ${reason}")
    echo "| ${row} |"
  done <<< "$entries"
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
#   IGNORED_ENTRIES — TAB-separated "ID<TAB>reason" lines for suppressed vulns
#   BELOW_IDS — vulns under the fail-on threshold (reported, never blocking)
#   new_count, resolved_count, existing_count, ignored_count, below_count
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
      echo ""
    fi

    if [ "$ignored_count" -gt 0 ]; then
      echo "### :mute: Ignored vulnerabilities ($ignored_count)"
      echo ""
      echo "Suppressed by \`${IGNORE_FILE_PATH}\`. These do not block the PR."
      echo ""
      echo "<details><summary>Click to expand</summary>"
      echo ""
      ignored_table "$IGNORED_ENTRIES" "$details_file"
      echo ""
      echo "</details>"
      echo ""
    fi

    if [ "$below_count" -gt 0 ]; then
      echo "### :information_source: Below the \`${FAIL_ON_LEVEL}\` threshold ($below_count)"
      echo ""
      case "$FAIL_ON_LEVEL" in
        package) echo "Present in the module graph, but the vulnerable package is not imported." ;;
        symbol)  echo "Present in the build, but your code does not call the vulnerable symbols." ;;
      esac
      echo "Reported for visibility; these do not block the PR."
      echo ""
      echo "<details><summary>Click to expand</summary>"
      echo ""
      vuln_table "$BELOW_IDS" "$details_file"
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

# Ignore-list and threshold state, declared here so write_summary can read it
# under `set -u` even when no ignore file or non-default threshold is in play.
IGNORED_ENTRIES=""
IGNORE_FILE_PATH=""
BELOW_IDS=""
FAIL_ON_LEVEL="module"

# Algorithm:
#   1. Validate the PR scan output format (warn if protocol changed).
#   2. Extract vuln IDs at or above the fail-on threshold from both scans.
#   3. Parse the ignore file (if any) into IDs + reasons.
#   4. Set-diff the two ID lists → new / resolved / pre-existing.
#   5. Subtract ignored IDs from every bucket; report them separately.
#   6. Build a { id → details } JSON lookup for rendering.
#   7. Render a GitHub job summary with markdown tables.
#   8. Expose counts via GITHUB_OUTPUT for downstream workflow steps.
#   9. Exit 1 if any non-ignored new vulns were introduced; 0 otherwise.
USAGE="Usage: govulncheck-report.sh <pr-vulns.json> <base-vulns.json> [ignore-file] [fail-on]"
main() {
  local pr_json="${1:?$USAGE}"
  local base_json="${2:?$USAGE}"
  local ignore_file="${3:-}"
  FAIL_ON_LEVEL="${4:-module}"

  if ! command -v jq &>/dev/null; then
    echo "::error::jq is required but not installed — use a GitHub-hosted runner or install jq"
    exit 1
  fi

  local min_level
  if ! min_level=$(level_rank "$FAIL_ON_LEVEL"); then
    echo "::error::invalid fail-on level '${FAIL_ON_LEVEL}' — expected one of: module, package, symbol"
    exit 1
  fi

  validate_format "$pr_json"

  # Step 2: extract vuln IDs from both scans, keeping only those at or above
  # the threshold. Everything below it is still collected so the summary can
  # report it without blocking.
  PR_IDS=$(extract_ids "$pr_json" "$min_level")
  BASE_IDS=$(extract_ids "$base_json" "$min_level")

  # Every ID in the PR scan regardless of level. Used for the below-threshold
  # section, and so that ignore entries covering a below-threshold finding are
  # not misreported as stale.
  local pr_all_ids
  pr_all_ids=$(extract_ids "$pr_json" 1)
  BELOW_IDS=$(filter_ids "$pr_all_ids" "$PR_IDS")

  # Step 3: parse the ignore file. It is read from the head tree, so a PR can
  # add a suppression and have it apply to itself — required to unblock a PR at
  # all. Gate that with CODEOWNERS on the ignore file if review is needed.
  # A parse failure is fatal: continuing would silently apply a partial list.
  IGNORE_FILE_PATH=$ignore_file
  local ignore_entries=""
  if [ -n "$ignore_file" ]; then
    if [ ! -f "$ignore_file" ]; then
      echo "::error::ignore file '${ignore_file}' not found"
      exit 1
    fi
    if ! ignore_entries=$(parse_ignorelist "$ignore_file"); then
      echo "::error::could not parse ignore file '${ignore_file}' — see the annotations above"
      exit 1
    fi
  fi

  # De-duplicate by ID (first entry wins, so the reason nearest the top of the
  # file is the one shown), then sort so the IDs can be fed to comm as a set.
  local ignored_ids=""
  if [ -n "$ignore_entries" ]; then
    local dupes
    dupes=$(cut -f1 <<< "$ignore_entries" | sort | uniq -d | grep . || true)
    if [ -n "$dupes" ]; then
      echo "::warning::duplicate entries in ${ignore_file}: $(tr '\n' ' ' <<< "$dupes")"
    fi
    ignore_entries=$(awk -F'\t' '!seen[$1]++' <<< "$ignore_entries" | sort -t$'\t' -k1,1)
    ignored_ids=$(cut -f1 <<< "$ignore_entries")
  fi

  # Step 4: compute set differences (populates NEW_IDS, RESOLVED_IDS, EXISTING_IDS).
  diff_vuln_ids "$PR_IDS" "$BASE_IDS"

  # Step 5: an ignored ID must not land in any bucket that implies action. Only
  # entries that actually matched this scan are reported as ignored; the rest
  # are stale and flagged so the file does not accumulate dead suppressions.
  if [ -n "$ignored_ids" ]; then
    NEW_IDS=$(filter_ids "$NEW_IDS" "$ignored_ids")
    RESOLVED_IDS=$(filter_ids "$RESOLVED_IDS" "$ignored_ids")
    EXISTING_IDS=$(filter_ids "$EXISTING_IDS" "$ignored_ids")
    # An explicit ignore wins over the threshold classification, so the entry
    # and its reason are what a reviewer sees rather than a bare listing.
    BELOW_IDS=$(filter_ids "$BELOW_IDS" "$ignored_ids")

    # Keep only the entries whose ID actually appeared in this scan, at any level.
    IGNORED_ENTRIES=$(awk -F'\t' 'NR==FNR { present[$0]=1; next } present[$1]' \
      <(echo "$pr_all_ids") <(echo "$ignore_entries") || true)

    local stale stale_count
    stale=$(comm -23 <(echo "$ignored_ids") <(echo "$pr_all_ids") | grep . || true)
    stale_count=$(count_lines "$stale")
    if [ "$stale_count" -gt 0 ]; then
      echo "::warning::${IGNORE_FILE_PATH} lists ${stale_count} $([ "$stale_count" -eq 1 ] && echo "vulnerability" || echo "vulnerabilities") not present in this scan — consider removing: $(tr '\n' ' ' <<< "$stale")"
    fi
  fi

  new_count=$(count_lines "$NEW_IDS")
  resolved_count=$(count_lines "$RESOLVED_IDS")
  existing_count=$(count_lines "$EXISTING_IDS")
  ignored_count=$(count_lines "${IGNORED_ENTRIES:-}")
  below_count=$(count_lines "$BELOW_IDS")

  # Emit an annotation visible in the PR checks summary.
  if [ "$new_count" -gt 0 ]; then
    echo "::error::${new_count} new $([ "$new_count" -eq 1 ] && echo "vulnerability" || echo "vulnerabilities") introduced — see job summary for details"
  fi

  # Step 6: build the { id → details } lookup from the PR scan's JSON.
  # Only the PR scan is used here — it has the superset of findings we need
  # details for (new + pre-existing). Resolved vulns get details from the base
  # scan's OSV entries which are also present if the PR still references those
  # modules (even if the finding is gone).
  build_detail_lookup "$pr_json" > "$DETAILS_FILE"

  # Step 7: write the GitHub job summary.
  # write_summary reads the global counts and ID lists set above.
  write_summary "$DETAILS_FILE"

  # Step 8: expose counts for downstream workflow steps (e.g., conditional notifications).
  # Gated on GITHUB_OUTPUT so the script still works when run locally.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "new-count=${new_count}" >> "$GITHUB_OUTPUT"
    echo "has-new-vulns=$([ "$new_count" -gt 0 ] && echo true || echo false)" >> "$GITHUB_OUTPUT"
    echo "ignored-count=${ignored_count}" >> "$GITHUB_OUTPUT"
    echo "below-threshold-count=${below_count}" >> "$GITHUB_OUTPUT"
  fi

  # Step 9: fail the check when new, non-ignored vulnerabilities are introduced.
  if [ "$new_count" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
