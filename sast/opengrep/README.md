# opengrep

Differential SAST with [Opengrep](https://opengrep.dev) for pull requests. Scans the current branch and compares against the base branch using `--baseline-commit`, **failing only on newly introduced findings**. Pre-existing findings are reported in the job summary but don't block the PR.

## Usage

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: temporalio/public-actions/sast/opengrep@main
```

That's it. On `pull_request` and `merge_group` events, `baseline-sha` is automatically detected and the scan is differential. On other events, all findings are treated as new.

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `v1.21.0` | Opengrep version to install |
| `baseline-sha` | Auto-detected | Base SHA for differential scanning. Override to compare against a specific commit. |
| `config` | _(empty)_ | Additional rule config (path or URL). Built-in rules always run. |

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

## Built-in rules

| Rule | Languages | What it detects |
|---|---|---|
| `security.gha.missing-explicit-permissions-temporal` | yaml | GitHub Actions workflows without explicit `permissions:` |
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
