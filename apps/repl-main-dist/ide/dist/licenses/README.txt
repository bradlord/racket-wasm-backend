racket-wasm license notice
==========================

This project (racket-wasm) is licensed under the MIT License; its full text is
in `racket-wasm-MIT.txt` in this directory.

The distributed runtime bundles other software, each under its own license. The
full texts are included here:

  * racket/  -- upstream Racket and the Chez Scheme runtime it embeds
                (Apache 2.0, MIT, LGPL, GPL, and the libscheme license).
  * deps/    -- the native C libraries linked into the WebAssembly runtime
                (always libffi; the cairo/pango drawing stack and others when
                the build selects them). One subdirectory per bundled library.

Your use of the distributed runtime is subject to all of the above licenses.