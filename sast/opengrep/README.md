# opengrep

Differential SAST with [Opengrep](https://opengrep.dev) for pull requests. Full-scans both the PR head and the base branch, then **fails only on newly introduced findings** — a finding is "new" only if its `(rule, file)` had fewer findings on the base. Pre-existing findings are reported in the job summary but don't block the PR. Identifying new findings by stable identity rather than by line/content fingerprint means editing a file (e.g. pinning an action SHA) does not re-report a pre-existing whole-file finding such as a missing `permissions:` block.

## Usage

```yaml
steps:
  - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  - uses: temporalio/public-actions/sast/opengrep@main
```

That's it. On `pull_request` and `merge_group` events, `baseline-sha` is automatically detected and the scan is differential. On other events, all findings are treated as new.

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `v1.21.0` | Opengrep version to install |
| `baseline-sha` | Auto-detected | Base SHA for differential scanning. Override to compare against a specific commit. |
| `config` | _(empty)_ | Additional rule config (path or URL). Built-in rules always run. |
| `pr-comments` | `false` | Post findings as inline PR review comments (opt-in, see below). |

## Outputs

| Output | Description |
|---|---|
| `new-count` | Number of new findings introduced by this change |
| `has-new-findings` | `true` if new findings were found, `false` otherwise |

### Using outputs

```yaml
- uses: temporalio/public-actions/sast/opengrep@main
  id: sast

- if: steps.sast.outputs.has-new-findings == 'true'
  run: echo "${{ steps.sast.outputs.new-count }} new findings"
```

## Job summary

The action writes a GitHub job summary with:
- **New findings** — introduced by this change (blocks the PR)
- **Total findings** — all findings across the repo, grouped by rule (informational)

New findings also appear as `::error::` annotations inline on the PR diff.

## PR review comments

Set `pr-comments: 'true'` to post findings as inline review comments directly on the PR diff, similar to Semgrep's managed scans. This requires `pull-requests: write` permission:

```yaml
permissions:
  contents: read
  pull-requests: write

steps:
  - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  - uses: temporalio/public-actions/sast/opengrep@main
    with:
      pr-comments: 'true'
```

Comments are deduplicated across runs using the finding fingerprint — re-running the action on the same PR won't create duplicate comments. Each comment includes suppression guidance. Multi-line findings highlight the full matched range in the diff.

When a finding is fixed, the action strikes through the original comment and attempts to resolve the review thread. Thread resolution requires a GitHub App token or PAT — the default `GITHUB_TOKEN` can update the comment body but cannot resolve threads via GraphQL (`Resource not accessible by integration`).

When a finding's line isn't part of the diff (edge case), the action falls back to a single PR comment with a table of findings and clickable links. This fallback comment is updated in-place on subsequent runs to avoid notification noise.

## Built-in rules

| Rule | Languages | What it detects |
|---|---|---|
| `security.gha.missing-explicit-permissions` | yaml | GitHub Actions workflows without explicit `permissions:` |
| `security.gha.run-shell-injection` | yaml | Untrusted `${{ github.* }}` context interpolated into a `run:`/`script:` block (shell injection) |
| `security.gha.run-shell-injection-inputs` | yaml | _(WARNING)_ Caller-supplied `inputs.*` interpolated into a `run:`/`script:` block — route through `env:` (advisory) |
| `security.gha.run-shell-injection-refs` | yaml | _(WARNING)_ Non-fork-controlled Git ref (`github.ref`/`base_ref`/`ref_name`/`pull_request.base.ref`) in a `run:`/`script:` block — route through `env:` (advisory) |
| `security.gha.deprecated.tibdex-github-app-token` | yaml | Deprecated `tibdex/github-app-token` usage |
| `security.go-zipslip-archive-path-traversal` | go | Unvalidated archive extraction paths (zip slip) |

Additional rules can be supplied via the `config` input — a path to a directory of YAML rule files in your repo, or a URL to a rule file:

```yaml
# Add repo-local custom rules
- uses: temporalio/public-actions/sast/opengrep@main
  with:
    config: .opengrep/rules/
```

Rules use the [Opengrep rule syntax](https://opengrep.dev/docs/writing-rules). Teams can add their own rules by creating YAML files in any directory and pointing `config` at it.

## Suppressions

Add a `noopengrep` comment on the matching line to suppress a finding:

```go
path := filepath.Join(dst, f.Name) // noopengrep: security.go-zipslip-archive-path-traversal
```

Opengrep also honors `.semgrepignore` files for excluding paths from scanning.

## Prerequisites

- `jq` must be available on the runner (pre-installed on GitHub-hosted runners)
- No other setup required — the action downloads the Opengrep binary automatically
