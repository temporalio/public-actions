const test = require('node:test');
const assert = require('node:assert/strict');
const { findViolations, parseSections } = require('../scripts/check.js');

const SECTIONS = ['## What changed?', '## Why?', '## How did you test it?'];

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

test('flags placeholder lines in any section', () => {
  const body = [
    '## What changed?',
    'Added a thing.',
    '## Potential risks',
    '_Any change is risky._',
  ].join('\n');
  assert.deepEqual(findViolations(body, SECTIONS), ['Line 4: Placeholder "_Any change is risky._"']);
});

test('does not flag inline emphasis', () => {
  const body = '## What changed?\nAdded _one_ thing, not _two_ things.';
  assert.deepEqual(findViolations(body, SECTIONS), []);
});

test('flags a required section followed by another heading', () => {
  const body = '## What changed?\n\n## Why?\nBecause.';
  assert.deepEqual(findViolations(body, SECTIONS), ['Section "## What changed?" appears to be empty.']);
});

test('flags a required section at the end of the description', () => {
  const body = '## What changed?\nAdded a thing.\n\n## Why?\n\n';
  assert.deepEqual(findViolations(body, SECTIONS), ['Section "## Why?" appears to be empty.']);
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
  assert.deepEqual(findViolations('## WHAT CHANGED?\n', SECTIONS), [
    'Section "## What changed?" appears to be empty.',
  ]);
});

test('handles CRLF line endings', () => {
  const body = '## What changed?\r\n_placeholder_\r\n## Why?\r\nBecause.';
  assert.deepEqual(findViolations(body, SECTIONS), ['Line 2: Placeholder "_placeholder_"']);
});

test('passes an empty description', () => {
  assert.deepEqual(findViolations(null, SECTIONS), []);
});

test('parses the required-sections input', () => {
  assert.deepEqual(parseSections('## What changed?\r\n  ## Why?  \n\n'), ['## What changed?', '## Why?']);
  assert.deepEqual(parseSections(undefined), []);
});
