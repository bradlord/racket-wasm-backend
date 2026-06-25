/* gui-demo.js -- page driver for the wasm racket/gui demo.
 *
 * Boots the Racket runtime in shell-worker.js, runs a #lang racket/gui program
 * (apps/gui-demo/demo.rkt -- a frame% with drawn controls: message%, button%,
 * check-box%) and wires the two browser-specific halves of the mred backend:
 *
 *   blit-out: each { type:"canvas", id, w, h, pixels } message from the runtime
 *     (wasm_canvas_blit_argb, driven by the backend's dc% flush) is one window's
 *     full surface; we putImageData it onto that window's own <canvas> (keyed by
 *     id, created on first blit, removed on a "canvas-destroy" message).
 *
 *   event-in: DOM mouse events on each <canvas> are encoded into the GUI input
 *     ring (wasm_gui_events.c) tagged with that canvas's id and Atomics.notify'd;
 *     the backend's pump (wx/wasm/queue.rkt) drains them into mouse-event% on the
 *     eventspace, routed to the matching frame.
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
  // Each GUI window owns its own <canvas>, keyed by frame id (= canvas id).
  // The static #frame is just the container anchor; we manage canvases
  // dynamically (the page owns placement -- here, stacked in #frame's parent).
  var stageEl = document.getElementById("frame").parentNode;
  document.getElementById("frame").remove();
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

  // id -> <canvas> for each shown window; focusedId routes keyboard (a
  // window-level event with no canvas under it) to the active window.
  var framesById = new Map();
  var focusedId = 0;

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
  function pushGuiEvent(type, id, x, y, k, mods) {
    if (!ioReady || !gui) return;
    var H = HEAP32, base = gui.base, cap = gui.cap, F = gui.fields;
    var tail = Atomics.load(H, base + 1);
    var slot = base + 2 + ((tail % cap) * F);
    H[slot]     = type;
    H[slot + 1] = id | 0;     // which window/canvas the event is for
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

  // Create (or fetch) the <canvas> for a window id, wiring its own input
  // listeners so each canvas tags events with its own id. offsetX/offsetY are
  // already relative to the target canvas.
  function ensureFrame(id) {
    var c = framesById.get(id);
    if (c) return c;
    c = document.createElement("canvas");
    c.style.cssText = "display:block;image-rendering:pixelated;margin:8px;";
    framesById.set(id, c);
    if (!focusedId) focusedId = id;
    c.addEventListener("mousedown", function (e) {
      focusedId = id;
      e.preventDefault();
      pushGuiEvent(EVT_MOUSE_DOWN, id, e.offsetX, e.offsetY, btnCode(e), modBits(e));
    });
    c.addEventListener("mouseup", function (e) {
      pushGuiEvent(EVT_MOUSE_UP, id, e.offsetX, e.offsetY, btnCode(e), modBits(e));
    });
    c.addEventListener("mousemove", function (e) {
      pushGuiEvent(EVT_MOUSE_MOVE, id, e.offsetX, e.offsetY, 0, modBits(e));
    });
    c.addEventListener("mouseenter", function (e) {
      focusedId = id;
      pushGuiEvent(EVT_ENTER, id, e.offsetX, e.offsetY, 0, modBits(e));
    });
    c.addEventListener("mouseleave", function (e) {
      pushGuiEvent(EVT_LEAVE, id, e.offsetX, e.offsetY, 0, modBits(e));
    });
    c.addEventListener("contextmenu", function (e) { e.preventDefault(); });
    stageEl.appendChild(c);
    return c;
  }

  function destroyFrame(id) {
    var c = framesById.get(id);
    if (c) { if (c.parentNode) c.parentNode.removeChild(c); framesById.delete(id); }
    if (focusedId === id) {
      var it = framesById.keys().next();
      focusedId = it.done ? 0 : it.value;
    }
  }

  /* Keyboard: forward keystrokes into the ring (EVT_KEY_DOWN) so text editors
   * (text%/editor-canvas%) can receive them. The backend builds a key-event%
   * from the code point; printable keys map to their char, a few specials to
   * their control codes (#\return / #\backspace / #\tab / #\escape). Listen on
   * the window since the <canvas> isn't a focusable element. */
  function keyCode(e) {
    if (e.key && e.key.length === 1) return e.key.codePointAt(0);
    switch (e.key) {
      case "Enter": return 13;
      case "Backspace": return 8;
      case "Tab": return 9;
      case "Escape": return 27;
      default: return 0;
    }
  }
  window.addEventListener("keydown", function (e) {
    var k = keyCode(e);
    if (k === 0 || !focusedId) return;
    pushGuiEvent(EVT_KEY_DOWN, focusedId, 0, 0, k, modBits(e));
    e.preventDefault();
  });

  /* ---- blit-out: render a window's surface onto its own canvas ---- */
  function blit(id, w, h, pixels) {
    if (!(w > 0 && h > 0)) return;
    var c = ensureFrame(id);
    if (c.width !== w) c.width = w;
    if (c.height !== h) c.height = h;
    c.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(pixels), w, h), 0, 0);
  }

  /* ---- worker lifecycle ------------------------------------------- */
  function teardown() {
    if (pollHandle) { cancelAnimationFrame(pollHandle); pollHandle = 0; }
    if (worker) { try { worker.terminate(); } catch (_) {} worker = null; }
    ioReady = false; HEAP32 = null; gui = null;
    framesById.forEach(function (c) { if (c.parentNode) c.parentNode.removeChild(c); });
    framesById.clear();
    focusedId = 0;
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
        blit(msg.id || 0, msg.w, msg.h, msg.pixels);
        return;
      }
      case "canvas-destroy": {
        destroyFrame(msg.id);
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
