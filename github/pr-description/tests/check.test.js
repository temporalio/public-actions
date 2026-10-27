const { describe, test } = require('node:test');
const assert = require('node:assert/strict');
const { run, findViolations, formatViolation, parseSections } = require('../scripts/check.js');

const SECTIONS = ['## What changed?', '## Why?', '## How did you test it?'];

describe('findViolations', () => {
  test('passes a filled-in description', () => {
    const body = [
      '## What changed?',
      'Added a thing.',
      '',
      '## Why?',
      'Because.',
      '',
      '## How did you test it?',
      '- [x] added new test(s)',
    ].join('\n');
    assert.deepEqual(findViolations(body, SECTIONS), []);
  });

  test('passes an empty description', () => {
    assert.deepEqual(findViolations(null, SECTIONS), []);
  });

  describe('placeholders', () => {
    test('flags placeholder lines in any section', () => {
      const body = [
        '## What changed?',
        'Added a thing.',
        '## Potential risks',
        '_Any change is risky._',
      ].join('\n');
      assert.deepEqual(findViolations(body, SECTIONS), [{ kind: 'placeholder', line: 4, text: '_Any change is risky._' }]);
    });

    test('does not flag inline emphasis', () => {
      const body = '## What changed?\nAdded _one_ thing, not _two_ things.';
      assert.deepEqual(findViolations(body, SECTIONS), []);
    });

    test('does not flag a horizontal rule', () => {
      const body = '## What changed?\nAdded a thing.\n___\n_ _ _\n';
      assert.deepEqual(findViolations(body, SECTIONS), []);
    });

    test('does not flag a bold line', () => {
      const body = '## What changed?\n__Important:__ read this.\n__Everything here is bold__';
      assert.deepEqual(findViolations(body, SECTIONS), []);
    });

    test('flags a one-character placeholder', () => {
      assert.deepEqual(findViolations('_x_', SECTIONS), [{ kind: 'placeholder', line: 1, text: '_x_' }]);
    });

    test('handles CRLF line endings', () => {
      const body = '## What changed?\r\n_placeholder_\r\n## Why?\r\nBecause.';
      assert.deepEqual(findViolations(body, SECTIONS), [{ kind: 'placeholder', line: 2, text: '_placeholder_' }]);
    });
  });

  describe('required sections', () => {
    test('flags a required section followed by another heading', () => {
      const body = '## What changed?\n\n## Why?\nBecause.';
      assert.deepEqual(findViolations(body, SECTIONS), [{ kind: 'empty-section', header: '## What changed?' }]);
    });

    test('flags a required section at the end of the description', () => {
      const body = '## What changed?\nAdded a thing.\n\n## Why?\n\n';
      assert.deepEqual(findViolations(body, SECTIONS), [{ kind: 'empty-section', header: '## Why?' }]);
    });

    test('treats a lower-level heading as content', () => {
      const body = '## What changed?\n### Details\n';
      assert.deepEqual(findViolations(body, SECTIONS), []);
    });

    test('ignores missing required sections', () => {
      assert.deepEqual(findViolations('Just a sentence.', SECTIONS), []);
    });

    test('ignores empty sections that are not required', () => {
      const body = '## What changed?\nAdded a thing.\n## Notes\n';
      assert.deepEqual(findViolations(body, SECTIONS), []);
    });

    test('flags missing required sections with requireSections', () => {
      const body = '## What changed?\nAdded a thing.';
      assert.deepEqual(findViolations(body, SECTIONS, { requireSections: true }), [
        { kind: 'missing-section', header: '## Why?' },
        { kind: 'missing-section', header: '## How did you test it?' },
      ]);
    });

    test('flags an empty description with requireSections', () => {
      assert.deepEqual(findViolations(null, ['## Why?'], { requireSections: true }), [
        { kind: 'missing-section', header: '## Why?' },
      ]);
    });

    test('matches headings case-insensitively', () => {
      assert.deepEqual(findViolations('## WHAT CHANGED?\n', SECTIONS), [{ kind: 'empty-section', header: '## What changed?' }]);
    });
  });
});

describe('run', () => {
  // Runs the github-script entry point against a fake PR and returns the failure message, if any.
  async function runWith(body, requiredSections, { requireSections = 'false', payload } = {}) {
    let failure = null;
    await run({
      github: { rest: { pulls: { get: async () => ({ data: { body } }) } } },
      context: {
        eventName: 'pull_request',
        repo: { owner: 'o', repo: 'r' },
        payload: payload || { pull_request: { number: 1 } },
      },
      core: { setFailed: msg => { failure = msg; }, info: () => {} },
    }, { requiredSections, requireSections });
    return failure;
  }

  test('fails the step and lists the problems', async () => {
    assert.equal(
      await runWith('## What changed?\n\n## Why?\n_Tell us._', '## What changed?\n## Why?'),
      [
        'PR description must not contain placeholders or empty or missing sections:',
        '- Line 4: Placeholder "_Tell us._"',
        '- Section "## What changed?" appears to be empty.',
      ].join('\n'),
    );
  });

  test('passes a good description', async () => {
    assert.equal(await runWith('## Why?\nBecause.', '## Why?'), null);
  });

  test('fails an empty description when require-sections is true', async () => {
    assert.equal(
      await runWith('', '## Why?', { requireSections: 'true' }),
      'PR description must not contain placeholders or empty or missing sections:\n- Section "## Why?" is missing.',
    );
  });

  test('passes an empty description by default', async () => {
    assert.equal(await runWith('', '## Why?'), null);
  });

  test('skips events without a pull request', async () => {
    assert.equal(await runWith('_placeholder_', '## Why?', { payload: {} }), null);
  });
});

describe('formatViolation', () => {
  test('formats each kind', () => {
    assert.equal(formatViolation({ kind: 'placeholder', line: 4, text: '_x_' }), 'Line 4: Placeholder "_x_"');
    assert.equal(formatViolation({ kind: 'empty-section', header: '## Why?' }), 'Section "## Why?" appears to be empty.');
    assert.equal(formatViolation({ kind: 'missing-section', header: '## Why?' }), 'Section "## Why?" is missing.');
  });
});

describe('parseSections', () => {
  test('parses the required-sections input', () => {
    assert.deepEqual(parseSections('## What changed?\r\n  ## Why?  \n\n'), ['## What changed?', '## Why?']);
    assert.deepEqual(parseSections(undefined), []);
  });
});
