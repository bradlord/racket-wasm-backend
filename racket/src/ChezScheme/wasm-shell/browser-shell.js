(function () {
  const statusElement = document.getElementById("runtime-status");
  const downloadElement = document.getElementById("download-status");
  const progressBar = document.getElementById("progress-bar");
  const runtimeChip = document.getElementById("runtime-chip");
  const focusButton = document.getElementById("focus-terminal");
  const reloadButton = document.getElementById("reload-runtime");
  const clearButton = document.getElementById("clear-terminal");
  const terminalHost = document.getElementById("terminal");

  const term = new Terminal({
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
  term.writeln("Racket WASM shell initialized.");
  term.writeln("Loading runtime assets...");
  term.writeln("");

  const inputQueue = [];
  let pendingLine = "";

  function setStatus(text, state) {
    statusElement.textContent = text;
    statusElement.dataset.state = state || "idle";
    runtimeChip.textContent = text;
  }

  function setProgress(ratio, text) {
    const clamped = Math.max(0, Math.min(1, ratio));
    progressBar.style.width = `${Math.round(clamped * 100)}%`;
    if (text) {
      downloadElement.textContent = text;
    }
  }

  function enqueueInput(text) {
    const bytes = new TextEncoder().encode(text);
    for (const byte of bytes) {
      inputQueue.push(byte);
    }
  }

  function handleTerminalInput(data) {
    for (const chunk of data) {
      if (chunk === "\r") {
        term.write("\r\n");
        enqueueInput(`${pendingLine}\n`);
        pendingLine = "";
        continue;
      }

      if (chunk === "\u007f") {
        if (pendingLine.length > 0) {
          pendingLine = pendingLine.slice(0, -1);
          term.write("\b \b");
        }
        continue;
      }

      if (chunk === "\u0003") {
        pendingLine = "";
        term.write("^C\r\n");
        enqueueInput("\u0003");
        continue;
      }

      if (chunk >= " ") {
        pendingLine += chunk;
        term.write(chunk);
      }
    }
  }

  term.onData(handleTerminalInput);

  focusButton.addEventListener("click", function () {
    term.focus();
  });

  clearButton.addEventListener("click", function () {
    term.clear();
  });

  reloadButton.addEventListener("click", function () {
    window.location.reload();
  });

  function makeByteWriter(prefix, color) {
    const decoder = new TextDecoder();
    let atLineStart = true;

    return function (value) {
      if (value === null || value === undefined || value === 0) {
        return;
      }

      const text = decoder.decode(new Uint8Array([value]), { stream: true });
      if (!text) {
        return;
      }

      for (const part of text) {
        if (atLineStart && prefix) {
          term.write(`\u001b[${color}m${prefix}\u001b[0m `);
          atLineStart = false;
        }

        if (part === "\n") {
          term.write("\r\n");
          atLineStart = true;
        } else {
          term.write(part);
        }
      }
    };
  }

  const writeStdout = makeByteWriter("", "0");
  const writeStderr = makeByteWriter("stderr", "31");

  window.Module = {
    stdin: function () {
      if (inputQueue.length === 0) {
        return undefined;
      }
      return inputQueue.shift();
    },
    stdout: writeStdout,
    stderr: writeStderr,
    print: function () {
      const text = Array.prototype.join.call(arguments, " ");
      if (text) {
        term.writeln(text);
      }
      console.log(text);
    },
    printErr: function () {
      const text = Array.prototype.join.call(arguments, " ");
      if (text) {
        term.writeln(`\u001b[31m${text}\u001b[0m`);
      }
      console.error(text);
    },
    setStatus: function (text) {
      const match = /^(.*)\((\d+(?:\.\d+)?)\/(\d+)\)$/.exec(text || "");
      if (match) {
        const loaded = Number(match[2]);
        const total = Number(match[3]);
        setStatus(match[1].trim() || "Downloading assets", "running");
        setProgress(total > 0 ? loaded / total : 0, `${loaded}/${total}`);
        return;
      }

      if (!text) {
        setStatus("Runtime ready", "ready");
        setProgress(1, "Complete");
        return;
      }

      setStatus(text, "running");
      downloadElement.textContent = text;
    },
    monitorRunDependencies: function (remaining) {
      if (remaining > 0) {
        setStatus("Preparing runtime", "running");
        downloadElement.textContent = `${remaining} dependency${remaining === 1 ? "" : "ies"} remaining`;
      } else {
        setStatus("Starting runtime", "running");
        downloadElement.textContent = "All downloads complete";
      }
    },
    onRuntimeInitialized: function () {
      setStatus("Runtime initialized", "ready");
      setProgress(1, "Initialized");
      term.writeln("\r\nRuntime initialized. Terminal is ready.");
      term.focus();
    },
    onAbort: function (reason) {
      setStatus("Runtime aborted", "error");
      term.writeln(`\r\n\u001b[31mRuntime aborted: ${String(reason)}\u001b[0m`);
    },
    onExit: function (code) {
      setStatus(`Runtime exited (${code})`, code === 0 ? "ready" : "error");
      term.writeln(`\r\nProcess exited with code ${code}.`);
    }
  };

  setStatus("Waiting for scheme.js", "idle");
  downloadElement.textContent = "Not started";
})();