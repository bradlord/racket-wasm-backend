#!/usr/bin/env python3
"""Static file server that sets the headers SharedArrayBuffer requires.

The Racket WASM browser shell links with shared memory + pthreads, so the
page must be "cross-origin isolated": that needs

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

A plain `python3 -m http.server` does not send these, so SharedArrayBuffer
is unavailable and the runtime never starts. Run this from the directory
that holds browser-shell.html and the generated scheme-web.* assets:

    python3 serve.py [port]      # default port 8123

then open http://127.0.0.1:<port>/browser-shell.html
"""

import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class COIHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # The .wasm/.data are same-origin; require-corp is satisfied, but be
        # explicit and discourage caching during development.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def guess_type(self, path):
        if path.endswith(".wasm"):
            return "application/wasm"
        return super().guess_type(path)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8123
    server = ThreadingHTTPServer(("127.0.0.1", port), COIHandler)
    print(f"Serving cross-origin-isolated on http://127.0.0.1:{port}/")
    print(f"Open http://127.0.0.1:{port}/browser-shell.html")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
