/* wasm_canvas.c -- pixel-buffer-to-canvas primitive for the WASM build.
 *
 * Adds one foreign-callable function, `wasm_canvas_blit`, that copies
 * an RGBA buffer from the runtime worker out to the page so the page
 * can render it onto a <canvas> via putImageData. This is the Tier 1
 * output path used by anything in Racket that generates pixels
 * (manual byte-pushing, a future racket/draw backend, plot, etc.).
 *
 * Calling convention: caller passes width, height, and a pointer to a
 * w*h*4 byte buffer in RGBA8888 order (one row at a time, top-down --
 * the same layout ImageData expects). The worker copies the buffer
 * out into a transferable ArrayBuffer and postMessages it to the page;
 * the page's canvas surface (canvas.js / playground.js) receives it
 * and putImageData's onto its <canvas>.
 *
 * Return value: 0 on success, -1 if not running inside a Worker that
 * can postMessage (e.g. the node CLI build, or any host that hasn't
 * set up a canvas surface).
 *
 * The copy is unavoidable -- transferring the WASM heap itself would
 * detach it from the runtime, and worker->page postMessage requires
 * the buffer to either be transferable or structured-cloned. ArrayBuffer
 * copy + transfer is the fast path (no JSON, no per-pixel JS work).
 *
 * Registered with Sforeign_symbol via wasm_extras.inc, reachable from
 * Racket through `(ffi/unsafe/vm)`'s `vm-eval` + Chez `foreign-procedure`.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __EMSCRIPTEN__
# include <emscripten.h>
#endif

#ifdef __EMSCRIPTEN__

EM_JS(int, wasm_canvas_blit, (int w, int h, const void *rgba),
{
  if (typeof self === "undefined" || typeof self.postMessage !== "function") {
    return -1;
  }
  if (w <= 0 || h <= 0) return -1;
  var bytes = (w * h) << 2;
  var buf = new ArrayBuffer(bytes);
  new Uint8Array(buf).set(HEAPU8.subarray(rgba, rgba + bytes));
  self.postMessage({ type: "canvas", w: w, h: h, pixels: buf }, [buf]);
  return 0;
});

#else

/* Stub for non-Emscripten builds: the table still has the entry so
   programs don't error out before reaching the renderer; calling it
   just reports "no canvas." */
int wasm_canvas_blit(int w, int h, const void *rgba) {
  (void)w; (void)h; (void)rgba;
  return -1;
}

#endif
