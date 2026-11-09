// Returns the problems found in a pull request description; empty when it passes.
// Each is { kind: 'placeholder', line, text }, { kind: 'empty-section', header },
// or { kind: 'missing-section', header } (only with requireSections).
function findViolations(body, requiredSections, { requireSections = false } = {}) {
  const lines = (body || '').split(/\r?\n/);

  let violations = [];

  // Detect placeholder lines: entire line is wrapped in single underscores (_..._).
  // Lines of only underscores (a horizontal rule) and __bold__ lines are not placeholders.
  lines.forEach((line, idx) => {
    const text = line.trim();
    if (/^_[^_](.*[^_])?_$/.test(text) && !/^(_\s*){3,}$/.test(text)) {
      violations.push({ kind: 'placeholder', line: idx + 1, text });
    }
  });

  // Detect empty sections: a required header followed by no meaningful content.
  // With requireSections, a required header that is absent is a violation too.
  requiredSections.forEach((header) => {
    const idx = lines.findIndex(line => line.trim().toLowerCase() === header.toLowerCase());
    if (idx === -1) {
      if (requireSections) {
        violations.push({ kind: 'missing-section', header });
      }
    } else {
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
    case 'missing-section':
      return `Section "${v.header}" is missing.`;
  }
}

// Splits the newline-separated required-sections input into headings.
function parseSections(input) {
  return (input || '')
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
}

// Entry point for actions/github-script. requiredSections and requireSections are the raw
// required-sections and require-sections inputs.
async function run({ github, context, core }, { requiredSections, requireSections }) {
  // Events like merge_group and push have no pull request to check.
  if (!context.payload.pull_request) {
    core.info(`No pull request in the ${context.eventName} event; skipping.`);
    return;
  }

  // Re-read the PR so a re-run sees the latest description, not the triggering event's.
  const pr = await github.rest.pulls.get({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.payload.pull_request.number
  });

  const violations = findViolations(pr.data.body, parseSections(requiredSections), {
    requireSections: requireSections === 'true',
  });

  if (violations.length > 0) {
    // The failure message becomes the check's annotation, so list the problems in it.
    core.setFailed([
      'PR description must not contain placeholders or empty or missing sections:',
      ...violations.map(v => `- ${formatViolation(v)}`),
    ].join('\n'));
  } else {
    core.info("✅ PR description passed all checks.");
  }
}

module.exports = { run, findViolations, formatViolation, parseSections };
