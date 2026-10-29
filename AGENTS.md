# Agent guidelines

Each action lives in `<area>/<name>/` with an `action.yml` and a `README.md`; `sast/opengrep` shows the directory layout (`scripts/`, `tests/`).

- Keep `action.yml` thin: inputs, outputs, and steps that call a script in `scripts/`.
- New or changed scripts ship with tests in `tests/`, and a `.github/workflows/test-<name>-action.yml` that runs them on pull requests touching the action.
- Write tests with tooling that needs no install: plain Bash for shell scripts, Node's built-in `node:test` for JavaScript.
- Test the logic as pure functions; keep the I/O at the edge (e.g. GitHub API calls) thin enough to cover with a fake.
- Pass inputs and event data to scripts through `env`, and read them there.
- Keep `${{ }}` expressions out of `run:` and `script:` bodies, where they become a script-injection vector.
