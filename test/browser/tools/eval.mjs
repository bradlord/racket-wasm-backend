#!/usr/bin/env node
// Ad-hoc "run Racket in the browser build and show me the output" CLI.
//
//   node tools/eval.mjs '(+ 1 2)'                 # REPL expression(s)
//   node tools/eval.mjs --file prog.rkt           # run a #lang module
//   echo '(displayln (* 6 7))' | node tools/eval.mjs -   # read from stdin
//   node tools/eval.mjs --shot out.png '(require racket/draw web-repl/display-bm)
//                                        (display-bm (make-bitmap 40 40))'
//
// Source starting with `#lang` runs as a module (its stdout is printed);
// otherwise it's evaluated at the REPL. Program output goes to stdout; all
// diagnostics go to stderr, so the result is clean to capture in scripts/agents.
//
// Flags: --file <path>, --repl (force REPL mode), --module (force module mode),
//        --shot <png> (screenshot the Interactions pane after running),
//        --url <baseURL> (use an already-running server; skip starting one),
//        --headed (show the browser), --timeout <ms>.
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';
import { startServer } from '../lib/server.mjs';
import { gotoIde, bootRepl, evalRepl, loadAndRun } from '../lib/ide.mjs';

function parseArgs(argv) {
  const o = { positional: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--file': o.file = argv[++i]; break;
      case '--repl': o.repl = true; break;
      case '--module': o.module = true; break;
      case '--shot': o.shot = argv[++i]; break;
      case '--url': o.url = argv[++i]; break;
      case '--headed': o.headed = true; break;
      case '--timeout': o.timeout = Number(argv[++i]); break;
      case '-h': case '--help': o.help = true; break;
      default: o.positional.push(a);
    }
  }
  return o;
}

const HELP = `usage: node tools/eval.mjs [options] '<code>' | --file <path> | -
  --file <path>   run a Racket source file
  -               read source from stdin
  --repl          evaluate as REPL expression(s) (default for non-#lang source)
  --module        run as a #lang module (default when source starts with #lang)
  --shot <png>    save a screenshot of the Interactions pane
  --url <base>    use an already-running COOP/COEP server (e.g. http://127.0.0.1:8123)
  --headed        show the browser window
  --timeout <ms>  per-step timeout (default 180000)`;

async function readSource(o) {
  if (o.file) return readFileSync(o.file, 'utf8');
  if (o.positional.length === 1 && o.positional[0] === '-') {
    return readFileSync(0, 'utf8'); // stdin
  }
  if (o.positional.length) return o.positional.join(' ');
  return null;
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.help) { console.error(HELP); process.exit(0); }
  const source = await readSource(o);
  if (source == null) { console.error(HELP); process.exit(2); }

  const asModule = o.module || (!o.repl && /^\s*#lang\b/.test(source));
  const timeout = o.timeout || 180_000;

  let server = null;
  let baseURL = o.url;
  if (!baseURL) {
    process.stderr.write('starting server…\n');
    server = await startServer();
    baseURL = server.baseURL;
  }

  const browser = await chromium.launch({
    headless: !o.headed,
    args: ['--enable-features=SharedArrayBuffer'],
  });
  try {
    const page = await browser.newPage({ baseURL });
    page.on('console', (m) => process.stderr.write(`[page] ${m.text()}\n`));
    process.stderr.write('booting runtime…\n');
    await gotoIde(page);

    let out;
    if (asModule) {
      out = await loadAndRun(page, source, { timeout });
    } else {
      await bootRepl(page, { timeout });
      out = await evalRepl(page, source, { timeout });
    }
    process.stdout.write(out.endsWith('\n') ? out : out + '\n');

    if (o.shot) {
      await page.locator('#output').screenshot({ path: o.shot });
      process.stderr.write(`saved screenshot: ${o.shot}\n`);
    }
  } finally {
    await browser.close();
    if (server) server.stop();
  }
}

main().catch((e) => {
  process.stderr.write(`error: ${e?.stack || e}\n`);
  process.exit(1);
});
