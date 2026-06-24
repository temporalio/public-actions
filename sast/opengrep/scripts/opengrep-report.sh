#!/usr/bin/env bash
# opengrep-report.sh — Parse Opengrep JSON results, write a GitHub job summary
# with ::error:: annotations for new findings.
#
# Usage:
#   opengrep-report.sh <baseline-findings.json> <head-findings.json>
#
# "New" findings are computed here as the head full scan minus the baseline
# full scan, keyed by stable identity (see compute_new_findings) — NOT by
# opengrep's --baseline-commit, whose location/content fingerprint re-reports
# pre-existing whole-file findings as new whenever the file is edited.
#
# Environment variables (set automatically by GitHub Actions):
#   GITHUB_STEP_SUMMARY — path to the job summary file (falls back to stdout)
#   GITHUB_OUTPUT       — path to expose step outputs
#
# Local testing:
#   opengrep scan --config rules/ --json . > /tmp/head.json
#   git worktree add --detach /tmp/base <base-sha>
#   ( cd /tmp/base && opengrep scan --config rules/ --json . ) > /tmp/baseline.json
#   ./opengrep-report.sh /tmp/baseline.json /tmp/head.json
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

# jq program: head findings minus baseline findings.
#
# Identity is the STABLE key (check_id, path) plus a per-key COUNT — never the
# line number or the matched text. Both of those shift when an unrelated line
# *inside* a whole-block "absence" match (e.g. the missing-permissions rule,
# which matches a whole job) is edited, which is exactly why opengrep's
# --baseline-commit re-reported pre-existing findings as new on PRs that only
# touched the file (SEC-1975).
#
# Per key, new count = max(0, head_count - baseline_count):
#   - edit inside a pre-existing match -> count unchanged -> 0 new (no noise)
#   - a genuinely new gap (new job/file/line) -> count rises -> still reported
# When a key gained findings, the head findings least like the baseline
# (content- and start-line-novel) are surfaced first, then capped at the delta,
# so the annotation points at the genuinely new finding rather than an edited
# pre-existing one.
NEW_FINDINGS_JQ='
($base[0].results // []) as $br
| (.results // []) as $hr
| ( $br
    | group_by([.check_id, .path])
    | map({ k: ([.[0].check_id, .[0].path] | @json),
            n: length,
            sigs: [.[].extra.lines],
            lines: [.[].start.line] })
    | map({ (.k): . }) | add // {} ) as $bmap
| [ $hr
    | group_by([.check_id, .path])[]
    | ([.[0].check_id, .[0].path] | @json) as $k
    | ($bmap[$k].n // 0) as $bn
    | ($bmap[$k].sigs // []) as $bsigs
    | ($bmap[$k].lines // []) as $blines
    | ((length - $bn) | if . < 0 then 0 else . end) as $delta
    | ( map(. + { _novel:
            ( (if ([.extra.lines] - $bsigs) | length > 0 then 1 else 0 end)
            + (if ([.start.line] - $blines) | length > 0 then 1 else 0 end) ) })
        | sort_by(-._novel)
        | .[0:$delta]
        | map(del(._novel)) ) ]
| add // []
| { results: ., errors: [], paths: {} }
'

# compute_new_findings <baseline-json> <head-json> <out-json>
# Write the new-findings JSON (a subset of the head results, preserved verbatim)
# to <out-json>. A missing/empty baseline or a diff failure conservatively
# treats every head finding as new, so a baseline problem never hides a finding.
compute_new_findings() {
  local baseline_json=$1 head_json=$2 out_json=$3

  if [ ! -s "$head_json" ]; then
    printf '%s\n' '{"results":[],"errors":[],"paths":{}}' > "$out_json"
    return
  fi

  local base_json=$baseline_json cleanup=""
  if [ ! -s "$baseline_json" ]; then
    base_json=$(mktemp)
    cleanup=$base_json
    printf '%s\n' '{"results":[]}' > "$base_json"
  fi

  if ! jq --slurpfile base "$base_json" "$NEW_FINDINGS_JQ" "$head_json" \
      > "$out_json" 2>/dev/null; then
    cp "$head_json" "$out_json"
  fi

  [ -n "$cleanup" ] && rm -f "$cleanup"
  return 0
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

# Resolve Opengrep review threads whose findings no longer appear in the scan.
# This keeps the PR conversation clean when developers fix flagged issues.
resolve_stale_threads() {
  local json_file=$1

  if [ "${PR_COMMENTS_ENABLED:-}" != "true" ]; then
    return
  fi
  if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${PR_NUMBER:-}" ]; then
    return
  fi
  if ! command -v gh &>/dev/null; then
    return
  fi

  local repo="${GITHUB_REPOSITORY}"
  local owner="${repo%%/*}"
  local name="${repo##*/}"

  # Collect current finding fingerprints (empty set if no findings file).
  local current_fps
  current_fps=$(jq '[.results[]? | .extra.fingerprint // empty] | unique' \
    "$json_file" 2>/dev/null) || current_fps="[]"

  # Fetch all unresolved Opengrep review threads via GraphQL.
  # Include databaseId so we can PATCH the comment body via REST.
  local threads
  threads=$(gh api graphql -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes { body databaseId }
              }
            }
          }
        }
      }
    }' -f owner="$owner" -f name="$name" -F pr="$PR_NUMBER" \
    --jq '
      [.data.repository.pullRequest.reviewThreads.nodes[] |
        select(.isResolved == false) |
        select(.comments.nodes[0].body | test("<!-- opengrep:")) |
        {
          thread_id: .id,
          comment_id: .comments.nodes[0].databaseId,
          body: .comments.nodes[0].body,
          fp: (.comments.nodes[0].body |
            capture("<!-- opengrep:(?<fp>[^\\s]+) -->") | .fp)
        }
      ]
    ' 2>/dev/null) || return 0

  # Filter to threads whose fingerprint is no longer in the current findings.
  local stale_threads
  stale_threads=$(echo "$threads" | jq --argjson current "$current_fps" '
    [.[] | select([.fp] - $current | length > 0)]
  ' 2>/dev/null) || return 0

  local stale_count
  stale_count=$(echo "$stale_threads" | jq 'length')
  if [ "$stale_count" -eq 0 ]; then
    return
  fi

  local head_sha="${PR_HEAD_SHA:-${GITHUB_SHA:-unknown}}"
  local server_url="${GITHUB_SERVER_URL:-https://github.com}"

  # For each stale thread: strike through the comment body and resolve.
  # Build a list of {thread_id, comment_id, new_body} to process.
  # The new body preserves the fingerprint marker (for dedup), strikes through
  # the original message, drops the suppress/suggestion blocks, and adds a
  # commit link showing when the finding was fixed.
  local resolved_threads
  resolved_threads=$(echo "$stale_threads" | jq \
    --arg sha "$head_sha" \
    --arg server "$server_url" \
    --arg repo "$repo" '
    [.[] | {
      thread_id,
      comment_id: (.comment_id | tostring),
      new_body: (
        "<!-- opengrep:" + .fp + " -->\n" +
        "<strike>\n\n" + (.body |
          gsub("<!-- opengrep:[^>]+ -->\\n?"; "") |
          gsub("\\n\\n```suggestion[\\s\\S]*?```"; "") |
          gsub("\\n---\\n<details>[\\s\\S]*</details>"; "") |
          rtrimstr("\n")
        ) + "\n\n</strike>\n\n" +
        "Fixed in [`" + $sha[0:7] + "`](" +
          $server + "/" + $repo + "/commit/" + $sha + ")"
      )
    }]
  ' 2>/dev/null) || return 0

  local i thread_id comment_id new_body
  for i in $(seq 0 $((stale_count - 1))); do
    thread_id=$(echo "$resolved_threads" | jq -r ".[$i].thread_id")
    comment_id=$(echo "$resolved_threads" | jq -r ".[$i].comment_id")
    new_body=$(echo "$resolved_threads" | jq -r ".[$i].new_body")

    # Update the comment body via REST.
    if gh api "repos/${repo}/pulls/comments/${comment_id}" \
      --method PATCH \
      -f body="$new_body" > /dev/null 2>&1; then
      echo "Struck through comment ${comment_id}"
    else
      echo "::warning::Failed to update comment ${comment_id}"
    fi

    # Resolve the thread via GraphQL.
    local resolve_result
    if resolve_result=$(gh api graphql -f query='
      mutation($id: ID!) {
        resolveReviewThread(input: {threadId: $id}) {
          thread { isResolved }
        }
      }' -f id="$thread_id" 2>&1); then
      echo "Resolved thread ${thread_id}"
    else
      echo "::warning::Failed to resolve thread ${thread_id}: $(echo "$resolve_result" | tr '\n' ' ')"
    fi
  done

  echo "Processed ${stale_count} stale Opengrep review thread(s)"
}

# Post findings as inline PR review comments via the GitHub API.
# Each comment embeds the finding fingerprint as an HTML comment so that
# repeat runs on the same PR skip findings that were already commented on.
post_pr_comments() {
  local json_file=$1

  if [ "${PR_COMMENTS_ENABLED:-}" != "true" ]; then
    return
  fi
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "::warning::pr-comments enabled but no GITHUB_TOKEN available — skipping PR review comments"
    return
  fi
  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::debug::Not a pull_request event — skipping PR review comments"
    return
  fi
  if [ ! -s "$json_file" ]; then
    return
  fi

  local repo="${GITHUB_REPOSITORY}"
  local commit_sha="${PR_HEAD_SHA:-}"
  if [ -z "$commit_sha" ]; then
    echo "::warning::PR head SHA not available — skipping PR review comments"
    return
  fi

  if ! command -v gh &>/dev/null; then
    echo "::warning::gh CLI not found — skipping PR review comments"
    return
  fi

  # --- Deduplication: fetch existing review comments and collect fingerprints
  # already posted by a previous run so we don't repeat them.  gh handles
  # pagination automatically via --paginate.  Each page is a JSON array of
  # comment objects; --jq extracts fingerprints per page, then jq -s merges
  # all pages into a single unique list.
  local existing_fingerprints
  if ! existing_fingerprints=$(gh api \
    --paginate \
    "repos/${repo}/pulls/${PR_NUMBER}/comments" \
    --jq '
      [.[] | .body // empty |
        select(test("<!-- opengrep:")) |
        capture("<!-- opengrep:(?<fp>[^\\s]+) -->") | .fp
      ]
    ' | jq -s 'add | unique // []'); then
    echo "::warning::Failed to fetch existing PR comments for dedup — may repost findings"
    existing_fingerprints="[]"
  fi

  # --- Build review comments, skipping already-posted fingerprints.
  # Uses start_line/line to highlight the full matched range when the finding
  # spans multiple lines (GitHub renders this as a multi-line comment).
  # Construct a base URL for rule source links from the action's own repo/ref.
  # GITHUB_ACTION_REPOSITORY isn't set for shell steps in composite actions,
  # so parse the repo and ref from GITHUB_ACTION_PATH instead:
  #   /home/runner/work/_actions/{owner}/{repo}/{ref}/...
  local action_repo="" action_ref=""
  if [[ "${GITHUB_ACTION_PATH:-}" =~ _actions/([^/]+/[^/]+)/([^/]+)/ ]]; then
    action_repo="${BASH_REMATCH[1]}"
    action_ref="${BASH_REMATCH[2]}"
  fi
  local server_url="${GITHUB_SERVER_URL:-https://github.com}"
  local rule_base_url=""
  if [ -n "$action_repo" ]; then
    rule_base_url="${server_url}/${action_repo}/blob/${action_ref}/"
  fi

  local comments
  comments=$(jq --argjson seen "$existing_fingerprints" --arg rule_base "$rule_base_url" '
    [.results[] |
      select((.extra.fingerprint // "") as $fp |
        $fp == "" or ([$fp] - $seen | length > 0)) |
      {
        path,
        line: .end.line,
        side: "RIGHT",
        body: (
          "<!-- opengrep:" + (.extra.fingerprint // "unknown") + " -->\n" +
          "**Opengrep** — " +
          (if (.extra.metadata.source // null) and $rule_base != "" then
            "[`\(.check_id)`](" + $rule_base + .extra.metadata.source + ")"
          else "`\(.check_id)`" end) +
          " (\(.extra.severity))\n\n" +
          .extra.message + "\n\n" +
          # Include a GitHub suggestion block when the rule provides an autofix.
          # Splice the fix into the original source line to preserve indentation:
          # prefix (before match start col) + fix + suffix (after match end col).
          (if .extra.fix then
            ((.extra.lines | rtrimstr("\n"))[0:.start.col - 1]
              + (.extra.fix | rtrimstr("\n"))
              + (.extra.lines | rtrimstr("\n"))[.end.col - 1:]
            ) as $fixed_line |
            "```suggestion\n" + $fixed_line + "\n```\n\n"
          else "" end) +
          "---\n" +
          "<details><summary>Suppress this finding</summary>\n\n" +
          "Add a suppression comment on the line before:\n```\n" +
          "# noopengrep: \(.check_id)\n" +
          "```\n\n</details>"
        )
      } +
      # Add start_line only for multi-line findings.
      if .start.line != .end.line then
        {start_line: .start.line, start_side: "RIGHT"}
      else {} end
    ]
  ' "$json_file") || return 0

  local comment_count
  comment_count=$(echo "$comments" | jq 'length')
  if [ "$comment_count" -eq 0 ]; then
    echo "All findings already have PR comments — nothing new to post"
    return
  fi

  # --- Post a single review with all inline comments.  This places comments
  # directly on the relevant lines in the PR diff.  If it fails (e.g. a
  # finding's line isn't part of the diff), fall back to a plain PR comment.
  local payload
  payload=$(jq -n \
    --arg sha "$commit_sha" \
    --argjson comments "$comments" \
    '{commit_id: $sha, event: "COMMENT", comments: $comments}')

  local gh_stderr
  if gh_stderr=$(gh api \
    "repos/${repo}/pulls/${PR_NUMBER}/reviews" \
    --method POST \
    --input - <<< "$payload" 2>&1 >/dev/null); then
    echo "Posted PR review with ${comment_count} inline comment(s)"
    return
  fi

  echo "::debug::Inline review failed, falling back to PR comment. gh api: $(echo "$gh_stderr" | tr '\n' ' ')"

  # --- Fallback: post (or update) a plain PR comment with findings as a table.
  # Look for an existing Opengrep summary comment to update in-place, avoiding
  # duplicate comments on every push.
  local existing_comment_id
  existing_comment_id=$(gh api \
    --paginate \
    "repos/${repo}/issues/${PR_NUMBER}/comments" \
    --jq '.[] | select(.body | test("<!-- opengrep:summary -->")) | .id' \
    2>/dev/null | head -1) || existing_comment_id=""

  local server_url="${GITHUB_SERVER_URL:-https://github.com}"
  local comment_body
  comment_body=$(jq -r \
    --arg server "$server_url" \
    --arg repo "$repo" \
    --arg sha "$commit_sha" '
    "<!-- opengrep:summary -->\n" +
    "### Opengrep — new findings\n\n" +
    "| Severity | Location | Rule | Message |\n" +
    "|----------|----------|------|---------|\n" +
    ([.results[] |
      "| \(.extra.severity) " +
      "| [`\(.path):\(.start.line)`](\($server)/\($repo)/blob/\($sha)/\(.path)#L\(.start.line)) " +
      "| `\(.check_id)` " +
      "| \(.extra.message | gsub("\\|"; "\\|") | gsub("\n"; " ")) |"
    ] | join("\n")) +
    "\n\n---\n" +
    "<details><summary>Suppress findings</summary>\n\n" +
    "Add a `noopengrep` comment on the line before the finding:\n" +
    "```\n# noopengrep: <rule-id>\n```\n\n" +
    "</details>"
  ' "$json_file") || return 0

  if [ -n "$existing_comment_id" ]; then
    # Update the existing comment in-place — no new notification.
    if gh api \
      "repos/${repo}/issues/comments/${existing_comment_id}" \
      --method PATCH \
      -f body="$comment_body" > /dev/null 2>&1; then
      echo "Updated existing PR comment with ${comment_count} finding(s)"
    else
      echo "::warning::Failed to update PR comment — findings are still shown as annotations and job summary"
    fi
  else
    if gh api \
      "repos/${repo}/issues/${PR_NUMBER}/comments" \
      --method POST \
      -f body="$comment_body" > /dev/null 2>&1; then
      echo "Posted PR comment with ${comment_count} finding(s) (inline review unavailable)"
    else
      echo "::warning::Failed to post PR comment — findings are still shown as annotations and job summary"
    fi
  fi
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
  local baseline_json="${1:?Usage: opengrep-report.sh <baseline-findings.json> <head-findings.json>}"
  local head_json="${2:?Usage: opengrep-report.sh <baseline-findings.json> <head-findings.json>}"

  if ! command -v jq &>/dev/null; then
    echo "::error::jq is required but not installed — use a GitHub-hosted runner or install jq"
    exit 1
  fi

  # New findings = head full scan minus baseline full scan, by stable identity.
  local new_json
  new_json=$(mktemp)
  # Bake the path into the trap now (double quotes): the EXIT trap fires in the
  # global scope where this local would be unbound under `set -u`.
  # shellcheck disable=SC2064  # intentional: expand $new_json at definition time
  trap "rm -f '$new_json'" EXIT
  compute_new_findings "$baseline_json" "$head_json" "$new_json"

  local new_count all_count scanned_count
  new_count=$(count_findings "$new_json")
  all_count=$(count_findings "$head_json")
  scanned_count=$(count_scanned "$head_json")

  # Emit ::error:: annotations for new findings (visible on PR diff).
  if [ "$new_count" -gt 0 ]; then
    emit_annotations "$new_json"
  fi

  # Write GitHub job summary.
  write_summary "$new_json" "$head_json" "$new_count" "$all_count" "$scanned_count"

  # Post inline PR review comments for new findings (best-effort — never
  # blocks outputs or the exit code, which are the authoritative signals).
  if [ "$new_count" -gt 0 ]; then
    post_pr_comments "$new_json" || true
  fi

  # Resolve review threads for findings that were fixed since the last run.
  resolve_stale_threads "$new_json" || true

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
