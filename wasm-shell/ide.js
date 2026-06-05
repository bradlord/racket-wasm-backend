/* ide.js -- page driver for the combined Racket WASM IDE (DrRacket-like).
 *
 * Layout: Definitions (editor) on the left, Interactions (output + REPL +
 * stdin) on the right. The Interactions pane is inert until you Run.
 *
 * Run lifecycle (process-per-run, like the old playground):
 *   - Teardown any existing worker, clear the Interactions output.
 *   - Spawn a fresh shell-worker.js with
 *       { type:"init", argv:[],
 *         files:{"/tmp/main.rkt": <editor text>}, idbfs:false }
 *     i.e. a plain interactive REPL (argv [] keeps the default
 *     racket/init, so the namespace has the full `racket` bindings). The
 *     editor text lands at /tmp/main.rkt in MEMFS.
 *   - On "ready", inject one line into the stdin ring (not echoed):
 *       (require racket/enter)
 *       (install the web-repl bitmap printer, guarded)
 *       (enter! (file "/tmp/main.rkt"))
 *     The printer is a current-print hook (web-repl/print) that renders
 *     bitmap-valued top-level results via display-bm; installed before
 *     enter! so the program's own top-level expressions get it too.
 *     enter! instantiates the module (its body runs -- output streams in)
 *     and switches the REPL's current namespace to the module's, so every
 *     top-level definition is in scope. That is exactly DrRacket's Run:
 *     run the definitions, then a REPL that sees them.
 *   - The Interactions input box is both the REPL (Cmd/Ctrl+Enter submits
 *     an expression) and the program's stdin (a submitted line reaches a
 *     blocked read-line). A second Run spawns a brand-new process.
 *
 * Shares all of the worker/ring/canvas/DOM-RPC plumbing with the pages it
 * replaces; see shell-worker.js, shell-tty.js, wasm_shell_io.c,
 * wasm_canvas.c, wasm_dom.c.
 */
(function () {
  "use strict";

  /* ---- DOM hooks --------------------------------------------------- */

  var editor       = document.getElementById("editor");
  var runBtn       = document.getElementById("run");
  var stopBtn      = document.getElementById("stop");
  var runIdleBtn   = document.getElementById("run-idle");
  var outputPre    = document.getElementById("output");
  var inputArea    = document.getElementById("input");
  var evaluateBtn  = document.getElementById("evaluate");
  var inputRow     = document.querySelector(".input-row");
  var inputState   = document.getElementById("input-state");
  var statusEl     = document.getElementById("status");
  var interactions = document.getElementById("interactions");

  function setStatus(text, state) {
    statusEl.textContent = text;
    statusEl.dataset.state = state || "idle";
  }

  function appendOutput(text) {
    // Output pane is a plain <pre>, not a terminal; strip ANSI CSI.
    text = text.replace(/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/g, "");
    if (!text) return;
    var atBottom =
      outputPre.scrollTop + outputPre.clientHeight + 4 >= outputPre.scrollHeight;
    outputPre.appendChild(document.createTextNode(text));
    while (outputPre.childNodes.length > 600) {
      outputPre.removeChild(outputPre.firstChild);
    }
    if (atBottom) outputPre.scrollTop = outputPre.scrollHeight;
  }

  // Append a bitmap inline: each { type:"canvas" } blit from the runtime
  // worker (wasm_canvas_blit*) drops a fresh <canvas> into #output, so a
  // program that draws N bitmaps shows N images interleaved with text.
  function appendCanvas(w, h, pixels) {
    if (!(w > 0 && h > 0)) return;
    var atBottom =
      outputPre.scrollTop + outputPre.clientHeight + 4 >= outputPre.scrollHeight;
    var canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    canvas.style.cssText =
      "display:block;margin:8px 0;max-width:100%;border-radius:8px;" +
      "border:1px solid rgba(159,176,195,0.18);image-rendering:pixelated;";
    // pixels arrived as a transferred ArrayBuffer (RGBA8888, top-down).
    var image = new ImageData(new Uint8ClampedArray(pixels), w, h);
    canvas.getContext("2d").putImageData(image, 0, 0);
    outputPre.appendChild(canvas);
    while (outputPre.childNodes.length > 600) {
      outputPre.removeChild(outputPre.firstChild);
    }
    if (atBottom) outputPre.scrollTop = outputPre.scrollHeight;
  }

  function clearOutput() {
    // textContent = "" also drops any <canvas> nodes appended inline.
    outputPre.textContent = "";
  }

  /* ---- bail out if not cross-origin isolated ---------------------- */

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    interactions.classList.remove("idle");
    setStatus("SAB unavailable", "error");
    appendOutput(
      "This page is not cross-origin isolated, so SharedArrayBuffer is\n" +
      "unavailable and the runtime cannot start.\n\n" +
      "Serve this directory with COOP/COEP headers, e.g. racket serve.rkt.\n"
    );
    runBtn.disabled = true;
    runIdleBtn.disabled = true;
    return;
  }

  /* ---- shared-memory rings (filled in once the worker is ready) --- */

  var HEAD = 0, TAIL = 1, DATA = 2;
  var worker = null;
  var HEAP32 = null;
  var ioReady = false;
  var inBase = 0, inCap = 0;
  var outBase = 0, outCap = 0;
  var outHead = 0;
  var stateBase = 0;   // io-state flag index (set by shell-tty.js)
  var ioWaiting = -1;  // last reflected flag value (-1 = not yet known)
  var pollHandle = 0;
  var encoder = new TextEncoder();
  var decoder = new TextDecoder("utf-8");
  /* DOM RPC slots forwarded from the runtime worker; see wasm_dom.c. */
  var domSlots = null;
  var domLastSeq = 0;

  function sendBytes(bytes) {
    if (!ioReady) return;
    var H = HEAP32;
    var tail = Atomics.load(H, inBase + TAIL);
    for (var i = 0; i < bytes.length; i++) {
      H[inBase + DATA + (tail % inCap)] = bytes[i];
      tail++;
    }
    Atomics.store(H, inBase + TAIL, tail);
    Atomics.notify(H, inBase + TAIL);
  }
  function sendText(s) { sendBytes(encoder.encode(s)); }

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
    if (text) appendOutput(text);
  }
  function serviceDom() {
    if (!domSlots || !HEAP32) return;
    var seq = Atomics.load(HEAP32, domSlots.cmdSeqBase);
    if (seq === domLastSeq) return;
    domLastSeq = seq;
    var len = Atomics.load(HEAP32, domSlots.cmdLenBase);
    // TextDecoder won't accept views over SharedArrayBuffer; slice()
    // returns a Uint8Array backed by a fresh (non-shared) buffer.
    var bytes = new Uint8Array(HEAP32.buffer, domSlots.cmdBufAddr, len).slice();
    var src = decoder.decode(bytes);
    var result;
    try {
      // v0 prototype: eval the JS string. A typed protocol will replace this.
      result = eval(src);
      if (result === undefined) result = "";
      else if (typeof result !== "string") result = String(result);
    } catch (e) {
      result = "ERROR: " + (e && (e.message || e));
    }
    var enc = encoder.encode(result);
    var n = Math.min(enc.length, domSlots.replyCap);
    var dst = new Uint8Array(HEAP32.buffer, domSlots.replyBufAddr, n);
    dst.set(enc.subarray(0, n));
    Atomics.store(HEAP32, domSlots.replyLenBase, n);
    Atomics.store(HEAP32, domSlots.replySeqBase, seq);
    Atomics.notify(HEAP32, domSlots.replySeqBase);
  }

  // Reflect the runtime's io-state flag into the input UI. 1 = the
  // process is blocked on stdin (a read-line, or the REPL prompt -- both
  // are genuinely "waiting for you to type a line"); 0 = it's busy. We
  // can't tell a program read apart from a REPL read at the fd level, so
  // we present one honest affordance covering both. Only touches the DOM
  // on a transition, and focuses the box once when input becomes wanted
  // (but never steals focus from the editor on the left).
  function reflectIoState() {
    if (!ioReady || !stateBase) return;
    var w = Atomics.load(HEAP32, stateBase);
    if (w === ioWaiting) return;
    ioWaiting = w;
    if (w) {
      inputRow.classList.add("waiting");
      inputRow.classList.remove("busy");
      inputState.textContent = "⌨ waiting for input";
      if (document.activeElement !== editor && document.activeElement !== inputArea) {
        inputArea.focus();
      }
    } else {
      inputRow.classList.remove("waiting");
      inputRow.classList.add("busy");
      inputState.textContent = "running…";
    }
  }

  function clearIoState() {
    ioWaiting = -1;
    inputRow.classList.remove("waiting", "busy");
    inputState.textContent = "";
  }

  function pollLoop() {
    drainOutput();
    serviceDom();
    reflectIoState();
    if (worker) pollHandle = requestAnimationFrame(pollLoop);
  }

  /* ---- run / stop / teardown ------------------------------------- */

  function teardown() {
    if (pollHandle) { cancelAnimationFrame(pollHandle); pollHandle = 0; }
    if (worker) {
      try { worker.terminate(); } catch (_) {}
      worker = null;
    }
    ioReady = false;
    HEAP32 = null;
    domSlots = null;
    stateBase = 0;
    clearIoState();
  }

  // Reflect "a process is alive" in the controls.
  function setControls(running, inputEnabled) {
    runBtn.disabled = running;
    runIdleBtn.disabled = running;
    stopBtn.disabled = !running;
    inputArea.disabled = !inputEnabled;
    evaluateBtn.disabled = !inputEnabled;
  }

  function run() {
    if (worker) return;
    clearOutput();
    interactions.classList.remove("idle");
    setControls(true, false);
    setStatus("Booting runtime…", "run");

    try {
      worker = new Worker("./shell-worker.js");
    } catch (err) {
      setStatus("Failed to spawn worker", "error");
      appendOutput("Failed to spawn runtime worker: " + String(err) + "\n");
      teardown();
      setControls(false, false);
      return;
    }
    worker.onerror = function (ev) {
      setStatus("Worker error", "error");
      appendOutput("\nWorker error: " + (ev.message || ev) + "\n");
    };
    worker.onmessage = onMessage;

    // Plain interactive REPL (argv [] keeps the default racket/init, so
    // the REPL namespace has the full `racket` bindings -- passing a
    // startup action like `-l racket/enter` would suppress racket/init
    // and leave the namespace bare). The editor text is dropped at
    // /tmp/main.rkt before main() runs; we require racket/enter and
    // `enter!` it once the REPL is ready (see "ready" below).
    worker.postMessage({
      type: "init",
      argv: [],
      files: { "/tmp/main.rkt": editor.value },
      idbfs: false,
    });
  }

  function stop() {
    if (!worker) return;
    appendOutput("\n[stopped]\n");
    teardown();
    setControls(false, false);
    setStatus("Stopped", "error");
  }

  // Submit the Interactions input: a REPL expression and/or a line of the
  // program's stdin. Echoed into the transcript (Racket doesn't echo stdin).
  function evaluate() {
    if (!ioReady) return;
    var text = inputArea.value;
    if (text.length === 0) return;
    if (!text.endsWith("\n")) text += "\n";
    appendOutput(text);
    sendText(text);
    inputArea.value = "";
    inputArea.focus();
  }

  function onMessage(event) {
    var msg = event.data;
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case "status": {
        var text = msg.text || "";
        var m = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text);
        if (m) setStatus("Downloading " + m[2] + "/" + m[3], "run");
        else if (text === "") setStatus("Assets loaded", "run");
        else setStatus(text, "run");
        return;
      }
      case "deps": {
        if (msg.remaining > 0) setStatus("Preparing (" + msg.remaining + ")", "run");
        return;
      }
      case "ready": {
        HEAP32   = new Int32Array(msg.heap);
        inBase   = msg.inBase;
        inCap    = msg.inCap;
        outBase  = msg.outBase;
        outCap   = msg.outCap;
        stateBase = msg.stateBase || 0;
        ioWaiting = -1;
        outHead  = Atomics.load(HEAP32, outBase + HEAD);
        domSlots = msg.dom || null;
        domLastSeq = 0;
        ioReady  = true;
        pollHandle = requestAnimationFrame(pollLoop);
        // Bootstrap, sent as separate top-level forms (each require takes
        // effect before the next form is read), not echoed:
        //   1. install the submission-oriented REPL reader
        //      (web-repl/ide-repl): from here on the REPL reads a whole
        //      submission and parses ALL its forms before evaluating, so a
        //      `read-line` mid-evaluation blocks for fresh input instead of
        //      eating the rest of a submitted line (e.g. the 2nd of two
        //      `(foo)`s). Read by the *default* per-datum reader; it then
        //      installs itself, so the remaining forms below are read by it
        //      as one submission. Guarded so a missing module still runs.
        //   2. require racket/enter (for enter!).
        //   3. install the web-repl bitmap printer: a current-print hook
        //      that renders bitmap-valued results via display-bm, so a
        //      bare top-level bitmap (in the program body or at the REPL)
        //      shows as an image. Set *before* enter! so the program's own
        //      top-level expressions get it too; guarded so a missing
        //      web-repl still lets the program run.
        //   4. enter! the program -- runs its body and lands the REPL in
        //      its namespace.
        // The trailing "\n" delimits the submission; the reader installed
        // in step 1 consumes it as the line terminator, leaving the stdin
        // buffer empty for the program's first real `read-line`.
        sendText(
          '(with-handlers ([(lambda (e) #t) void]) ' +
            '((dynamic-require (quote web-repl/ide-repl) (quote install-ide-prompt-read!)))) ' +
          '(require racket/enter) ' +
          '(with-handlers ([(lambda (e) #t) void]) ' +
            '((dynamic-require (quote web-repl/print) (quote install-bitmap-printer!)))) ' +
          '(enter! (file "/tmp/main.rkt"))\n');
        setControls(true, true);
        setStatus("Running", "run");
        inputArea.focus();
        return;
      }
      case "fs-error": {
        appendOutput("[fs error: " + msg.path + ": " + msg.error + "]\n");
        return;
      }
      case "canvas": {
        appendCanvas(msg.w, msg.h, msg.pixels);
        return;
      }
      case "abort": {
        appendOutput("\nRuntime aborted: " + msg.reason + "\n");
        teardown();
        setControls(false, false);
        setStatus("Aborted", "error");
        return;
      }
      case "exit": {
        drainOutput();  // flush anything emitted just before exit
        appendOutput("\n[exited " + msg.code + "]\n");
        teardown();
        setControls(false, false);
        setStatus(msg.code === 0 ? "Exited 0" : ("Exited " + msg.code),
                  msg.code === 0 ? "ok" : "error");
        return;
      }
    }
  }

  /* ---- wiring ----------------------------------------------------- */

  runBtn.addEventListener("click", run);
  runIdleBtn.addEventListener("click", run);
  stopBtn.addEventListener("click", stop);
  evaluateBtn.addEventListener("click", evaluate);

  editor.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      if (!runBtn.disabled) run();
    } else if (ev.key === "Tab") {
      ev.preventDefault();
      var s = editor.selectionStart, e = editor.selectionEnd;
      editor.value = editor.value.slice(0, s) + "  " + editor.value.slice(e);
      editor.selectionStart = editor.selectionEnd = s + 2;
    }
  });

  inputArea.addEventListener("keydown", function (ev) {
    // Cmd/Ctrl+Enter submits; plain Enter inserts a newline.
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      evaluate();
    }
  });

  setStatus("Idle", "idle");
})();
