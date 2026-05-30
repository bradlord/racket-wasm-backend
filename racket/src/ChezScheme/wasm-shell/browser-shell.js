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

  if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined") {
    setStatus("SharedArrayBuffer unavailable", "error");
    term.writeln("[31mThis page is not cross-origin isolated, so");
    term.writeln("SharedArrayBuffer is unavailable and the runtime cannot start.[0m");
    term.writeln("");
    term.writeln("Serve this directory with COOP/COEP headers, e.g.:");
    term.writeln("  [36mpython3 serve.py[0m   (see wasm-shell/serve.py)");
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

  var pendingLine = "";

  function sendBytes(bytes) {
    if (!ioReady) return;
    var H = HEAP32;
    var tail = Atomics.load(H, ringInBase + TAIL);
    for (var i = 0; i < bytes.length; i++) {
      H[ringInBase + DATA + (tail % ringInCap)] = bytes[i];
      tail++;
    }
    Atomics.store(H, ringInBase + TAIL, tail);
    Atomics.notify(H, ringInBase + TAIL);
  }

  function sendText(text) { sendBytes(encoder.encode(text)); }

  function handleTerminalInput(data) {
    for (var i = 0; i < data.length; i++) {
      var chunk = data[i];
      if (chunk === "\r") {
        term.write("\r\n");
        sendText(pendingLine + "\n");
        pendingLine = "";
      } else if (chunk === "") {
        if (pendingLine.length > 0) {
          pendingLine = pendingLine.slice(0, -1);
          term.write("\b \b");
        }
      } else if (chunk === "") {
        pendingLine = "";
        term.write("^C\r\n");
        sendText("");
      } else if (chunk === "") {
        sendText("");
      } else if (chunk >= " ") {
        pendingLine += chunk;
        term.write(chunk);
      }
    }
  }

  term.onData(handleTerminalInput);

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
    term.writeln("\r\n[31mFailed to spawn runtime worker: " + String(err) + "[0m");
    return;
  }

  worker.onerror = function (event) {
    setStatus("Runtime worker error", "error");
    term.writeln("\r\n[31mWorker error: " + (event.message || event) + "[0m");
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
        HEAP32 = new Int32Array(msg.heap);
        ringInBase = msg.inBase;
        ringInCap = msg.inCap;
        ringOutBase = msg.outBase;
        ringOutCap = msg.outCap;
        outHead = Atomics.load(HEAP32, ringOutBase + HEAD);
        ioReady = true;
        setStatus("Runtime ready", "ready");
        setProgress(1, "Ready");
        requestAnimationFrame(pollLoop);
        term.focus();
        return;
      }
      case "abort": {
        ioReady = false;
        setStatus("Runtime aborted", "error");
        term.writeln("\r\n[31mRuntime aborted: " + msg.reason + "[0m");
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
