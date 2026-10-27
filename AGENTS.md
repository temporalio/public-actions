# Agent guidelines

Each action lives in `<area>/<name>/` with an `action.yml` and a `README.md`; `sast/opengrep` is the reference layout.

## Scripts over YAML

Keep `action.yml` thin: inputs, outputs, and steps that call a script in `scripts/`. Logic in a script can be run locally and unit tested; logic inlined in a `run:` or github-script `script:` block can only be tested by running the workflow.

- Shell logic goes in a Bash script; JavaScript for `actions/github-script` goes in a module the `script:` block `require`s from `${{ github.action_path }}`.
- Pass inputs and event data to scripts through `env`, and read them there. Keep `${{ }}` expressions out of `run:` and `script:` bodies, where they become a script-injection vector.

## Tests

Every script ships with tests in `tests/`, and a `.github/workflows/test-<name>-action.yml` that runs them on pull requests touching the action (see `test-opengrep-action.yml`).

- Use test tooling that needs no install: plain Bash for shell scripts, Node's built-in `node:test` for JavaScript.
- Test the logic as pure functions; keep the I/O at the edge (GitHub API calls, `core.setFailed`) thin enough to cover with a fake.
