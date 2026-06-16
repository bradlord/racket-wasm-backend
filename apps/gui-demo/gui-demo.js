/* gui-demo.js -- page driver for the wasm racket/gui demo.
 *
 * Boots the Racket runtime in shell-worker.js, runs a #lang racket/gui program
 * (apps/gui-demo/demo.rkt -- a frame% with drawn controls: message%, button%,
 * check-box%) and wires the two browser-specific halves of the mred backend:
 *
 *   blit-out: each { type:"canvas", w, h, pixels } message from the runtime
 *     (wasm_canvas_blit_argb, driven by the backend's dc% flush) is the frame's
 *     full surface; we putImageData it onto ONE persistent <canvas> (unlike the
 *     IDE, which appends a fresh bitmap per blit).
 *
 *   event-in: DOM mouse events on that <canvas> are encoded into the GUI input
 *     ring (wasm_gui_events.c) and Atomics.notify'd; the backend's pump
 *     (wx/wasm/queue.rkt) drains them into mouse-event% on the eventspace.
 *
 * The runtime is started with argv that (1) set PLT_WASM_GUI before racket/gui
 * loads -- so wx/platform.rkt's unix branch selects wx/wasm -- and (2) require
 * the program with no interactive REPL. The program parks in (yield ...), so the
 * worker idles on a Racket semaphore (not a stdin read) and the pump still runs.
 */
"use strict";

(function () {
  var runBtn = document.getElementById("run");
  var statusEl = document.getElementById("status");
  var frameCanvas = document.getElementById("frame");
  var frameCtx = frameCanvas.getContext("2d");
  var logEl = document.getElementById("log");

  function setStatus(s) { statusEl.textContent = s; }
  function log(s) { logEl.textContent += s; logEl.scrollTop = logEl.scrollHeight; }

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SAB unavailable — serve with COOP/COEP (racket serve.rkt)");
    runBtn.disabled = true;
    return;
  }

  /* ---- GUI event protocol (mirror of wx/wasm/queue.rkt) ----------- */
  var EVT_MOUSE_DOWN = 1, EVT_MOUSE_UP = 2, EVT_MOUSE_MOVE = 3,
      EVT_KEY_DOWN = 4, EVT_ENTER = 7, EVT_LEAVE = 8;
  var FRAME_ID = 1;  // the demo's single frame gets id 1 (next-frame-id starts at 1)

  /* ---- ring bookkeeping (ints filled in on "ready") --------------- */
  var HEAD = 0, TAIL = 1, DATA = 2;
  var worker = null, HEAP32 = null, ioReady = false;
  var outBase = 0, outCap = 0, outHead = 0;
  var gui = null;            // { base, cap, fields } int32 indices/sizes
  var pollHandle = 0;
  var decoder = new TextDecoder("utf-8");

  /* The demo program (apps/gui-demo/demo.rkt), spliced in by the app's
   * post-build hook (build-demo.rkt) as a JSON string. Dropped at
   * /tmp/main.rkt before main() runs. */
  var PROGRAM = __PROGRAM__;

  /* ---- stdout drain (program printf -> #log) ---------------------- */
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
    if (text) log(text);
  }

  function pollLoop() {
    drainOutput();
    if (worker) pollHandle = requestAnimationFrame(pollLoop);
  }

  /* ---- event-in: write a record into the GUI ring ----------------- */
  function pushGuiEvent(type, x, y, k, mods) {
    if (!ioReady || !gui) return;
    var H = HEAP32, base = gui.base, cap = gui.cap, F = gui.fields;
    var tail = Atomics.load(H, base + 1);
    var slot = base + 2 + ((tail % cap) * F);
    H[slot]     = type;
    H[slot + 1] = FRAME_ID;
    H[slot + 2] = x | 0;
    H[slot + 3] = y | 0;
    H[slot + 4] = k | 0;
    H[slot + 5] = mods | 0;
    Atomics.store(H, base + 1, tail + 1);
    Atomics.notify(H, base + 1);
  }

  function modBits(e) {
    return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) |
           (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
  }
  // DOM button (0 left, 1 middle, 2 right) -> backend k (0 left, 1 middle, 2 right).
  function btnCode(e) { return e.button === 1 ? 1 : e.button === 2 ? 2 : 0; }

  frameCanvas.addEventListener("mousedown", function (e) {
    e.preventDefault();
    pushGuiEvent(EVT_MOUSE_DOWN, e.offsetX, e.offsetY, btnCode(e), modBits(e));
  });
  frameCanvas.addEventListener("mouseup", function (e) {
    pushGuiEvent(EVT_MOUSE_UP, e.offsetX, e.offsetY, btnCode(e), modBits(e));
  });
  frameCanvas.addEventListener("mousemove", function (e) {
    pushGuiEvent(EVT_MOUSE_MOVE, e.offsetX, e.offsetY, 0, modBits(e));
  });
  frameCanvas.addEventListener("mouseenter", function (e) {
    pushGuiEvent(EVT_ENTER, e.offsetX, e.offsetY, 0, modBits(e));
  });
  frameCanvas.addEventListener("mouseleave", function (e) {
    pushGuiEvent(EVT_LEAVE, e.offsetX, e.offsetY, 0, modBits(e));
  });
  frameCanvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });

  /* ---- blit-out: mirror the frame surface onto #frame ------------- */
  function blit(w, h, pixels) {
    if (frameCanvas.width !== w || frameCanvas.height !== h) {
      frameCanvas.width = w;
      frameCanvas.height = h;
    }
    frameCtx.putImageData(new ImageData(new Uint8ClampedArray(pixels), w, h), 0, 0);
  }

  /* ---- worker lifecycle ------------------------------------------- */
  function teardown() {
    if (pollHandle) { cancelAnimationFrame(pollHandle); pollHandle = 0; }
    if (worker) { try { worker.terminate(); } catch (_) {} worker = null; }
    ioReady = false; HEAP32 = null; gui = null;
    runBtn.disabled = false;
  }

  function onMessage(event) {
    var msg = event.data;
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case "status": {
        if (ioReady) return;
        var m = /\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(msg.text || "");
        if (m) setStatus("Downloading " + m[1] + "/" + m[2]);
        else if (msg.text) setStatus(msg.text);
        return;
      }
      case "deps": {
        if (msg.remaining > 0) setStatus("Preparing (" + msg.remaining + ")");
        return;
      }
      case "ready": {
        HEAP32 = new Int32Array(msg.heap);
        outBase = msg.outBase; outCap = msg.outCap;
        outHead = Atomics.load(HEAP32, outBase + HEAD);
        gui = (msg.guiEvents && msg.guiEvents.cap) ? msg.guiEvents : null;
        ioReady = true;
        setStatus(gui ? "Running" : "Running (no GUI ring — clicks disabled)");
        pollHandle = requestAnimationFrame(pollLoop);
        return;
      }
      case "canvas": {
        blit(msg.w, msg.h, msg.pixels);
        return;
      }
      case "abort": {
        log("\n[runtime aborted: " + msg.reason + "]\n");
        setStatus("Aborted");
        teardown();
        return;
      }
      case "exit": {
        drainOutput();
        log("\n[exited " + msg.code + "]\n");
        setStatus("Exited " + msg.code);
        teardown();
        return;
      }
    }
  }

  function run() {
    if (worker) return;
    runBtn.disabled = true;
    logEl.textContent = "";
    setStatus("Booting runtime…");
    try {
      worker = new Worker("./shell-worker.js");
    } catch (err) {
      setStatus("Failed to spawn worker");
      log("Failed to spawn runtime worker: " + String(err) + "\n");
      teardown();
      return;
    }
    worker.onerror = function (ev) {
      setStatus("Worker error");
      log("\nWorker error: " + (ev.message || ev) + "\n");
    };
    worker.onmessage = onMessage;
    // -e sets PLT_WASM_GUI BEFORE racket/gui is required (so the wasm mred
    // backend is selected); -t requires the program with no interactive REPL.
    worker.postMessage({
      type: "init",
      argv: ["-e", "(putenv \"PLT_WASM_GUI\" \"1\")", "-t", "/tmp/main.rkt"],
      files: { "/tmp/main.rkt": PROGRAM },
    });
  }

  runBtn.addEventListener("click", run);
  setStatus("Idle — click Run");
})();
