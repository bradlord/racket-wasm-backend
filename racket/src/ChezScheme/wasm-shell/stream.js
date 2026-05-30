#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const moduleConfig = global.Module || {};

const originalReadSync = fs.readSync.bind(fs);

function makeInput() {
  const buffer = Buffer.alloc(256);
  let pending = [];
  let ttyFd = null;
  let stdinFd = null;
  let reported = false;

  function report(message) {
    if (reported) {
      return;
    }

    reported = true;

    try {
      fs.writeSync(process.stderr.fd, `[stream.js] ${message}\n`);
    } catch (_error) {
    }
  }

  if (process.stdin.isTTY) {
    try {
      ttyFd = fs.openSync("/dev/tty", "r");
      process.on("exit", function () {
        if (ttyFd !== null) {
          try {
            fs.closeSync(ttyFd);
          } catch (_error) {
          }
        }
      });
    } catch (_error) {
      ttyFd = null;
    }
  }

  try {
    stdinFd = process.stdin.fd;
  } catch (error) {
    report(`process.stdin.fd failed during setup: ${error && error.stack ? error.stack : String(error)}`);
    stdinFd = null;
  }

  fs.readSync = function (fd, targetBuffer, offset, length, position) {
    const useTTY = ttyFd !== null && stdinFd !== null && fd === stdinFd && position == null;

    try {
      return originalReadSync(useTTY ? ttyFd : fd, targetBuffer, offset, length, position);
    } catch (error) {
      if (useTTY) {
        report(`global readSync redirect failed: ${error && error.stack ? error.stack : String(error)}`);
      }
      throw error;
    }
  };

  function refillFromFd(fd) {
    while (pending.length === 0) {
      try {
        const bytesRead = fs.readSync(fd, buffer, 0, buffer.length, null);
        if (bytesRead <= 0) {
          return null;
        }

        pending = Array.from(buffer.subarray(0, bytesRead));
      } catch (error) {
        const code = error && error.code;

        if (String(error).includes("EOF")) {
          return null;
        }

        if (code === "EINTR" || code === "EAGAIN") {
          continue;
        }

        if (fd === ttyFd && (code === "ENXIO" || code === "ENOTTY" || code === "EBADF")) {
          report(`tty read fallback disabled after ${code}`);
          ttyFd = null;
          return null;
        }

        report(`readSync failed on fd ${fd}: ${error && error.stack ? error.stack : String(error)}`);
        return null;
      }
    }

    return pending.shift();
  }

  return function () {
    try {
      if (pending.length === 0) {
        if (ttyFd !== null) {
          return refillFromFd(ttyFd);
        }

        if (stdinFd !== null) {
          return refillFromFd(stdinFd);
        }

        return null;
      }

      return pending.shift();
    } catch (error) {
      report(`stdin callback threw: ${error && error.stack ? error.stack : String(error)}`);
      return null;
    }
  };
}

function makeWriter(stream) {
  return function (value) {
    if (value === null || value === undefined) {
      return;
    }

    stream.write(Buffer.from([value]));
  };
}

moduleConfig.stdin = makeInput();
moduleConfig.stdout = makeWriter(process.stdout);
moduleConfig.stderr = makeWriter(process.stderr);
moduleConfig.arguments = process.argv.slice(2);
moduleConfig.thisProgram = path.join(__dirname, "stream.js");
moduleConfig.mainScriptUrlOrBlob = path.join(__dirname, "stream.js");

global.Module = moduleConfig;

require("./scheme.js");
