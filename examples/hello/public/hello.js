/* hello.js -- the smallest driver for a custom Racket/WASM app surface.
 *
 * It spawns the shared runtime worker (shell-worker.js), runs main.rkt as a
 * module (argv ["-u","/tmp/main.rkt"], which runs-then-exits), and drains the
 * program's stdout from the shared-memory output ring onto the page. This is
 * the minimal counterpart to the IDE's ide.js: no editor, no REPL, no DOM RPC
 * -- just "run a module and show its output". The ring read/write protocol is
 * the same one wasm_shell_io.c / wasmfs-console.js define (see ide.js for the full,
 * interactive version).
 */
"use strict";

(function () {
  var out = document.getElementById("out");
  function append(text) { out.textContent += text; }
  function setStatus(text) { out.textContent = text; }

  // SharedArrayBuffer needs cross-origin isolation (COOP/COEP). serve.rkt sets
  // the headers; a plain static server will not start the runtime.
  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SharedArrayBuffer unavailable.\n" +
              "Serve this directory with COOP/COEP headers (e.g. racket serve.rkt).\n");
    return;
  }

  // Ring layout (int32 indices): [HEAD, TAIL, DATA...]; see wasm_shell_io.c.
  var HEAD = 0, TAIL = 1, DATA = 2;
  var HEAP32 = null;
  var outBase = 0, outCap = 0, outHead = 0;
  var ioReady = false;
  var pollHandle = 0;
  var decoder = new TextDecoder("utf-8");

  function drainOutput() {
    if (!ioReady) return;
    var H = HEAP32;
    var tail = Atomics.load(H, outBase + TAIL);
    if (tail === outHead) return;
    var chunk = new Uint8Array(tail - outHead);
    for (var i = 0; outHead !== tail; outHead++, i++) {
      chunk[i] = H[outBase + DATA + (outHead % outCap)] & 0xff;
    }
    Atomics.store(H, outBase + HEAD, outHead);
    var text = decoder.decode(chunk, { stream: true });
    if (text) append(text);
  }

  function run(programText) {
    var worker = new Worker("./shell-worker.js");
    worker.onmessage = function (event) {
      var msg = event.data;
      switch (msg.type) {
        case "status":
          if (msg.text && !ioReady) setStatus(msg.text + "\n");
          break;
        case "ready":
          HEAP32  = new Int32Array(msg.heap);   // SharedArrayBuffer
          outBase = msg.outBase;
          outCap  = msg.outCap;
          outHead = Atomics.load(HEAP32, outBase + HEAD);
          ioReady = true;
          out.textContent = "";                 // clear "starting…"
          pollHandle = setInterval(drainOutput, 16);
          break;
        case "abort":
          append("\n[runtime aborted: " + msg.reason + "]\n");
          break;
        case "exit":
          drainOutput();                        // flush the tail
          if (pollHandle) { clearInterval(pollHandle); pollHandle = 0; }
          append("\n[done, exit " + (msg.code | 0) + "]\n");
          worker.terminate();
          break;
        case "fs-error":
          append("\n[fs error at " + msg.path + ": " + msg.error + "]\n");
          break;
      }
    };
    // Run main.rkt as a module and exit. Seed it into the FS before main().
    worker.postMessage({
      type: "init",
      argv: ["-u", "/tmp/main.rkt"],
      files: { "/tmp/main.rkt": programText },
    });
  }

  // The Racket program ships as a file in this app dir; fetch and run it.
  fetch("./main.rkt")
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.text();
    })
    .then(run)
    .catch(function (e) { setStatus("could not load main.rkt: " + e.message + "\n"); });
})();
