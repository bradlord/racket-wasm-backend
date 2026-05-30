/* browser-shell.js -- main-thread driver for the Racket WASM terminal.
 *
 * Architecture (see shell-worker.js, shell-tty.js, wasm_shell_io.c):
 *
 *   We spawn a dedicated Web Worker (shell-worker.js) that loads
 *   scheme-web.js and runs Racket's `main()` on its own thread. The
 *   page's main thread (this file) stays free to drive xterm.js.
 *   The two threads exchange console bytes through two ring buffers
 *   placed in the module's *shared* linear memory:
 *
 *     - stdin ring:  we write typed lines here and Atomics.notify the
 *                    worker, which is blocked in Atomics.wait inside
 *                    its TTY get_char (see shell-tty.js).
 *     - stdout ring: the worker writes bytes; we poll it here each
 *                    animation frame and render to the terminal.
 *
 *   This replaces the previous -sPROXY_TO_PTHREAD design, where
 *   Emscripten itself spawned the runtime thread but proxied FS
 *   syscalls (including stdin reads) back to the page's main thread,
 *   forcing a non-blocking, busy-polling stdin. By owning the worker
 *   ourselves, get_char actually runs on the worker and can block.
 *
 * Line editing: we don't send keystrokes raw -- we maintain a local
 * edit buffer with cursor, history, and a small kill ring, redraw the
 * editable region in place via ANSI escapes, and only push the line
 * across the ring to Racket on Enter. Recognized keys: arrows, Home,
 * End, Delete, Backspace, Ctrl-A/E/B/F/K/U/W/Y/L/P/N, Ctrl-C, Ctrl-D.
 * Multi-line wrap inside an edit isn't redrawn correctly; treat that as
 * a known limitation (a long line is fine, just edits past the wrap may
 * smudge).
 */
(function () {
  "use strict";

  var statusElement = document.getElementById("runtime-status");
  var downloadElement = document.getElementById("download-status");
  var progressBar = document.getElementById("progress-bar");
  var runtimeChip = document.getElementById("runtime-chip");
  var focusButton = document.getElementById("focus-terminal");
  var reloadButton = document.getElementById("reload-runtime");
  var clearButton = document.getElementById("clear-terminal");
  var terminalHost = document.getElementById("terminal");

  var term = new Terminal({
    cols: 100,
    rows: 32,
    cursorBlink: true,
    convertEol: true,
    fontFamily: '"IBM Plex Mono", "SFMono-Regular", Consolas, monospace',
    fontSize: 15,
    lineHeight: 1.35,
    theme: {
      background: "#081018",
      foreground: "#e6edf3",
      cursor: "#f59e0b",
      selectionBackground: "rgba(56, 189, 248, 0.28)",
      black: "#081018",
      red: "#f87171",
      green: "#4ade80",
      yellow: "#fbbf24",
      blue: "#60a5fa",
      magenta: "#c084fc",
      cyan: "#22d3ee",
      white: "#e6edf3",
      brightBlack: "#546273",
      brightWhite: "#ffffff"
    }
  });
  term.open(terminalHost);
  term.focus();

  function setStatus(text, state) {
    statusElement.textContent = text;
    statusElement.dataset.state = state || "idle";
    runtimeChip.textContent = text;
  }

  function setProgress(ratio, text) {
    var clamped = Math.max(0, Math.min(1, ratio));
    progressBar.style.width = Math.round(clamped * 100) + "%";
    if (text) {
      downloadElement.textContent = text;
    }
  }

  var ESC_CSI = "[";

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SharedArrayBuffer unavailable", "error");
    term.writeln(ESC_CSI + "31mThis page is not cross-origin isolated, so");
    term.writeln("SharedArrayBuffer is unavailable and the runtime cannot start." + ESC_CSI + "0m");
    term.writeln("");
    term.writeln("Serve this directory with COOP/COEP headers, e.g.:");
    term.writeln("  " + ESC_CSI + "36mpython3 serve.py" + ESC_CSI + "0m   (see wasm-shell/serve.py)");
    return;
  }

  term.writeln("Racket WASM shell initialized.");
  term.writeln("Loading runtime assets...");
  term.writeln("");

  /* ---- shared-memory rings (filled in once the worker is ready) -- */

  var HEAD = 0, TAIL = 1, DATA = 2;
  var HEAP32 = null;
  var ioReady = false;
  var ringInBase = 0, ringInCap = 0;
  var ringOutBase = 0, ringOutCap = 0;
  var outHead = 0;
  var encoder = new TextEncoder();
  var outDecoder = new TextDecoder("utf-8");

  /* ---- terminal -> stdin ring ------------------------------------ */

  // Line editor state. `lineBuf` is the in-progress line; `cursor` is
  // the 0-based column within `lineBuf` where the caret sits. The
  // editable region starts at whatever column the cursor was at when
  // editing began (typically right after Racket printed "> "); we never
  // need to know that column because every move/redraw is relative.
  var lineBuf = "";
  var cursor = 0;
  var history = [];
  var histIdx = 0;        // 0 = live line, 1..history.length = back N
  var histSaved = "";     // live line stashed while navigating history
  var killRing = "";

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
    debug("send " + bytes.length + "B, in.tail=" + tail +
          ", in.head(observed)=" + Atomics.load(H, ringInBase + HEAD));
    schedulePeek();
  }

  function sendText(text) { sendBytes(encoder.encode(text)); }

  /* ---- on-page diagnostics --------------------------------------- */

  var debugList = document.getElementById("debug-log");
  var debugLines = [];
  function debug(msg) {
    if (!debugList) { console.log("[shell]", msg); return; }
    debugLines.push("[" + new Date().toISOString().substr(11, 12) + "] " + msg);
    if (debugLines.length > 40) debugLines.shift();
    debugList.textContent = debugLines.join("\n");
  }

  // After we send bytes, poll the input ring's HEAD a few times: if it
  // advances, the worker is reading from the same shared buffer we are
  // writing to (the page<->worker memory wiring is correct). If HEAD
  // stays stuck, the worker is blocked but cannot see our writes.
  var peekTimer = null;
  function schedulePeek() {
    if (!ioReady || peekTimer) return;
    var ticks = 0;
    peekTimer = setInterval(function () {
      ticks++;
      var head = Atomics.load(HEAP32, ringInBase + HEAD);
      var tail = Atomics.load(HEAP32, ringInBase + TAIL);
      debug("peek " + ticks + ": in.head=" + head + " in.tail=" + tail +
            (head === tail ? " (drained)" : " (still pending " + (tail - head) + ")"));
      if (head === tail || ticks > 8) {
        clearInterval(peekTimer);
        peekTimer = null;
      }
    }, 250);
  }

  /* ---- line editor primitives ----------------------------------- */

  // Repaint the editable region after a content change. `prevCursor`
  // is the column the cursor was on before the edit (the caller has
  // already updated `lineBuf` and `cursor`).
  function redraw(prevCursor) {
    var out = "";
    if (prevCursor > 0) out += ESC_CSI + prevCursor + "D";
    out += ESC_CSI + "K" + lineBuf;
    var trailing = lineBuf.length - cursor;
    if (trailing > 0) out += ESC_CSI + trailing + "D";
    term.write(out);
  }

  function moveCursor(delta) {
    var nc = cursor + delta;
    if (nc < 0) nc = 0;
    if (nc > lineBuf.length) nc = lineBuf.length;
    var diff = nc - cursor;
    if (diff > 0)      term.write(ESC_CSI + diff + "C");
    else if (diff < 0) term.write(ESC_CSI + (-diff) + "D");
    cursor = nc;
  }

  function insertText(str) {
    if (!str) return;
    var prev = cursor;
    lineBuf = lineBuf.slice(0, cursor) + str + lineBuf.slice(cursor);
    cursor += str.length;
    redraw(prev);
  }

  function deleteBack(n) {
    if (cursor === 0 || n <= 0) return;
    n = Math.min(n, cursor);
    var prev = cursor;
    lineBuf = lineBuf.slice(0, cursor - n) + lineBuf.slice(cursor);
    cursor -= n;
    redraw(prev);
  }

  function deleteForward(n) {
    if (cursor >= lineBuf.length || n <= 0) return;
    n = Math.min(n, lineBuf.length - cursor);
    var prev = cursor;
    lineBuf = lineBuf.slice(0, cursor) + lineBuf.slice(cursor + n);
    redraw(prev);
  }

  function killToEol() {
    if (cursor >= lineBuf.length) return;
    var prev = cursor;
    killRing = lineBuf.slice(cursor);
    lineBuf = lineBuf.slice(0, cursor);
    redraw(prev);
  }

  function killToBol() {
    if (cursor === 0) return;
    var prev = cursor;
    killRing = lineBuf.slice(0, cursor);
    lineBuf = lineBuf.slice(cursor);
    cursor = 0;
    redraw(prev);
  }

  function killWordBack() {
    if (cursor === 0) return;
    var i = cursor;
    while (i > 0 && !/\w/.test(lineBuf[i - 1])) i--;
    while (i > 0 &&  /\w/.test(lineBuf[i - 1])) i--;
    var prev = cursor;
    killRing = lineBuf.slice(i, cursor);
    lineBuf = lineBuf.slice(0, i) + lineBuf.slice(cursor);
    cursor = i;
    redraw(prev);
  }

  function setLine(s) {
    var prev = cursor;
    lineBuf = s;
    cursor = s.length;
    redraw(prev);
  }

  // History nav is only allowed when the current line is empty: in the
  // middle of a multi-line expression (which Racket sees one line at a
  // time, since we send on Enter), an in-place ↑ would clobber the
  // user's in-progress text with the previous *line* of history -- not
  // the previous expression -- and there's no way to put the half-typed
  // text back. Until we do real multi-line buffering on the page side,
  // make ↑/↓ no-ops when there's anything to clobber.
  function historyBack() {
    if (lineBuf.length !== 0) return;
    if (histIdx >= history.length) return;
    if (histIdx === 0) histSaved = "";
    histIdx++;
    setLine(history[history.length - histIdx]);
  }
  function historyForward() {
    if (histIdx === 0) return;
    histIdx--;
    setLine(histIdx === 0 ? histSaved : history[history.length - histIdx]);
  }

  function acceptLine() {
    var line = lineBuf;
    term.write("\r\n");
    sendText(line + "\n");
    if (line.length > 0 &&
        (history.length === 0 || history[history.length - 1] !== line)) {
      history.push(line);
      if (history.length > 200) history.shift();
    }
    lineBuf = "";
    cursor = 0;
    histIdx = 0;
    histSaved = "";
  }

  // Parse xterm input into edit commands. xterm sends a string per
  // input event that may contain plain characters, single control
  // bytes, or CSI sequences (ESC [ params final-byte).
  function handleTerminalInput(data) {
    var i = 0;
    while (i < data.length) {
      var c = data.charCodeAt(i);

      // CSI escape sequence: ESC '[' params final
      if (c === 0x1b && data.charAt(i + 1) === "[") {
        var j = i + 2;
        var params = "";
        while (j < data.length) {
          var d = data.charCodeAt(j);
          if (d >= 0x30 && d <= 0x39) { params += data.charAt(j); j++; }
          else break;
        }
        if (j >= data.length) { i = data.length; break; }
        var fin = data.charAt(j);
        switch (fin) {
          case "A": historyBack();    break;
          case "B": historyForward(); break;
          case "C": moveCursor(+1);   break;
          case "D": moveCursor(-1);   break;
          case "H": moveCursor(-cursor); break;
          case "F": moveCursor(lineBuf.length - cursor); break;
          case "~":
            if (params === "1" || params === "7") moveCursor(-cursor);
            else if (params === "4" || params === "8") moveCursor(lineBuf.length - cursor);
            else if (params === "3") deleteForward(1);
            break;
        }
        i = j + 1;
        continue;
      }

      // Single-byte control characters.
      if (c === 0x0d || c === 0x0a) { acceptLine();  i++; continue; }    // Enter
      if (c === 0x7f || c === 0x08) { deleteBack(1); i++; continue; }    // Backspace
      if (c === 0x01) { moveCursor(-cursor); i++; continue; }            // Ctrl-A
      if (c === 0x05) { moveCursor(lineBuf.length - cursor); i++; continue; } // Ctrl-E
      if (c === 0x02) { moveCursor(-1); i++; continue; }                 // Ctrl-B
      if (c === 0x06) { moveCursor(+1); i++; continue; }                 // Ctrl-F
      if (c === 0x0b) { killToEol();    i++; continue; }                 // Ctrl-K
      if (c === 0x15) { killToBol();    i++; continue; }                 // Ctrl-U
      if (c === 0x17) { killWordBack(); i++; continue; }                 // Ctrl-W
      if (c === 0x19) { insertText(killRing); i++; continue; }           // Ctrl-Y
      if (c === 0x0c) { term.write(ESC_CSI + "2J" + ESC_CSI + "H"); redraw(0); i++; continue; } // Ctrl-L
      if (c === 0x10) { historyBack();    i++; continue; }               // Ctrl-P
      if (c === 0x0e) { historyForward(); i++; continue; }               // Ctrl-N
      if (c === 0x03) {                                                   // Ctrl-C
        term.write("^C\r\n");
        lineBuf = ""; cursor = 0; histIdx = 0; histSaved = "";
        i++; continue;
      }
      if (c === 0x04) {                                                   // Ctrl-D
        if (lineBuf.length === 0) sendText("");
        else deleteForward(1);
        i++; continue;
      }
      if (c === 0x1b) { i++; continue; }   // bare ESC

      // Run of plain printables, inserted as one block.
      if (c >= 0x20 && c !== 0x7f) {
        var k = i + 1;
        while (k < data.length) {
          var dc = data.charCodeAt(k);
          if (dc < 0x20 || dc === 0x7f || dc === 0x1b) break;
          k++;
        }
        insertText(data.slice(i, k));
        i = k;
        continue;
      }

      i++;   // unknown control: skip
    }
  }

  term.onData(function (data) {
    debug("onData " + JSON.stringify(data));
    handleTerminalInput(data);
  });

  focusButton.addEventListener("click", function () { term.focus(); });
  clearButton.addEventListener("click", function () { term.clear(); });
  reloadButton.addEventListener("click", function () { window.location.reload(); });

  /* ---- stdout ring -> terminal (polled) -------------------------- */

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
    if (text) term.write(text);
  }

  function pollLoop() {
    drainOutput();
    requestAnimationFrame(pollLoop);
  }

  /* ---- worker wiring --------------------------------------------- */

  setStatus("Spawning runtime worker", "running");
  downloadElement.textContent = "Starting";

  var worker;
  try {
    worker = new Worker("./shell-worker.js");
  } catch (err) {
    setStatus("Failed to spawn worker", "error");
    term.writeln("\r\n" + ESC_CSI + "31mFailed to spawn runtime worker: " + String(err) + ESC_CSI + "0m");
    return;
  }

  worker.onerror = function (event) {
    setStatus("Runtime worker error", "error");
    term.writeln("\r\n" + ESC_CSI + "31mWorker error: " + (event.message || event) + ESC_CSI + "0m");
  };

  worker.onmessage = function (event) {
    var msg = event.data;
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case "status": {
        var text = msg.text || "";
        var match = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text);
        if (match) {
          var loaded = Number(match[2]);
          var total = Number(match[3]);
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
      case "ready": {
        var sab = msg.heap;
        HEAP32 = new Int32Array(sab);
        ringInBase = msg.inBase;
        ringInCap = msg.inCap;
        ringOutBase = msg.outBase;
        ringOutCap = msg.outCap;
        outHead = Atomics.load(HEAP32, ringOutBase + HEAD);
        ioReady = true;
        debug("ready: SAB type=" + (sab && sab.constructor && sab.constructor.name) +
              " bytes=" + (sab && sab.byteLength) +
              " inBase=" + ringInBase + " inCap=" + ringInCap +
              " outBase=" + ringOutBase + " outCap=" + ringOutCap);
        setStatus("Runtime ready", "ready");
        setProgress(1, "Ready");
        requestAnimationFrame(pollLoop);
        term.focus();
        return;
      }
      case "abort": {
        ioReady = false;
        setStatus("Runtime aborted", "error");
        term.writeln("\r\n" + ESC_CSI + "31mRuntime aborted: " + msg.reason + ESC_CSI + "0m");
        return;
      }
      case "exit": {
        ioReady = false;
        setStatus("Runtime exited (" + msg.code + ")", msg.code === 0 ? "ready" : "error");
        term.writeln("\r\nProcess exited with code " + msg.code + ".");
        return;
      }
    }
  };
})();
