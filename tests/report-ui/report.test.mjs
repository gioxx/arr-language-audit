import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const root = fileURLToPath(new URL('../../', import.meta.url));
const row = (title, verdict = 'CONFIRMED_NOT_ITALIAN', path = `/media/${title}.mkv`) => ({
  App: 'sonarr', Title: title, Year: '2026', Episode: '',
  DeclaredAudioLanguages: '', DetectedLanguage: 'en', Confidence: '0.91',
  Verdict: verdict, Path: path,
});

function page(t, rows, clipboard) {
  const html = execFileSync(process.env.PYTHON_BIN || 'python3', ['-c',
    'import json,sys;sys.path.insert(0,"verify");import report;print(report.build_html(json.load(sys.stdin),"fixture.csv"))',
  ], { cwd: root, input: JSON.stringify(rows), encoding: 'utf8' });
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', // Only execute the locally generated product report.
    beforeParse(window) {
      Object.defineProperty(window.navigator, 'clipboard', { value: clipboard });
    },
  });
  t.after(() => dom.window.close());
  return dom.window;
}

const settle = () => new Promise(resolve => setImmediate(resolve));

test('unknown verdicts matching Object prototype names remain visible and filterable', t => {
  const w = page(t, [row('one', '__proto__'), row('two', 'constructor')]);
  const chips = [...w.document.querySelectorAll('#chips [data-verdict]')];
  assert.deepEqual(chips.map(c => c.dataset.verdict).sort(), ['__proto__', 'constructor']);
  assert.ok(chips.every(c => c.textContent.endsWith('1')));
  assert.deepEqual([...w.document.querySelectorAll('#body .badge')].map(c => c.textContent).sort(),
    ['__proto__', 'constructor']);
});

test('filters and sorting are native focusable buttons with announced state', t => {
  const w = page(t, [row('Bravo'), row('Alpha', 'LOW_CONFIDENCE')]);
  const d = w.document;
  const filter = d.querySelector('#chips [data-verdict="LOW_CONFIDENCE"]');
  assert.equal(filter.tagName, 'BUTTON');
  assert.equal(filter.getAttribute('aria-pressed'), 'true');
  filter.click();
  assert.equal(filter.getAttribute('aria-pressed'), 'false');
  assert.equal(d.querySelectorAll('#body tr').length, 1);
  filter.click();
  const sort = d.querySelector('th[data-key="Title"] button');
  assert.ok(sort);
  sort.click();
  assert.equal(sort.closest('th').getAttribute('aria-sort'), 'ascending');
  assert.equal(d.querySelector('#body tr td:nth-child(2)').textContent, 'Alpha');
  sort.click();
  assert.equal(d.querySelector('#body tr td:nth-child(2)').textContent, 'Bravo');
});

test('copy uses the current search even before debounce and deduplicates episode paths', async t => {
  let copied;
  const w = page(t, [row('Alpha'), row('Alpha second episode', 'LOW_CONFIDENCE', '/media/Alpha.mkv'), row('Bravo')],
    { writeText: async text => { copied = text; } });
  const q = w.document.getElementById('q');
  q.value = 'Alpha';
  q.dispatchEvent(new w.Event('input'));
  w.document.getElementById('copyPaths').click();
  await settle();
  assert.equal(copied, '/media/Alpha.mkv');
  assert.match(w.document.getElementById('copyStatus').textContent, /Copied 1/);
});

for (const unavailable of [true, false]) {
  test(`clipboard ${unavailable ? 'absent' : 'denied'} exposes the actual text for manual copying`, async t => {
    const w = page(t, [row('Alpha')], unavailable ? undefined : {
      writeText: async () => { throw new Error('NotAllowedError'); },
    });
    w.document.getElementById('copyPaths').click();
    await settle();
    const manual = w.document.getElementById('manualCopy');
    assert.ok(manual);
    assert.equal(manual.hidden, false);
    const text = manual.querySelector('textarea');
    assert.equal(text.value, '/media/Alpha.mkv');
    assert.equal(text.selectionEnd - text.selectionStart, text.value.length);
    assert.doesNotMatch(w.document.getElementById('copyStatus').textContent, /^Copied/);
  });
}

test('row cap and show all preserve the full filtered copy set', async t => {
  let copied;
  const w = page(t, Array.from({ length: 2001 }, (_, i) => row(`Film ${i}`)), {
    writeText: async text => { copied = text; },
  });
  const d = w.document;
  assert.equal(d.querySelectorAll('#body tr').length, 2000);
  assert.equal(d.getElementById('showAll').hidden, false);
  assert.equal(d.getElementById('copyPaths').textContent, 'Copy filtered paths');
  d.getElementById('copyPaths').click();
  await settle();
  assert.equal(copied.split('\n').length, 2001);
  d.getElementById('showAll').click();
  assert.equal(d.querySelectorAll('#body tr').length, 2001);
  assert.equal(d.getElementById('showAll').hidden, true);
});
