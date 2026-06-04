/* browser-shell.js -- page driver for the Racket WASM REPL.
 *
 * Architecture (see shell-worker.js, shell-tty.js, wasm_shell_io.c):
 *
 *   We spawn a dedicated Web Worker (shell-worker.js) that loads
 *   scheme-web.js and runs Racket's `main()` on its own thread. The
 *   page's main thread (this file) stays free to drive the UI. The
 *   two threads exchange console bytes through two ring buffers
 *   placed in the module's shared linear memory:
 *
 *     - stdin ring:  the page writes the submitted expression here and
 *                    Atomics.notify's the worker, which is blocked in
 *                    Atomics.wait inside its TTY read (shell-tty.js).
 *     - stdout ring: the worker writes bytes; we poll it here each
 *                    animation frame and append to the <pre> output.
 *
 * UI shape:
 *   Output (a scrollable <pre>) on top, plain <textarea> on the
 *   bottom. The browser handles all editing (cursor, multi-line,
 *   paste, undo, find). Cmd/Ctrl+Enter or the Evaluate button
 *   submits the textarea contents as one Racket expression.
 *
 *   Submitting echoes the entered text into the output pane (Racket
 *   itself does not echo stdin) so a session reads back as a
 *   transcript: prompt, your expression, result, next prompt.
 */
(function () {
  "use strict";

  /* ---- DOM hooks --------------------------------------------------- */

  var statusElement   = document.getElementById("runtime-status");
  var downloadElement = document.getElementById("download-status");
  var progressBar     = document.getElementById("progress-bar");
  var runtimeChip     = document.getElementById("runtime-chip");
  var reloadButton    = document.getElementById("reload-runtime");
  var clearButton     = document.getElementById("clear-output");
  var saveButton      = document.getElementById("save-restart");
  var outputPre       = document.getElementById("output");
  var inputTextarea   = document.getElementById("input");
  var evaluateButton  = document.getElementById("evaluate");

  function setStatus(text, state) {
    statusElement.textContent = text;
    statusElement.dataset.state = state || "idle";
    runtimeChip.textContent = text;
  }
  function setProgress(ratio, text) {
    var clamped = Math.max(0, Math.min(1, ratio));
    progressBar.style.width = Math.round(clamped * 100) + "%";
    if (text) downloadElement.textContent = text;
  }

  function appendOutput(text) {
    // Strip ANSI CSI sequences we don't render -- the output pane is a
    // plain <pre>, not a terminal emulator. \x1b[...m, \x1b[K, etc.
    text = text.replace(/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/g, "");
    if (!text) return;
    var atBottom =
      outputPre.scrollTop + outputPre.clientHeight + 4 >= outputPre.scrollHeight;
    outputPre.appendChild(document.createTextNode(text));
    // Bound the output node count so very chatty programs don't
    // monotonically grow the DOM. We keep a trailing window of text
    // nodes; the user can also hit "Clear Output".
    while (outputPre.childNodes.length > 600) {
      outputPre.removeChild(outputPre.firstChild);
    }
    if (atBottom) outputPre.scrollTop = outputPre.scrollHeight;
  }

  // Append a bitmap inline in the transcript. The runtime worker sends
  // pixels through wasm_canvas_blit{,_argb,_bgra} (racket/src/cs/c/
  // wasm_canvas.c), which postMessages { type:"canvas", w, h, pixels }
  // straight to this page. Unlike the playground (one fixed <canvas>),
  // the REPL drops a fresh <canvas> per blit so a session that draws N
  // bitmaps reads back as N images interleaved with its text output.
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
    // pixels arrived as a transferred ArrayBuffer (RGBA8888, top-down);
    // wrap it without copying.
    var image = new ImageData(new Uint8ClampedArray(pixels), w, h);
    canvas.getContext("2d").putImageData(image, 0, 0);
    outputPre.appendChild(canvas);
    while (outputPre.childNodes.length > 600) {
      outputPre.removeChild(outputPre.firstChild);
    }
    if (atBottom) outputPre.scrollTop = outputPre.scrollHeight;
  }

  /* ---- bail out if not cross-origin isolated ---------------------- */

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SharedArrayBuffer unavailable", "error");
    appendOutput(
      "This page is not cross-origin isolated, so SharedArrayBuffer is\n" +
      "unavailable and the runtime cannot start.\n\n" +
      "Serve this directory with COOP/COEP headers, e.g.:\n" +
      "  racket serve.rkt   (see wasm-shell/serve.rkt)\n"
    );
    return;
  }

  appendOutput("Racket WASM REPL initialized.\nLoading runtime assets...\n\n");

  /* ---- shared-memory rings (filled in once the worker is ready) -- */

  var HEAD = 0, TAIL = 1, DATA = 2;
  var HEAP32 = null;
  var ioReady = false;
  var ringInBase = 0, ringInCap = 0;
  var ringOutBase = 0, ringOutCap = 0;
  var outHead = 0;
  var encoder = new TextEncoder();
  var outDecoder = new TextDecoder("utf-8");
  /* DOM RPC: see racket/src/cs/c/wasm_dom.c. */
  var domSlots = null;
  var domLastSeq = 0;

  function sendBytes(bytes) {
    if (!ioReady) {
      debug("drop " + bytes.length + " bytes (runtime not ready)");
      return;
    }
    var H = HEAP32;
    var tail = Atomics.load(H, ringInBase + TAIL);
    for (var i = 0; i < bytes.length; i++) {
      H[ringInBase + DATA + (tail % ringInCap)] = bytes[i];
      tail++;
    }
    Atomics.store(H, ringInBase + TAIL, tail);
    Atomics.notify(H, ringInBase + TAIL);
    debug("send " + bytes.length + "B, in.tail=" + tail);
  }
  function sendText(text) { sendBytes(encoder.encode(text)); }

  /* ---- diagnostics ------------------------------------------------ */

  var debugList = document.getElementById("debug-log");
  var debugLines = [];
  function debug(msg) {
    if (!debugList) { console.log("[shell]", msg); return; }
    debugLines.push("[" + new Date().toISOString().substr(11, 12) + "] " + msg);
    if (debugLines.length > 40) debugLines.shift();
    debugList.textContent = debugLines.join("\n");
  }

  /* ---- submit ----------------------------------------------------- */

  function evaluate() {
    if (!ioReady) return;
    var text = inputTextarea.value;
    if (text.length === 0) return;
    if (!text.endsWith("\n")) text += "\n";

    // Echo into the output transcript so the session reads back as
    // prompt/input/result/prompt rather than just result-after-result.
    appendOutput(text);

    sendText(text);
    inputTextarea.value = "";
    inputTextarea.focus();
  }

  evaluateButton.addEventListener("click", evaluate);
  clearButton.addEventListener("click", function () {
    outputPre.textContent = "";
    inputTextarea.focus();
  });
  reloadButton.addEventListener("click", function () { window.location.reload(); });

  // Save & Restart: send Racket a clean exit. The runtime worker's
  // Module.onExit runs FS.syncfs(false) once its event loop is free,
  // then posts { type: "exit" }; the page tears down the worker and
  // spawns a fresh one (which IDBFS-loads on its preRun).
  var saveInProgress = false;
  saveButton.addEventListener("click", function () {
    if (!ioReady || saveInProgress) return;
    saveInProgress = true;
    saveButton.disabled = true;
    evaluateButton.disabled = true;
    appendOutput("\n[saving /home/web_user and restarting runtime...]\n");
    sendText("(exit 0)\n");
  });

  // Cmd+Enter (macOS) or Ctrl+Enter (others) submits; plain Enter
  // inserts a newline. Shift+Enter is also a plain newline.
  inputTextarea.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      evaluate();
    }
  });

  /* ---- stdout ring -> <pre> (polled) ------------------------------ */

  function drainOutput() {
    if (!ioReady) return;
    var H = HEAP32;
    var tail = Atomics.load(H, ringOutBase + TAIL);
    if (tail === outHead) return;

    var chunk = new Uint8Array(tail - outHead);
    for (var i = 0; outHead !== tail; outHead++, i++) {
      chunk[i] = H[ringOutBase + DATA + (outHead % ringOutCap)] & 0xff;
    }
    Atomics.store(H, ringOutBase + HEAD, outHead);
    var text = outDecoder.decode(chunk, { stream: true });
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
    var src = outDecoder.decode(bytes);
    var result;
    try {
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

  function pollLoop() {
    drainOutput();
    serviceDom();
    requestAnimationFrame(pollLoop);
  }

  /* ---- worker wiring --------------------------------------------- */

  var worker = null;

  function spawnWorker() {
    setStatus("Spawning runtime worker", "running");
    downloadElement.textContent = "Starting";
    evaluateButton.disabled = true;
    saveButton.disabled = true;
    ioReady = false;
    try {
      worker = new Worker("./shell-worker.js");
    } catch (err) {
      setStatus("Failed to spawn worker", "error");
      appendOutput("\nFailed to spawn runtime worker: " + String(err) + "\n");
      worker = null;
      return;
    }
    worker.onerror = onWorkerError;
    worker.onmessage = onWorkerMessage;
    // No argv -> Racket runs the interactive REPL. IDBFS on for the
    // persistent /home/web_user the REPL relies on.
    worker.postMessage({ type: "init", argv: [], idbfs: true });
  }

  function onWorkerError(event) {
    setStatus("Runtime worker error", "error");
    appendOutput("\nWorker error: " + (event.message || event) + "\n");
  }

  function onWorkerMessage(event) {
    var msg = event.data;
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case "status": {
        var text = msg.text || "";
        var match = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text);
        if (match) {
          var loaded = Number(match[2]);
          var total  = Number(match[3]);
          setStatus(match[1].trim() || "Downloading assets", "running");
          setProgress(total > 0 ? loaded / total : 0, loaded + "/" + total);
        } else if (text === "") {
          setStatus("Assets loaded", "running");
          setProgress(1, "Loaded");
        } else {
          setStatus(text, "running");
          downloadElement.textContent = text;
        }
        return;
      }
      case "deps": {
        var n = msg.remaining;
        if (n > 0) {
          setStatus("Preparing runtime", "running");
          downloadElement.textContent = n + " dependenc" + (n === 1 ? "y" : "ies") + " remaining";
        } else {
          setStatus("Starting runtime", "running");
          downloadElement.textContent = "All downloads complete";
        }
        return;
      }
      case "idbfs": {
        debug("idbfs: " + msg.text);
        return;
      }
      case "ready": {
        var sab = msg.heap;
        HEAP32       = new Int32Array(sab);
        ringInBase   = msg.inBase;
        ringInCap    = msg.inCap;
        ringOutBase  = msg.outBase;
        ringOutCap   = msg.outCap;
        outHead      = Atomics.load(HEAP32, ringOutBase + HEAD);
        domSlots     = msg.dom || null;
        domLastSeq   = 0;
        ioReady      = true;
        evaluateButton.disabled = false;
        saveButton.disabled = false;
        debug("ready: SAB=" + (sab && sab.constructor && sab.constructor.name) +
              " bytes=" + (sab && sab.byteLength) +
              " inBase=" + ringInBase + " inCap=" + ringInCap +
              " outBase=" + ringOutBase + " outCap=" + ringOutCap);
        setStatus("Runtime ready", "ready");
        setProgress(1, "Ready");
        requestAnimationFrame(pollLoop);
        inputTextarea.focus();
        return;
      }
      case "canvas": {
        appendCanvas(msg.w, msg.h, msg.pixels);
        return;
      }
      case "abort": {
        ioReady = false;
        evaluateButton.disabled = true;
        saveButton.disabled = true;
        setStatus("Runtime aborted", "error");
        appendOutput("\nRuntime aborted: " + msg.reason + "\n");
        return;
      }
      case "exit": {
        ioReady = false;
        evaluateButton.disabled = true;
        saveButton.disabled = true;
        if (msg.syncErr) {
          appendOutput("\n[save warning: " + msg.syncErr + "]\n");
          debug("syncfs(false) error: " + msg.syncErr);
        }
        // Tear down the worker now that its onExit (and the
        // syncfs(false) inside it) has resolved. If this exit came
        // from the Save & Restart path, spawn a fresh runtime
        // immediately. Otherwise leave the user with a stopped
        // runtime and a "reload page" button.
        try { if (worker) worker.terminate(); } catch (_) {}
        worker = null;
        if (saveInProgress) {
          appendOutput("[saved. respawning runtime...]\n\n");
          saveInProgress = false;
          spawnWorker();
        } else {
          setStatus("Runtime exited (" + msg.code + ")", msg.code === 0 ? "ready" : "error");
          appendOutput("\nProcess exited with code " + msg.code + ".\n");
        }
        return;
      }
    }
  }

  spawnWorker();
})();
