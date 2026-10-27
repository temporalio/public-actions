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

module.exports = { findViolations, parseSections };
