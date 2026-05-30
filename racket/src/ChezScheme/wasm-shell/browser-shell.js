/* browser-shell.js -- main-thread driver for the Racket WASM terminal.
 *
 * Architecture (see shell-tty.js and wasm_shell_io.c for the peers):
 *
 *   scheme-web.js is linked with -sPROXY_TO_PTHREAD, so Racket's main()
 *   runs on a Web Worker "compute" thread and THIS page's main thread
 *   stays responsive to drive xterm.js. Console traffic crosses the
 *   thread boundary through two ring buffers in the module's shared
 *   linear memory:
 *
 *     - stdout ring: the compute thread writes bytes; we poll it here
 *       and render to the terminal.
 *     - stdin ring:  we write typed lines here and Atomics.notify the
 *       compute thread, which is blocked in Atomics.wait inside its
 *       TTY get_char.
 *
 *   This avoids the old design's fatal flaw: there, main() ran on the
 *   page's main thread and its blocking stdin read froze the event loop.
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

  /* ---- terminal -> stdin ring (line edited) ---------------------- */

  var pendingLine = "";
  var ioReady = false;
  var ringInBase = 0, ringInCap = 0;
  var ringOutBase = 0, ringOutCap = 0;
  var HEAD = 0, TAIL = 1, DATA = 2;
  var encoder = new TextEncoder();

  function sendBytes(bytes) {
    if (!ioReady) return;
    var H = Module.HEAP32;
    var tail = Atomics.load(H, ringInBase + TAIL);
    for (var i = 0; i < bytes.length; i++) {
      H[ringInBase + DATA + (tail % ringInCap)] = bytes[i];
      tail++;
    }
    Atomics.store(H, ringInBase + TAIL, tail);
    Atomics.notify(H, ringInBase + TAIL);
  }

  function sendText(text) {
    sendBytes(encoder.encode(text));
  }

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
        sendText(""); // Ctrl-D / EOF passthrough
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

  var outHead = 0;
  var outDecoder = new TextDecoder("utf-8");

  function drainOutput() {
    if (!ioReady) return;
    var H = Module.HEAP32;
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

  function tryStartIO() {
    if (ioReady) return true;
    // The ring accessors only exist once the wasm module is instantiated;
    // their presence is a sufficient readiness signal (we deliberately do
    // not gate on Module.calledRun, which may not be set on the page's
    // main thread under PROXY_TO_PTHREAD).
    if (typeof Module === "undefined" ||
        typeof Module["_shell_in_addr"] !== "function" ||
        typeof Module["_shell_out_addr"] !== "function" ||
        !Module["HEAP32"]) {
      return false;
    }
    ringInBase = Module["_shell_in_addr"]() >> 2;
    ringInCap = Module["_shell_in_cap"]();
    ringOutBase = Module["_shell_out_addr"]() >> 2;
    ringOutCap = Module["_shell_out_cap"]();
    outHead = Atomics.load(Module.HEAP32, ringOutBase + HEAD);
    ioReady = true;
    setStatus("Runtime ready", "ready");
    setProgress(1, "Ready");
    requestAnimationFrame(pollLoop);
    term.focus();
    return true;
  }

  /* ---- Emscripten Module wiring ---------------------------------- */

  window.Module = {
    // Output is handled via the ring, not print/printErr, so we leave
    // those undefined (defining them would route the compute thread's
    // console through the postMessage proxy instead).
    locateFile: function (path) { return path; },
    setStatus: function (text) {
      var match = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text || "");
      if (match) {
        var loaded = Number(match[2]);
        var total = Number(match[3]);
        setStatus(match[1].trim() || "Downloading assets", "running");
        setProgress(total > 0 ? loaded / total : 0, loaded + "/" + total);
        return;
      }
      if (!text) {
        setStatus("Assets loaded", "running");
        setProgress(1, "Loaded");
        return;
      }
      setStatus(text, "running");
      downloadElement.textContent = text;
    },
    monitorRunDependencies: function (remaining) {
      if (remaining > 0) {
        setStatus("Preparing runtime", "running");
        downloadElement.textContent = remaining + " dependenc" + (remaining === 1 ? "y" : "ies") + " remaining";
      } else {
        setStatus("Starting runtime", "running");
        downloadElement.textContent = "All downloads complete";
      }
    },
    onRuntimeInitialized: function () {
      // With PROXY_TO_PTHREAD this fires on the main thread once the
      // module is ready; start IO if the exports are visible yet.
      tryStartIO();
    },
    onAbort: function (reason) {
      setStatus("Runtime aborted", "error");
      term.writeln("\r\n[31mRuntime aborted: " + String(reason) + "[0m");
    },
    onExit: function (code) {
      ioReady = false;
      setStatus("Runtime exited (" + code + ")", code === 0 ? "ready" : "error");
      term.writeln("\r\nProcess exited with code " + code + ".");
    }
  };

  // Fallback: onRuntimeInitialized may land before the ring exports are
  // attached to Module, so also retry on a short timer until IO is live.
  var startTimer = setInterval(function () {
    if (tryStartIO()) clearInterval(startTimer);
  }, 50);

  setStatus("Waiting for scheme-web.js", "idle");
  downloadElement.textContent = "Not started";
})();
