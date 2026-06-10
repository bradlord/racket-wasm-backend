import { test, expect } from '@playwright/test';
import { gotoIde, bootRepl, evalRepl } from '../lib/ide.mjs';

// Boot validation for the cross-SDK consume path (`racket build/main.rkt
// cross-install`): a package cross-compiled to tpb32l and folded into the
// runtime's share.data must actually resolve via `require` in the booted
// runtime. Requires dist/share.data to already carry the `greeter` package
// (single collection "greeter": main.rkt -> greet, util.rkt -> shout) -- run
// `cross-install --sdk <sdk> --share-data dist/share.data --dest <tmp> <greeter>`
// and swap the result into dist/ first. Not part of the default smoke run.

test('cross-installed package resolves in the booted runtime', async ({ page }) => {
  // Off by default: needs a greeter-extended dist (see header). Enable with
  // CONSUME_TEST=1 after cross-installing greeter into dist/share.data.
  test.skip(!process.env.CONSUME_TEST,
    'set CONSUME_TEST=1 after cross-installing greeter into dist/share.data');
  await gotoIde(page);
  await bootRepl(page);
  // main.rkt: (require greeter) (greet "world")
  expect(await evalRepl(page, '(require greeter) (greet "world")'))
    .toContain('hello, world, from tpb32l');
  // util.rkt requires its own collection's main.rkt -> the second module + an
  // intra-package require both cross-compiled and packed.
  expect(await evalRepl(page, '(require greeter/util) (shout "world")'))
    .toContain('HELLO, WORLD, FROM TPB32L');
});
