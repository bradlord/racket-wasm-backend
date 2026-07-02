/* ide.js -- page driver for the combined Racket WASM IDE (DrRacket-like).
 *
 * Layout: Definitions (editor, with a file-tab strip for multi-file
 * programs) on the left, Interactions (output + REPL + stdin) on the right.
 * The Interactions pane is inert until you Run.
 *
 * Multiple files: the Definitions pane can hold any number of open files
 * (tabs), all landing in the same directory (/tmp/) when a run starts, so
 * one file can `(require "sibling.rkt")` another by name. Whichever tab is
 * *active* is the entry point Run uses -- not a fixed main.rkt -- mirroring
 * DrRacket's "run the front file" model but letting you pick which file is
 * the front one.
 *
 * Run lifecycle (process-per-run, like the old playground):
 *   - Teardown any existing worker, clear the Interactions output.
 *   - Spawn a fresh shell-worker.js with
 *       { type:"init", argv:[],
 *         files:{"/tmp/<name>": <tab text>, ...} }
 *     i.e. a plain interactive REPL (argv [] keeps the default
 *     racket/init, so the namespace has the full `racket` bindings). Every
 *     open tab lands at /tmp/<its name>. (The persistent home
 *     /home/web_user is OPFS-backed by the runtime, durable on close, so
 *     a new run still sees files an earlier run wrote -- no opt-in flag.)
 *   - On "ready", inject one line into the stdin ring (not echoed):
 *       (require racket/enter)
 *       (install the web-repl bitmap printer, guarded)
 *       (enter! (file "/tmp/<active tab's name>"))
 *     The printer is a current-print hook (web-repl/print) that renders
 *     bitmap-valued top-level results via display-bm; installed before
 *     enter! so the program's own top-level expressions get it too.
 *     enter! instantiates the module (its body runs -- output streams in)
 *     and switches the REPL's current namespace to the module's, so every
 *     top-level definition is in scope. That is exactly DrRacket's Run:
 *     run the definitions, then a REPL that sees them.
 *   - The Interactions input box is both the REPL (Cmd/Ctrl+Enter submits
 *     an expression) and the program's stdin (a submitted line reaches a
 *     blocked read-line). A second Run spawns a brand-new process;
 *     Cmd/Ctrl+Enter (or Cmd/Ctrl+R) in the editor re-runs too, stopping a
 *     live run first.
 *
 * Shares all of the worker/ring/canvas/DOM-RPC plumbing with the pages it
 * replaces; see shell-worker.js, wasmfs-stdin.js, wasmfs-console.js,
 * wasm_shell_io.c, wasm_canvas.c, wasm_dom.c.
 */
(function () {
  "use strict";

  /* ---- example programs ------------------------------------------- */
  /* The Definitions pane is seeded from here (no hardcoded markup in
   * index.html). Each entry is { name, files: [{ name, code }, ...] } --
   * one or more files, one tab each; a single-file example is just a
   * one-element files array. This array is GENERATED at build time from
   * the programs in apps/ide/examples/: the post-build hook
   * (apps/ide/build-examples.rkt) splices the examples JSON in place of the
   * placeholder token below. Edit the files under examples/, not this
   * line. */

  var EXAMPLES = __EXAMPLES__;

  /* ---- DOM hooks --------------------------------------------------- */

  /* The Definitions editor is a single CodeMirror 5 instance overlaid on the
   * <textarea id="editor">; each open file gets its own CodeMirror.Doc (own
   * undo history + cursor), and switching tabs calls editor.swapDoc() to
   * show the right one -- the DOM/CM instance itself never changes. CM5 has
   * no dedicated racket mode; `scheme` covers all the shared s-expression
   * keywords (define, lambda, let, quote, ...) and renders Racket source
   * faithfully. The mode is chosen from the #lang line (see detectMode
   * below): lispy #langs use scheme, rhombus and rhombus/* use the rhombus
   * mode, others fall back to text/plain. The REPL input (#input)
   * deliberately stays a plain textarea -- it's a single submission line,
   * not an editing surface. */
  var editor = CodeMirror.fromTextArea(document.getElementById("editor"), {
    mode: "scheme",
    lineNumbers: true,
    lineWrapping: false,
    indentUnit: 2,
    tabSize: 2,
    indentWithTabs: false,
    matchBrackets: true,
    autoCloseBrackets: true,
    extraKeys: {
      "Cmd-Enter":  function () { restart(); },
      "Ctrl-Enter": function () { restart(); },
      "Cmd-R":      function () { restart(); },
      "Ctrl-R":     function () { restart(); },
      "Tab":        function (cm) { cm.replaceSelection("  ", "end"); }
    }
  });

  /* #lang -> CM mode. scheme mode handles every s-expression #lang; the
   * entries below are the non-lisp #langs the shipped examples use, plus
   * the common lispy ones made explicit for clarity. Any #lang starting
   * with "rhombus" (rhombus, rhombus/static, rhombus/non-space, etc.) uses
   * the rhombus mode. An unknown #lang defaults to scheme (most Racket
   * #langs are s-expr based). */
  var LANG_MODE = {
    "racket": "scheme", "racket/base": "scheme", "typed/racket": "scheme",
    "typed/racket/base": "scheme", "lazy": "scheme", "r5rs": "scheme",
    "r6rs": "scheme", "scheme": "scheme", "scheme/base": "scheme",
    "at-exp": "scheme", "scribble": "text/plain",
    "datalog": "text/plain", "s-exp": "scheme"
  };

  function detectMode() {
    var val = editor.getValue();
    var m = /^[\s\n]*#lang\s+(\S+)/m.exec(val);
    var lang = m ? m[1] : "racket";
    var mode;
    if (LANG_MODE[lang] != null) {
      mode = LANG_MODE[lang];
    } else if (/^rhombus($|\/)/.test(lang)) {
      mode = "rhombus";
    } else {
      mode = "scheme";
    }
    if (editor.getOption("mode") !== mode) editor.setOption("mode", mode);
  }
  var modeDebounce = 0;
  editor.on("change", function () {
    if (modeDebounce) clearTimeout(modeDebounce);
    modeDebounce = setTimeout(detectMode, 300);
  });

  var exampleSel   = document.getElementById("example");
  var gistBtn      = document.getElementById("gist");
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
  var tabsEl       = document.getElementById("tabs");
  var addFileBtn   = document.getElementById("add-file");

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
      "display:block;margin:8px 0;max-width:100%;" +
      "image-rendering:pixelated;";
    // pixels arrived as a transferred ArrayBuffer (RGBA8888, top-down).
    var image = new ImageData(new Uint8ClampedArray(pixels), w, h);
    canvas.getContext("2d").putImageData(image, 0, 0);
    outputPre.appendChild(canvas);
    while (outputPre.childNodes.length > 600) {
      outputPre.removeChild(outputPre.firstChild);
    }
    if (atBottom) outputPre.scrollTop = outputPre.scrollHeight;
  }

  // Addressable canvases: id > 0 owns a persistent <canvas> that updates in
  // place (a web-repl canvas-window, or a GUI frame). The page owns placement
  // -- here they're appended inline like ephemeral ones, but tracked by id so
  // repeated blits reuse the same element instead of stacking up.
  var canvasesById = new Map();
  function blitCanvas(id, w, h, pixels) {
    if (!(w > 0 && h > 0)) return;
    var canvas = canvasesById.get(id);
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.style.cssText =
        "display:block;margin:8px 0;max-width:100%;image-rendering:pixelated;";
      canvasesById.set(id, canvas);
    }
    // Re-attach if absent (first blit, or pruned by the #output node cap).
    if (!canvas.parentNode) outputPre.appendChild(canvas);
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;
    var image = new ImageData(new Uint8ClampedArray(pixels), w, h);
    canvas.getContext("2d").putImageData(image, 0, 0);
  }

  function destroyCanvas(id) {
    var canvas = canvasesById.get(id);
    if (canvas) {
      if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
      canvasesById.delete(id);
    }
  }

  function clearOutput() {
    // textContent = "" also drops any <canvas> nodes appended inline.
    outputPre.textContent = "";
    canvasesById.clear();
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

  /* ---- multi-file Definitions state -------------------------------- */
  /* files: [{ name, doc }] -- one CodeMirror.Doc per open tab, all shown
   * through the single `editor` instance via swapDoc. active is the index
   * of both the selected tab and the file Run treats as the entry point. */

  var files = [];
  var active = 0;
  var renaming = -1;  // index of the tab currently being renamed, -1 = none

  function activeFile() { return files[active]; }
  function entryPath() { return "/tmp/" + activeFile().name; }

  function makeDoc(code) {
    return new CodeMirror.Doc(code, "scheme");
  }

  // Serialize a file list for unsaved-edit comparisons (see loadExample).
  function snapshotFiles(list) {
    return JSON.stringify(list.map(function (f) {
      return { name: f.name, code: f.doc.getValue() };
    }));
  }
  function currentSnapshot() { return snapshotFiles(files); }

  // Replace the whole open-file set (example load / gist import).
  function setFiles(newFiles, activeIdx) {
    files = newFiles;
    active = (activeIdx == null || activeIdx < 0 || activeIdx >= files.length)
      ? 0 : activeIdx;
    editor.swapDoc(files[active].doc);
    detectMode();
    renderTabs();
  }

  function selectTab(idx) {
    if (idx === active || !files[idx]) return;
    active = idx;
    editor.swapDoc(files[active].doc);
    detectMode();
    renderTabs();
  }

  function nextUntitledName() {
    var n = 1;
    while (files.some(function (f) { return f.name === "untitled-" + n + ".rkt"; })) n++;
    return "untitled-" + n + ".rkt";
  }

  // Seed text for a freshly-added file; also its "untouched" marker (see
  // closeFile) -- a tab still holding exactly this text has nothing worth
  // confirming a close over.
  var NEW_FILE_SEED = "#lang racket\n";

  function addFile() {
    var name = nextUntitledName();
    files.push({ name: name, doc: makeDoc(NEW_FILE_SEED), pristineSeed: NEW_FILE_SEED });
    active = files.length - 1;
    editor.swapDoc(files[active].doc);
    detectMode();
    // startRename focuses its inline input; don't steal that focus back to
    // the editor here, or the input's blur handler commits the rename
    // (a no-op, since it fires before the user types anything) immediately.
    startRename(active);
  }

  function closeFile(idx) {
    if (files.length <= 1) return;
    var f = files[idx];
    // Closing a tab deletes its content outright (there's no save/restore),
    // so confirm -- unless it's a just-added file nobody has typed into yet.
    var untouched = f.pristineSeed != null && f.doc.getValue() === f.pristineSeed;
    if (!untouched && !window.confirm("Close " + f.name + "? This can't be undone.")) return;
    files.splice(idx, 1);
    if (idx < active) active--;
    if (active >= files.length) active = files.length - 1;
    if (active < 0) active = 0;
    if (renaming === idx) renaming = -1;
    editor.swapDoc(files[active].doc);
    detectMode();
    renderTabs();
  }

  function startRename(idx) {
    renaming = idx;
    renderTabs();
    var input = tabsEl.querySelector(".tab-rename");
    if (input) { input.focus(); input.select(); }
  }

  function commitRename(idx, value) {
    var name = value.trim();
    renaming = -1;
    if (name && name !== files[idx].name) {
      var collision = files.some(function (f, i) { return i !== idx && f.name === name; });
      if (!collision) files[idx].name = name;
    }
    renderTabs();
  }

  function cancelRename() {
    renaming = -1;
    renderTabs();
  }

  // Rebuild the tab strip from `files`/`active`/`renaming`. Called after
  // every mutation -- there is no incremental diffing, the strip is small.
  function renderTabs() {
    tabsEl.innerHTML = "";
    files.forEach(function (f, i) {
      var tab = document.createElement("div");
      tab.className = "tab" + (i === active ? " active" : "");

      var dot = document.createElement("span");
      dot.className = "tab-dot";
      tab.appendChild(dot);

      if (renaming === i) {
        var input = document.createElement("input");
        input.className = "tab-rename";
        input.value = f.name;
        input.spellcheck = false;
        input.addEventListener("keydown", function (ev) {
          ev.stopPropagation();
          if (ev.key === "Enter") { ev.preventDefault(); commitRename(i, input.value); }
          else if (ev.key === "Escape") { ev.preventDefault(); cancelRename(); }
        });
        input.addEventListener("blur", function () { commitRename(i, input.value); });
        input.addEventListener("click", function (ev) { ev.stopPropagation(); });
        tab.appendChild(input);
      } else {
        var label = document.createElement("span");
        label.className = "tab-name";
        label.textContent = f.name;
        tab.appendChild(label);
      }

      if (files.length > 1) {
        var close = document.createElement("button");
        close.type = "button";
        close.className = "tab-close";
        close.textContent = "×";
        close.setAttribute("aria-label", "Close " + f.name);
        close.addEventListener("click", function (ev) {
          ev.stopPropagation();
          closeFile(i);
        });
        tab.appendChild(close);
      }

      tab.addEventListener("click", function () { selectTab(i); });
      tab.addEventListener("dblclick", function () { startRename(i); });
      tabsEl.appendChild(tab);
    });
  }

  addFileBtn.addEventListener("click", addFile);

  /* ---- shared-memory rings (filled in once the worker is ready) --- */

  var HEAD = 0, TAIL = 1, DATA = 2;
  var worker = null;
  var HEAP32 = null;
  var ioReady = false;
  var inBase = 0, inCap = 0;
  var outBase = 0, outCap = 0;
  var outHead = 0;
  var stateBase = 0;   // io-state flag index (set by wasmfs-stdin.js)
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
      if (!editor.hasFocus() && document.activeElement !== inputArea) {
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
    // and leave the namespace bare). Every open tab lands at /tmp/<its
    // name> before main() runs; we require racket/enter and `enter!` the
    // active tab once the REPL is ready (see "ready" below), so siblings
    // resolve by name in the same directory.
    // The persistent home (/home/web_user) is mounted on OPFS by the runtime
    // itself (wasm_shell_io.c); it is durable on close(), so a new
    // process-per-run still sees files an earlier run wrote and closed -- no
    // opt-in flag and no save-on-exit handshake needed.
    var filesPayload = {};
    files.forEach(function (f) {
      filesPayload["/tmp/" + f.name] = f.doc.getValue();
    });
    worker.postMessage({
      type: "init",
      argv: [],
      files: filesPayload,
    });
  }

  function stop() {
    if (!worker) return;
    appendOutput("\n[stopped]\n");
    teardown();
    setControls(false, false);
    setStatus("Stopped", "error");
  }

  // DrRacket's Run shortcut: re-run from scratch even mid-run. teardown()
  // (via stop()) is synchronous, so the current process is gone before
  // run() spawns the next; run()'s clearOutput() wipes the "[stopped]"
  // line, so a restart looks like a clean Run.
  function restart() {
    if (worker) stop();
    run();
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
        // Emscripten's loader status (download progress, "" once all run-
        // dependencies clear) only describes boot. Under -sPROXY_TO_PTHREAD the
        // `ready` message races AHEAD of the final dependency drain, so a last
        // setStatus("") lands after we've shown "Running" and would downgrade
        // the chip back to "Assets loaded". Once the runtime is up (ioReady),
        // ignore all further loader status.
        if (ioReady) return;
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
        //   4. enter! the active tab -- runs its body and lands the REPL in
        //      its namespace -- then, in the SAME form (a begin, so it is
        //      read+compiled in the racket namespace before enter! switches
        //      it), run the entered #lang's `configure-runtime` submodule
        //      if it has one. That is what binds a non-default REPL reader
        //      to `current-read-interaction` (e.g. rhombus's shrubbery
        //      reader), so ide-repl defers to it instead of feeding the
        //      language's surface syntax to its `#%top-interaction` as
        //      s-exprs. Then re-install the bitmap printer so it wraps
        //      whatever `current-print` the language set, keeping picts/
        //      bitmaps rendering at the REPL. Finally, DrRacket/`racket`-style,
        //      run the active tab's `main` submodule if it declared one (e.g.
        //      via `module+`) -- after the printer reinstall, so images it
        //      prints render through the finalized printer too. Everything
        //      after enter! must live inside this begin: once the namespace
        //      has switched, the REPL's `#%top-interaction` is the
        //      language's and would reject these racket forms.
        // The trailing "\n" delimits the submission; the reader installed
        // in step 1 consumes it as the line terminator, leaving the stdin
        // buffer empty for the program's first real `read-line`.
        var entryLit = JSON.stringify(entryPath());
        sendText(
          '(with-handlers ([(lambda (e) #t) void]) ' +
            '((dynamic-require (quote web-repl/ide-repl) (quote install-ide-prompt-read!)))) ' +
          '(require racket/enter) ' +
          '(with-handlers ([(lambda (e) #t) void]) ' +
            '((dynamic-require (quote web-repl/print) (quote install-bitmap-printer!)))) ' +
          '(begin ' +
            '(enter! (file ' + entryLit + ')) ' +
            '(with-handlers ([(lambda (e) #t) void]) ' +
              '(let ([cr (list (quote submod) (list (quote file) ' + entryLit + ') ' +
                              '(quote configure-runtime))]) ' +
                '(when (module-declared? cr #t) (dynamic-require cr #f)))) ' +
            '(with-handlers ([(lambda (e) #t) void]) ' +
              '((dynamic-require (quote web-repl/print) (quote install-bitmap-printer!)))) ' +
            '(with-handlers ([(lambda (e) #t) void]) ' +
              '(let ([m (list (quote submod) (list (quote file) ' + entryLit + ') ' +
                             '(quote main))]) ' +
                '(when (module-declared? m #t) (dynamic-require m #f)))))\n');
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
        // id 0 (or absent) -> ephemeral: append a fresh inline canvas.
        // id > 0 -> addressable: create-or-update a persistent canvas.
        if (msg.id) blitCanvas(msg.id, msg.w, msg.h, msg.pixels);
        else appendCanvas(msg.w, msg.h, msg.pixels);
        return;
      }
      case "canvas-destroy": {
        destroyCanvas(msg.id);
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

  /* ---- examples dropdown ------------------------------------------ */
  /* Seed the Definitions pane from EXAMPLES and let the dropdown swap
   * programs. loadedSnapshot tracks the unedited file set of the current
   * example so we can tell whether the user has touched it; if so, picking
   * another example confirms before discarding their edits. loadedIdx is
   * the dropdown index to revert to on cancel (-1 once a gist replaces the
   * file set -- the dropdown then has nothing "current" to point at). */

  var loadedIdx = -1;
  var loadedSnapshot = null;

  function loadExample(idx) {
    var ex = EXAMPLES[idx];
    if (!ex) return;
    var newFiles = ex.files.map(function (f) {
      return { name: f.name, doc: makeDoc(f.code) };
    });
    var mainIdx = 0;
    for (var i = 0; i < newFiles.length; i++) {
      if (newFiles[i].name === "main.rkt") { mainIdx = i; break; }
    }
    setFiles(newFiles, mainIdx);
    loadedIdx = idx;
    loadedSnapshot = currentSnapshot();
    exampleSel.value = String(idx);
  }

  // Placeholder shown while the open files came from a gist, not a built-in
  // example -- value "" so `exampleSel.value = ""` (see importFilesAsTabs and
  // the revert-on-cancel below) displays it instead of silently leaving
  // whichever example option was last selected showing.
  var gistPlaceholderOpt = document.createElement("option");
  gistPlaceholderOpt.value = "";
  gistPlaceholderOpt.disabled = true;
  gistPlaceholderOpt.textContent = "Custom (from gist)";
  exampleSel.appendChild(gistPlaceholderOpt);

  EXAMPLES.forEach(function (ex, i) {
    var opt = document.createElement("option");
    opt.value = String(i);
    opt.textContent = ex.name;
    exampleSel.appendChild(opt);
  });

  exampleSel.addEventListener("change", function () {
    var idx = parseInt(exampleSel.value, 10);
    if (currentSnapshot() !== loadedSnapshot &&
        !window.confirm("Discard your edits and load “" +
                        EXAMPLES[idx].name + "”?")) {
      exampleSel.value = loadedIdx >= 0 ? String(loadedIdx) : "";
      return;
    }
    if (worker) stop();  // switching examples ends the current run
    loadExample(idx);
    editor.focus();
  });

  /* ---- load-from-gist ---------------------------------------------- */

  var gistOverlay   = document.getElementById("gist-modal-overlay");
  var gistInput     = document.getElementById("gist-input");
  var gistErrorEl   = document.getElementById("gist-error");
  var gistCancelBtn = document.getElementById("gist-cancel");
  var gistImportBtn = document.getElementById("gist-import");
  var gistCloseBtn  = document.getElementById("gist-modal-close");

  // "Clear the interactions menu" for a fresh gist load: stop any live run
  // and put the Interactions pane back in its pre-Run idle state (switching
  // built-in examples only stops the worker today; loading a gist should
  // look like a clean slate).
  function resetInteractions() {
    if (worker) stop();
    clearOutput();
    interactions.classList.add("idle");
    setStatus("Idle", "idle");
  }

  function parseGistId(input) {
    input = input.trim();
    var m = /gist\.github\.com\/(?:[^\/]+\/)?([0-9a-f]+)/i.exec(input);
    if (m) return m[1];
    if (/^[0-9a-f]+$/i.test(input)) return input;
    return null;
  }

  // "shapes.rkt" collides -> "shapes-2.rkt", "shapes-3.rkt", ...
  function dedupeName(name, used) {
    if (!used[name]) { used[name] = true; return name; }
    var m = /^(.*?)(\.[^./]*)?$/.exec(name);
    var base = m[1], ext = m[2] || "";
    var n = 2, candidate;
    do {
      candidate = base + "-" + n + ext;
      n++;
    } while (used[candidate]);
    used[candidate] = true;
    return candidate;
  }

  // Fetch every file in a gist as { name, code }, fetching raw_url for any
  // file GitHub truncated in the summary response. Rejects with an object
  // carrying a user-facing `userMessage` for the modal's error line.
  function loadGistFiles(id) {
    return fetch("https://api.github.com/gists/" + encodeURIComponent(id), {
      headers: { Accept: "application/vnd.github+json" }
    }).then(function (r) {
      if (r.status === 404) return Promise.reject({ userMessage: "No gist found with that ID." });
      if (!r.ok) return Promise.reject({ userMessage: "GitHub returned " + r.status + "." });
      return r.json();
    }).then(function (data) {
      var names = Object.keys(data.files || {});
      if (names.length === 0) return Promise.reject({ userMessage: "That gist has no files." });
      var used = {};
      return Promise.all(names.map(function (name) {
        var file = data.files[name];
        var finalName = dedupeName(file.filename || name, used);
        if (file.truncated) {
          return fetch(file.raw_url).then(function (r) { return r.text(); })
            .then(function (text) { return { name: finalName, code: text }; });
        }
        return { name: finalName, code: file.content };
      }));
    });
  }

  function showGistError(msg) {
    gistErrorEl.textContent = "⚠ " + msg;
    gistErrorEl.hidden = false;
  }
  function clearGistError() {
    gistErrorEl.hidden = true;
    gistErrorEl.textContent = "";
  }
  function openGistModal() {
    gistInput.value = "";
    clearGistError();
    gistOverlay.hidden = false;
    gistInput.focus();
  }
  function closeGistModal() {
    gistOverlay.hidden = true;
  }

  function importFilesAsTabs(fileList, gistId) {
    resetInteractions();
    var newFiles = fileList.map(function (f) {
      return { name: f.name, doc: makeDoc(f.code) };
    });
    setFiles(newFiles, 0);
    loadedIdx = -1;
    loadedSnapshot = currentSnapshot();
    exampleSel.value = "";
    var url = new URL(window.location.href);
    url.searchParams.set("gist", gistId);
    history.replaceState(null, "", url);
  }

  function submitGistImport() {
    var raw = gistInput.value;
    var id = parseGistId(raw);
    if (!raw.trim() || !id) { showGistError("Enter a gist URL or ID."); return; }
    clearGistError();
    gistImportBtn.disabled = true;
    gistImportBtn.textContent = "Importing…";
    loadGistFiles(id).then(function (fileList) {
      importFilesAsTabs(fileList, id);
      closeGistModal();
      editor.focus();
    }).catch(function (err) {
      showGistError((err && err.userMessage) || "Failed to load gist: " + (err && (err.message || err)));
    }).then(function () {
      gistImportBtn.disabled = false;
      gistImportBtn.textContent = "Import";
    });
  }

  gistBtn.addEventListener("click", openGistModal);
  gistCancelBtn.addEventListener("click", closeGistModal);
  gistCloseBtn.addEventListener("click", closeGistModal);
  gistOverlay.addEventListener("click", function (ev) {
    if (ev.target === gistOverlay) closeGistModal();
  });
  gistInput.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter") { ev.preventDefault(); submitGistImport(); }
  });
  document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && !gistOverlay.hidden) closeGistModal();
  });
  gistImportBtn.addEventListener("click", submitGistImport);

  loadExample(0);  // seed immediately so the editor isn't blank while a gist loads

  var gistParam = new URLSearchParams(window.location.search).get("gist");
  if (gistParam) {
    var initialGistId = parseGistId(gistParam) || gistParam;
    loadGistFiles(initialGistId).then(function (fileList) {
      importFilesAsTabs(fileList, initialGistId);
    }).catch(function (err) {
      alert("Failed to load gist from URL: " + ((err && err.userMessage) || (err && err.message) || err));
    });
  }

  /* ---- wiring ----------------------------------------------------- */

  runBtn.addEventListener("click", run);
  runIdleBtn.addEventListener("click", run);
  stopBtn.addEventListener("click", stop);
  evaluateBtn.addEventListener("click", evaluate);

  /* The editor's Cmd/Ctrl+Enter (re-run) and Tab (insert two spaces) are
   * bound via CodeMirror extraKeys above; the REPL input keeps its own
   * keydown handler below. */

  inputArea.addEventListener("keydown", function (ev) {
    // Cmd/Ctrl+Enter submits; plain Enter inserts a newline.
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      evaluate();
    }
  });

  setStatus("Idle", "idle");
})();
