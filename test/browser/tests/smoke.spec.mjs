import { test, expect } from '@playwright/test';
import { gotoIde, bootRepl, evalRepl, loadAndRun, canvasCount, status } from '../lib/ide.mjs';

// One worker boot per test (process-per-run, like the IDE). These exercise the
// actual ide.html surface end to end: cross-origin isolation, the SAB stdin/
// stdout rings, the submission REPL, racket/draw + the canvas blit channel, and
// the web-repl helpers.

test('REPL: arithmetic and a collection require', async ({ page }) => {
  await gotoIde(page);
  await bootRepl(page);
  expect(await evalRepl(page, '(+ 4 5)')).toContain('9');
  expect(await evalRepl(page, '(require racket/list) (range 5)')).toContain('(0 1 2 3 4)');
  expect(await status(page)).toBe('Running');
});

test('module: Run prints the program stdout', async ({ page }) => {
  await gotoIde(page);
  const out = await loadAndRun(
    page,
    '#lang racket/base\n(for ([i (in-range 3)]) (displayln (* i i)))\n',
  );
  expect(out.split(/\s+/).filter(Boolean)).toEqual(['0', '1', '4']);
});

test('module: REPL lands in the program namespace (DrRacket-style)', async ({ page }) => {
  await gotoIde(page);
  await loadAndRun(page, '#lang racket/base\n(define answer 42)\n');
  // After Run, definitions are in scope at the REPL.
  expect(await evalRepl(page, 'answer')).toContain('42');
});

test('racket/draw renders an inline canvas via web-repl/display-bm', async ({ page }) => {
  await gotoIde(page);
  await bootRepl(page);
  await evalRepl(page, '(require racket/draw web-repl/display-bm)');
  const before = await canvasCount(page);
  await evalRepl(
    page,
    '(define bm (make-bitmap 32 32))' +
      '(define dc (send bm make-dc))' +
      "(send dc set-brush \"red\" 'solid)" +
      '(send dc draw-ellipse 1 1 30 30)' +
      '(display-bm bm)',
  );
  await expect.poll(() => canvasCount(page)).toBeGreaterThan(before);
});
