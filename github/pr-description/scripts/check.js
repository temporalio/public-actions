// Adapted from temporalio/temporal's check-pr-placeholders workflow:
// https://github.com/temporalio/temporal/blob/122ed53e019210326b2dde267fb3c3fe4ab83b2a/.github/workflows/check-pr-placeholders.yml

// Returns the problems found in a pull request description; empty when it passes.
// Each is { kind: 'placeholder', line, text } or { kind: 'empty-section', header }.
function findViolations(body, requiredSections) {
  const lines = (body || '').split(/\r?\n/);

  let violations = [];

  // Detect placeholder lines: entire line starts and ends with _
  lines.forEach((line, idx) => {
    if (/^_.*_$/.test(line.trim())) {
      violations.push({ kind: 'placeholder', line: idx + 1, text: line.trim() });
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
        violations.push({ kind: 'empty-section', header });
      }
    }
  });

  return violations;
}

// Describes a violation for the check's output.
function formatViolation(v) {
  switch (v.kind) {
    case 'placeholder':
      return `Line ${v.line}: Placeholder "${v.text}"`;
    case 'empty-section':
      return `Section "${v.header}" appears to be empty.`;
  }
}

// Splits the newline-separated required-sections input into headings.
function parseSections(input) {
  return (input || '')
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
}

// Entry point for actions/github-script. requiredSections is the raw required-sections input.
async function run({ github, context, core }, { requiredSections }) {
  // Re-read the PR so a re-run sees the latest description, not the triggering event's.
  const pr = await github.rest.pulls.get({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.payload.pull_request.number
  });

  const violations = findViolations(pr.data.body, parseSections(requiredSections));

  if (violations.length > 0) {
    // The failure message becomes the check's annotation, so list the problems in it.
    core.setFailed([
      'PR description must not contain placeholders or empty sections:',
      ...violations.map(v => `- ${formatViolation(v)}`),
    ].join('\n'));
  } else {
    core.info("✅ PR description passed all checks.");
  }
}

module.exports = { run, findViolations, formatViolation, parseSections };
