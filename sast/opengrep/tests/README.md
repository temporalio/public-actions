# Opengrep rule regression tests

Every rule in [`../rules`](../rules) has a fixture here that pins its behavior:
which lines it **must** flag and which it **must not**. The
[`Opengrep rule tests`](../../../.github/workflows/test-opengrep-rules.yml)
workflow runs them on any PR that touches `sast/opengrep/rules/**` or
`sast/opengrep/tests/**`, so rule changes can't silently regress.

## Run locally

### In Docker (no host install — mirrors CI)

[`Dockerfile`](Dockerfile) installs the same pinned Opengrep binary the
workflow uses; the repo is mounted at runtime, so edits to rules/fixtures take
effect without rebuilding. Run from the repo root:

```bash
docker build --platform linux/amd64 -t opengrep-rules sast/opengrep/tests
docker run  --rm --platform linux/amd64 -v "$PWD:/work" opengrep-rules            # rule tests
docker run  --rm --platform linux/amd64 -v "$PWD:/work" opengrep-rules \
    opengrep scan --no-rewrite-rule-ids --config sast/opengrep/rules/ .           # full scan
```

`--platform linux/amd64` matches the GitHub-hosted runner (1:1). On Apple
Silicon that runs under emulation; for a faster native image, drop the
`--platform` flags — BuildKit's `TARGETARCH` selects the arm64 binary
automatically.

### On the host (if opengrep or semgrep is installed)

```bash
python3 sast/opengrep/tests/run.py            # uses opengrep if installed, else semgrep
OPENGREP_TEST_BIN=semgrep python3 sast/opengrep/tests/run.py   # force an engine
```

Exit code is non-zero if any test fails or any rule is missing a fixture.

## How pairing works

A rule file `rules/<stem>.yml` is paired with the fixture under this directory
whose filename **stem** matches `<stem>` — e.g.:

| Rule | Fixture |
|---|---|
| `rules/gha-run-injection.yml` | `tests/.github/workflows/gha-run-injection.yaml` |
| `rules/go-zipslip.yml` | `tests/go/go-zipslip.go` |

Fixtures live at realistic paths (`.github/workflows/…`, `…/action.yml`, `*.go`)
so each rule's `paths:` / `languages:` filter applies exactly as in production.
Every rule **must** have a fixture — the runner fails otherwise.

## Annotation syntax

Inside a fixture, annotate the line *immediately above* the line you expect a
result on (for a multi-line `run: |` block, that's the `run:` line itself):

```yaml
# ruleid: <rule-id>    # the next line MUST produce a finding for <rule-id>
- run: echo ${{ github.event.pull_request.title }}

# ok: <rule-id>        # the next line must NOT produce a finding
- run: echo ${{ github.sha }}
```

> Do **not** write the literal tokens `# ruleid:` / `# ok:` in explanatory
> comments — the engine parses every occurrence as an annotation.

## Add or change a test

- **New case for an existing rule:** add lines to that rule's fixture with a
  `# ruleid:` or `# ok:` annotation. Re-run `run.py`.
- **New rule:** add `rules/<stem>.yml`, then add a fixture whose stem is
  `<stem>` at a path its filters accept (a workflow under
  `tests/.github/workflows/`, an `action.yml`, a `*.go` file, …).
- **Remove a case:** delete the annotated lines (or the whole fixture if the
  rule is removed).

## Notes

- These fixtures contain intentional vulnerabilities. The repo-root
  [`.semgrepignore`](../../../.semgrepignore) keeps them out of this repo's own
  Opengrep/Semgrep scans; `--test` targets them explicitly and is unaffected.
- The `security.gha.run-shell-injection-inputs` fixture also encodes the
  decision to keep that rule strict on constant-result ternaries (see the
  comments in that fixture).
