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

    test('matches headings case-insensitively', () => {
      assert.deepEqual(findViolations('## WHAT CHANGED?\n', SECTIONS), [{ kind: 'empty-section', header: '## What changed?' }]);
    });
  });
});

describe('run', () => {
  // Runs the github-script entry point against a fake PR and returns the failure message, if any.
  async function runWith(body, requiredSections) {
    let failure = null;
    await run({
      github: { rest: { pulls: { get: async () => ({ data: { body } }) } } },
      context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 1 } } },
      core: { setFailed: msg => { failure = msg; }, info: () => {} },
    }, { requiredSections });
    return failure;
  }

  test('fails the step and lists the problems', async () => {
    assert.equal(
      await runWith('## What changed?\n\n## Why?\n_Tell us._', '## What changed?\n## Why?'),
      [
        'PR description must not contain placeholders or empty sections:',
        '- Line 4: Placeholder "_Tell us._"',
        '- Section "## What changed?" appears to be empty.',
      ].join('\n'),
    );
  });

  test('passes a good description', async () => {
    assert.equal(await runWith('## Why?\nBecause.', '## Why?'), null);
  });
});

describe('formatViolation', () => {
  test('formats each kind', () => {
    assert.equal(formatViolation({ kind: 'placeholder', line: 4, text: '_x_' }), 'Line 4: Placeholder "_x_"');
    assert.equal(formatViolation({ kind: 'empty-section', header: '## Why?' }), 'Section "## Why?" appears to be empty.');
  });
});

describe('parseSections', () => {
  test('parses the required-sections input', () => {
    assert.deepEqual(parseSections('## What changed?\r\n  ## Why?  \n\n'), ['## What changed?', '## Why?']);
    assert.deepEqual(parseSections(undefined), []);
  });
});
