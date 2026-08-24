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
| `ignore-file` | `.govulncheck-ignore` if present | Path to a file listing vulnerabilities that must not fail the check. An explicitly set path that does not exist is an error. |
| `fail-on` | `module` | Lowest scan level that may fail the check: `module`, `package`, or `symbol`. See [Reachability](#reachability). |

## Outputs

| Output | Description |
|---|---|
| `new-count` | Number of newly introduced vulnerabilities |
| `has-new-vulns` | `true` if new vulnerabilities were found, `false` otherwise |
| `ignored-count` | Number of vulnerabilities suppressed by the ignore file |
| `below-threshold-count` | Number of vulnerabilities reported but below the `fail-on` threshold |

### Using outputs

```yaml
- uses: temporalio/public-actions/golang/govulncheck@main
  id: vulncheck

- if: steps.vulncheck.outputs.has-new-vulns == 'true'
  run: echo "${{ steps.vulncheck.outputs.new-count }} new vulnerabilities found"
```

## Reachability

govulncheck reports a vulnerability at one of three levels, depending on how deeply your code touches it:

| Level | Meaning | govulncheck's own wording |
|---|---|---|
| `module` | The module is in your build graph | "in modules you require... your code doesn't appear to call these" |
| `package` | The vulnerable package is imported | "in packages you import" |
| `symbol` | Your code calls the vulnerable symbol | "Your code is affected by N vulnerabilities" |

By default this action fails on **any** level, including findings govulncheck itself classifies as not affecting your code. `fail-on` narrows that:

```yaml
- uses: temporalio/public-actions/golang/govulncheck@main
  with:
    fail-on: symbol   # only block when your code actually calls the vulnerable symbol
```

Findings below the threshold don't vanish. They get their own job-summary section so the exposure stays visible, they just don't block.

**When this matters.** [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) covers `golang.org/x/crypto/openpgp` at every version. Repos that only require `golang.org/x/crypto` transitively, without importing `openpgp`, hit a module-level finding with no fix and no reachable code. `fail-on: symbol` resolves it with no ignore entry to maintain.

**Choosing a level.** `symbol` matches what govulncheck's text output treats as actionable, and is the tightest signal-to-noise. It is also the loosest gate: a vulnerability becomes blocking only once something calls it, so a dependency that adds a vulnerable call path in a later release won't be flagged until that path is reachable from your code. `module` is the most conservative and stays the default. Note the analysis is static, so `symbol` can miss reflection- and codegen-driven call paths.

## Ignoring a vulnerability

Some findings can't be fixed by upgrading. The clearest case is a package that upstream has abandoned with no fixed version, such as [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) (`golang.org/x/crypto/openpgp`), where no dependency bump will ever clear the finding.

Add a `.govulncheck-ignore` file to the repo root:

```
# golang.org/x/crypto/openpgp is unmaintained upstream with no fixed version.
# Reported at module level only — nothing in our build imports the package.
GO-2026-5932

GO-2025-1234  # reachable but low risk; tracked in SEC-1234
```

- One `GO-YYYY-NNNN` per line. Blank lines are skipped, `#` starts a comment.
- The comment block directly above an entry, or a trailing comment on the entry line, is captured as that entry's **reason** and rendered in the job summary. A blank line detaches a comment block from the entry below it, so a file header isn't mistaken for a justification.
- A malformed line fails the job. An ignore file that silently misparses would weaken the check without anyone noticing.

See [`.govulncheck-ignore.example`](.govulncheck-ignore.example) for a fuller template.

**Guardrails.** The ignore file is read from the head tree, so a PR can add an entry and unblock itself. That's necessary (otherwise there'd be no way to land a suppression), but it means the file is the security boundary: add it to `CODEOWNERS` if suppressions need review. The action also warns when an entry no longer matches anything in the scan, so stale suppressions surface instead of accumulating.

## Job summary

The action writes a GitHub job summary with:
- **New vulnerabilities** — not present on the base branch (blocks the PR)
- **Resolved vulnerabilities** — were on the base branch but are now fixed
- **Pre-existing vulnerabilities** — present on both branches (does not block)
- **Ignored vulnerabilities** — matched an ignore-file entry, shown with the reason (does not block)
- **Below the threshold** — reported at a scan level under `fail-on` (does not block)

Each vulnerability links to [pkg.go.dev/vuln](https://pkg.go.dev/vuln/) with the affected module, current version, and fix version.

## Prerequisites

- Go must be set up before calling this action (e.g., via [actions/setup-go](https://github.com/actions/setup-go))
- `jq` must be available on the runner (pre-installed on GitHub-hosted runners)

## Tests

Reporting logic is covered by pure bash/jq tests that craft scan JSON directly, with no govulncheck install needed:

```bash
bash golang/govulncheck/tests/ignorelist-test.sh
bash golang/govulncheck/tests/fail-on-test.sh
```

Shared fixtures and assertions live in `tests/lib.sh`.
