#!/usr/bin/env python3
"""Regression-test runner for the Opengrep rules in ../rules.

Each rule file `rules/<stem>.yml` is paired (by filename stem) with a fixture
file under this `tests/` tree. The fixture is a real workflow / action / source
file annotated inline:

    # ruleid: <rule-id>   the NEXT line MUST produce a finding for <rule-id>
    # ok: <rule-id>       the NEXT line must NOT produce a finding

The runner invokes `<engine> --test` (Opengrep in CI, Semgrep locally — same
interface) once per rule and aggregates the results. It exits non-zero if any
test fails OR any rule has no fixture, so every rule must ship with tests.

Usage:
    python3 sast/opengrep/tests/run.py
    OPENGREP_TEST_BIN=semgrep python3 sast/opengrep/tests/run.py
"""
# `from __future__ import annotations` lets the `X | None` annotations below
# run on the Python 3.9 that ships with macOS as well as the 3.12 container.
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
RULES_DIR = TESTS_DIR.parent / "rules"
REPO_ROOT = TESTS_DIR.parents[2]
GHA = os.environ.get("GITHUB_ACTIONS") == "true"


@dataclass
class RuleResult:
    """Outcome of testing one rule; `passed` is true iff there are no failures."""

    name: str
    failures: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.failures


def pick_engine() -> str:
    """Pick the test engine: $OPENGREP_TEST_BIN, else opengrep, else semgrep."""
    if override := os.environ.get("OPENGREP_TEST_BIN"):
        # Validate the override now so a typo fails clearly here instead of as a
        # FileNotFoundError from the first subprocess.run. shutil.which accepts a
        # bare command name or an explicit path.
        if not shutil.which(override):
            sys.exit(f"error: OPENGREP_TEST_BIN={override!r} not found on PATH")
        return override
    for candidate in ("opengrep", "semgrep"):
        if shutil.which(candidate):
            return candidate
    sys.exit("error: neither 'opengrep' nor 'semgrep' found on PATH "
             "(set OPENGREP_TEST_BIN to override)")


def rule_files() -> list[Path]:
    """Return the rule files under rules/, sorted for stable output."""
    return sorted(p for p in RULES_DIR.iterdir() if p.suffix in {".yml", ".yaml"})


def fixture_index() -> dict[str, Path]:
    """Map each fixture's filename stem to its path (one pass over tests/).

    Pairing is by stem, so two fixtures sharing a stem would be ambiguous and
    could silently mis-pair a rule. Fail loudly instead of guessing.
    """
    index: dict[str, Path] = {}
    for path in sorted(TESTS_DIR.rglob("*")):
        if path.is_file() and path.name != "run.py" and path.name.lower() != "readme.md":
            if path.stem in index:
                sys.exit(f"error: duplicate fixture stem '{path.stem}': "
                         f"{rel(index[path.stem])} and {rel(path)} — stems must be unique")
            index[path.stem] = path
    return index


def rel(path: Path | str) -> str:
    """Return *path* relative to the repo root (for display and annotations)."""
    return os.path.relpath(path, REPO_ROOT)


def annotate(level: str, file: str, line: int, message: str) -> None:
    """Emit a GitHub Actions annotation for *file*:*line* (no-op outside CI)."""
    # `::level file=...,line=...::msg` is a GitHub Actions workflow command — it
    # surfaces the message inline on the PR diff and checks UI. See:
    # https://docs.github.com/actions/reference/workflow-commands-for-github-actions
    if GHA:
        print(f"::{level} file={rel(file)},line={line}::{message}")


def run_one(engine: str, rule: Path, fixture: Path) -> list[str]:
    """Run `<engine> --test` for one rule; return failure messages (empty == pass)."""
    proc = subprocess.run(
        [engine, "--test", "--json", "--config", str(rule), str(fixture)],
        capture_output=True, text=True, check=False,
    )
    if not proc.stdout.strip():
        last = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "?"
        return [f"engine produced no output (exit {proc.returncode}): {last}"]
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return [f"could not parse --test --json output (exit {proc.returncode})"]

    failures = [f"rule config error: {cfg}" for cfg in data.get("config_with_errors", [])]

    checks_seen = 0
    for info in data.get("results", {}).values():
        for rule_id, check in info.get("checks", {}).items():
            checks_seen += 1
            if check.get("passed"):
                continue
            for fpath, lines in check.get("matches", {}).items():
                expected = set(lines.get("expected_lines", []))
                reported = set(lines.get("reported_lines", []))
                for line in sorted(expected - reported):
                    message = f"{rule_id}: expected a finding here but none was produced"
                    failures.append(f"{rel(fpath)}:{line}  {message}")
                    annotate("error", fpath, line, message)
                for line in sorted(reported - expected):
                    message = f"{rule_id}: unexpected finding (false positive) — annotate with '# ok:' if intended"
                    failures.append(f"{rel(fpath)}:{line}  {message}")
                    annotate("error", fpath, line, message)

    # A fixture with no '# ruleid:'/'# ok:' annotations produces no checks; that
    # is a vacuous (useless) test, not a pass.
    if checks_seen == 0 and not failures:
        failures.append(f"{rel(fixture)}: no test cases — fixture has no '# ruleid:'/'# ok:' annotations")

    if not failures and proc.returncode != 0:
        failures.append(f"engine reported failure (exit {proc.returncode})")
    return failures


def write_step_summary(path: Path, engine: str, results: list[RuleResult], passed: int) -> None:
    """Append a Markdown results table to the GitHub Actions step summary file."""
    lines = [
        "## Opengrep rule regression tests\n",
        f"Engine: `{engine}` — **{passed}/{len(results)}** rules passed\n",
        "| Rule | Result |",
        "|---|---|",
        *(f"| `{r.name}` | {'✅ pass' if r.passed else '❌ fail'} |" for r in results),
    ]
    with path.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main() -> int:
    """Run every rule against its fixture; return the exit code (0 = all passed)."""
    engine = pick_engine()
    rules = rule_files()
    if not rules:
        sys.exit(f"error: no rule files found in {rel(RULES_DIR)}")
    fixtures = fixture_index()

    print(f"Running rule regression tests with '{engine}'\n")
    results: list[RuleResult] = []
    for rule in rules:
        result = RuleResult(rule.name)
        fixture = fixtures.get(rule.stem)
        if fixture is None:
            result.failures.append(
                f"no fixture found (expected a file named '{rule.stem}.*' under {rel(TESTS_DIR)})")
        else:
            result.failures.extend(run_one(engine, rule, fixture))
        results.append(result)

    passed = sum(r.passed for r in results)
    for result in results:
        print(f"  [{'PASS' if result.passed else 'FAIL'}] {result.name}")
        for failure in result.failures:
            print(f"         {failure}")
    print(f"\n{passed}/{len(results)} rules passed")

    if GHA and (summary_path := os.environ.get("GITHUB_STEP_SUMMARY")):
        write_step_summary(Path(summary_path), engine, results, passed)

    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
