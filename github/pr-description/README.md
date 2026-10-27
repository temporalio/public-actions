# PR description

Fails a pull request whose description still contains template placeholder lines (a whole line wrapped in `_..._`) or leaves a required section empty. Pairs with a `.github/PULL_REQUEST_TEMPLATE.md` whose guidance is written as `_placeholder_` lines.

## Usage

```yaml
name: PR description

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  pull-requests: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: temporalio/public-actions/github/pr-description@main
```

Include `edited` in the trigger types so the check re-runs when the description is fixed.

## Inputs

| Input | Default | Description |
|---|---|---|
| `required-sections` | `## What changed?`, `## Why?`, `## How did you test it?` | Newline-separated headings that must have content below them. Headings missing from the description are ignored. |
| `github-token` | `${{ github.token }}` | Token used to read the pull request. Needs `pull-requests: read`. |
