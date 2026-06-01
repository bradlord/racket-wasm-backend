/* playground.js -- page driver for the Racket WASM playground.
 *
 * Lifecycle: process-per-run.
 *   - User edits a program in the textarea.
 *   - Click Run -> spawn shell-worker.js, post
 *       { type:"init", argv:["-u","/tmp/main.rkt"],
 *         files:{"/tmp/main.rkt": <editor text>}, idbfs:false }
 *     The worker loads scheme-web.js (same artifact the REPL uses),
 *     drops the file into MEMFS during preRun, and main() runs Racket
 *     with that argv, executing the user's module and exiting.
 *   - stdout/stderr stream into the output pane through the same
 *     SharedArrayBuffer ring the REPL uses (shell-tty.js inside the
 *     runtime worker pushes bytes; we poll them on rAF here).
 *   - On exit the worker posts {type:"exit", code}; we surface the
 *     code and terminate the worker. A fresh worker is spawned the
 *     next time the user clicks Run.
 *   - Stop just terminates the worker mid-run.
 *
 * stdin is supported: while the program is running, typing into the
 * stdin textarea and pressing Enter pushes a line into the input ring,
 * which shell-tty.js delivers to the Racket process.
 */
(function () {
  "use strict";

  var editor      = document.getElementById("editor");
  var runBtn      = document.getElementById("run");
  var stopBtn     = document.getElementById("stop");
  var outputPre   = document.getElementById("output");
  var stdinBox    = document.getElementById("stdin");
  var statusEl    = document.getElementById("status");
  var canvasWrap  = document.getElementById("canvas-wrap");
  var canvasEl    = document.getElementById("canvas");
  var canvasCtx   = canvasEl.getContext("2d");

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
  function clearOutput() {
    outputPre.textContent = "";
    canvasWrap.dataset.active = "0";
    canvasEl.width = 1;
    canvasEl.height = 1;
  }

  function drawCanvas(w, h, pixels) {
    if (canvasEl.width !== w || canvasEl.height !== h) {
      canvasEl.width = w;
      canvasEl.height = h;
    }
    // pixels arrived as a transferred ArrayBuffer; wrap, no copy.
    var clamped = new Uint8ClampedArray(pixels);
    var image = new ImageData(clamped, w, h);
    canvasCtx.putImageData(image, 0, 0);
    canvasWrap.dataset.active = "1";
  }

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SAB unavailable", "error");
    appendOutput(
      "This page is not cross-origin isolated, so SharedArrayBuffer is\n" +
      "unavailable and the runtime cannot start.\n\n" +
      "Serve this directory with COOP/COEP headers, e.g. python3 serve.py.\n"
    );
    return;
  }

  /* ---- per-run state ---- */

  var HEAD = 0, TAIL = 1, DATA = 2;
  var worker = null;
  var HEAP32 = null;
  var ioReady = false;
  var inBase = 0, inCap = 0;
  var outBase = 0, outCap = 0;
  var outHead = 0;
  var pollHandle = 0;
  var encoder = new TextEncoder();
  var decoder = new TextDecoder("utf-8");
  /* DOM RPC slots forwarded from the runtime worker; see shell-worker.js
     and racket/src/cs/c/wasm_dom.c. The poller below services commands
     each animation frame. */
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
      // v0 prototype: eval the JS string. Anything the page can do
      // is reachable; a typed protocol will replace this.
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
    if (worker) pollHandle = requestAnimationFrame(pollLoop);
  }

  /* ---- spawn / teardown ---- */

  function teardown() {
    if (pollHandle) { cancelAnimationFrame(pollHandle); pollHandle = 0; }
    if (worker) {
      try { worker.terminate(); } catch (_) {}
      worker = null;
    }
    ioReady = false;
    HEAP32 = null;
    stdinBox.disabled = true;
    stopBtn.disabled = true;
    runBtn.disabled = false;
  }

  function run() {
    if (worker) return;
    clearOutput();
    setStatus("Booting runtime…", "run");
    runBtn.disabled = true;
    stopBtn.disabled = false;
    stdinBox.disabled = true;
    stdinBox.value = "";

    try {
      worker = new Worker("./shell-worker.js");
    } catch (err) {
      setStatus("Failed to spawn worker", "error");
      appendOutput("Failed to spawn runtime worker: " + String(err) + "\n");
      teardown();
      return;
    }
    worker.onerror = function (ev) {
      setStatus("Worker error", "error");
      appendOutput("\nWorker error: " + (ev.message || ev) + "\n");
    };
    worker.onmessage = onMessage;

    worker.postMessage({
      type: "init",
      argv: ["-u", "/tmp/main.rkt"],
      files: { "/tmp/main.rkt": editor.value },
      idbfs: false,
    });
  }

  function stop() {
    if (!worker) return;
    appendOutput("\n[stopped]\n");
    setStatus("Stopped", "error");
    teardown();
  }

  function onMessage(event) {
    var msg = event.data;
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case "status": {
        var text = msg.text || "";
        var m = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text);
        if (m) {
          setStatus("Downloading " + m[2] + "/" + m[3], "run");
        } else if (text === "") {
          setStatus("Assets loaded", "run");
        } else {
          setStatus(text, "run");
        }
        return;
      }
      case "deps": {
        if (msg.remaining > 0) {
          setStatus("Preparing (" + msg.remaining + ")", "run");
        }
        return;
      }
      case "ready": {
        HEAP32  = new Int32Array(msg.heap);
        inBase  = msg.inBase;
        inCap   = msg.inCap;
        outBase = msg.outBase;
        outCap  = msg.outCap;
        outHead = Atomics.load(HEAP32, outBase + HEAD);
        domSlots = msg.dom || null;
        domLastSeq = 0;
        ioReady = true;
        stdinBox.disabled = false;
        setStatus("Running…", "run");
        pollHandle = requestAnimationFrame(pollLoop);
        return;
      }
      case "fs-error": {
        appendOutput("[fs error: " + msg.path + ": " + msg.error + "]\n");
        return;
      }
      case "canvas": {
        drawCanvas(msg.w, msg.h, msg.pixels);
        return;
      }
      case "abort": {
        appendOutput("\nRuntime aborted: " + msg.reason + "\n");
        setStatus("Aborted", "error");
        teardown();
        return;
      }
      case "exit": {
        // Drain any output the runtime emitted just before exit.
        drainOutput();
        appendOutput("\n[exit " + msg.code + "]\n");
        setStatus(msg.code === 0 ? "Exited 0" : ("Exited " + msg.code),
                  msg.code === 0 ? "ok" : "error");
        teardown();
        return;
      }
    }
  }

  /* ---- wiring ---- */

  runBtn.addEventListener("click", run);
  stopBtn.addEventListener("click", stop);

  editor.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      if (!runBtn.disabled) run();
    } else if (ev.key === "Tab") {
      // Insert two spaces; the textarea would otherwise tab out.
      ev.preventDefault();
      var s = editor.selectionStart, e = editor.selectionEnd;
      editor.value = editor.value.slice(0, s) + "  " + editor.value.slice(e);
      editor.selectionStart = editor.selectionEnd = s + 2;
    }
  });

  stdinBox.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter" && !ev.shiftKey) {
      ev.preventDefault();
      if (!ioReady) return;
      var line = stdinBox.value + "\n";
      // Echo into the output so the user can see what they typed.
      appendOutput(line);
      sendText(line);
      stdinBox.value = "";
    }
  });

  runBtn.disabled = false;
  setStatus("Idle", "idle");
})();
