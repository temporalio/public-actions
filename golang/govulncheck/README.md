# govulncheck

Differential [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) analysis for Go repositories. Scans the current branch and compares against the base branch, **failing only on newly introduced vulnerabilities**. Pre-existing vulnerabilities are reported but don't block the PR.

## Usage

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: actions/setup-go@v5
    with:
      go-version-file: go.mod

  - uses: temporalio/public-actions/golang/govulncheck@main
```

That's it. On `pull_request` and `merge_group` events, `base-sha` is automatically detected and the scan is differential. On other events (e.g., `push`), all findings are treated as new.

## Inputs

| Input | Default | Description |
|---|---|---|
| `govulncheck-version` | `v1.1.4` | Version of govulncheck to install |
| `base-sha` | Auto-detected | Base branch SHA for differential comparison. Override to compare against a specific commit. |

## Outputs

| Output | Description |
|---|---|
| `new-count` | Number of newly introduced vulnerabilities |
| `has-new-vulns` | `true` if new vulnerabilities were found, `false` otherwise |

### Using outputs

```yaml
- uses: temporalio/public-actions/golang/govulncheck@main
  id: vulncheck

- if: steps.vulncheck.outputs.has-new-vulns == 'true'
  run: echo "${{ steps.vulncheck.outputs.new-count }} new vulnerabilities found"
```

## Job summary

The action writes a GitHub job summary with:
- **New vulnerabilities** — not present on the base branch (blocks the PR)
- **Resolved vulnerabilities** — were on the base branch but are now fixed
- **Pre-existing vulnerabilities** — present on both branches (does not block)

Each vulnerability links to [pkg.go.dev/vuln](https://pkg.go.dev/vuln/) with the affected module, current version, and fix version.

## Prerequisites

- Go must be set up before calling this action (e.g., via [actions/setup-go](https://github.com/actions/setup-go))
- `jq` must be available on the runner (pre-installed on GitHub-hosted runners)
