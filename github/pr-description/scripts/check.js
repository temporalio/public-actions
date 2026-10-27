// Adapted from temporalio/temporal's check-pr-placeholders workflow:
// https://github.com/temporalio/temporal/blob/122ed53e019210326b2dde267fb3c3fe4ab83b2a/.github/workflows/check-pr-placeholders.yml

// Returns the problems found in a pull request description; empty when it passes.
function findViolations(body, requiredSections) {
  const lines = (body || '').split(/\r?\n/);

  let violations = [];

  // Detect placeholder lines: entire line starts and ends with _
  lines.forEach((line, idx) => {
    if (/^_.*_$/.test(line.trim())) {
      violations.push(`Line ${idx + 1}: Placeholder "${line.trim()}"`);
    }
  });

  // Detect empty sections: a required header followed by no meaningful content
  requiredSections.forEach((header) => {
    const idx = lines.findIndex(line => line.trim().toLowerCase() === header.toLowerCase());
    if (idx !== -1) {
      let contentIdx = idx + 1;
      while (contentIdx < lines.length && lines[contentIdx].trim() === '') {
        contentIdx++;
      }
      const nextLine = lines[contentIdx]?.trim();
      if (!nextLine || /^## /.test(nextLine)) {
        violations.push(`Section "${header}" appears to be empty.`);
      }
    }
  });

  return violations;
}

// Splits the newline-separated required-sections input into headings.
function parseSections(input) {
  return (input || '')
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
}

// Entry point for actions/github-script.
async function run({ github, context, core }) {
  // Re-read the PR so a re-run sees the latest description, not the triggering event's.
  const pr = await github.rest.pulls.get({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.payload.pull_request.number
  });

  const violations = findViolations(pr.data.body, parseSections(process.env.REQUIRED_SECTIONS));

  if (violations.length > 0) {
    console.log("❌ PR description issues found:");
    violations.forEach(v => console.log(`- ${v}`));
    core.setFailed(`PR description must not contain placeholders or empty sections.`);
  } else {
    console.log("✅ PR description passed all checks.");
  }
}

module.exports = { run, findViolations, parseSections };
