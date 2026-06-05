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
 * the page's canvas surface (ide.js) receives it and putImageData's
 * onto a fresh <canvas> appended to the output.
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
#include <string.h>

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

/* Variant for racket/draw's bitmap% pixel format: `get-argb-pixels`
 * fills bytes in memory order A R G B (one alpha byte then RGB). Canvas
 * putImageData expects R G B A, so we rotate by one byte per pixel.
 * The pixels are non-premultiplied (Racket's documented surface). */
EM_JS(int, wasm_canvas_blit_argb, (int w, int h, const void *argb),
{
  if (typeof self === "undefined" || typeof self.postMessage !== "function") {
    return -1;
  }
  if (w <= 0 || h <= 0) return -1;
  var bytes = (w * h) << 2;
  var buf = new ArrayBuffer(bytes);
  var dst = new Uint8Array(buf);
  var src = HEAPU8;
  for (var i = 0, p = argb; i < bytes; i += 4, p += 4) {
    dst[i]     = src[p + 1];   // R
    dst[i + 1] = src[p + 2];   // G
    dst[i + 2] = src[p + 3];   // B
    dst[i + 3] = src[p];       // A
  }
  self.postMessage({ type: "canvas", w: w, h: h, pixels: buf }, [buf]);
  return 0;
});

/* Variant for callers whose pixel buffer is in Cairo's CAIRO_FORMAT_ARGB32
 * memory layout, which on little-endian is byte order B G R A. Canvas
 * putImageData expects R G B A, so we swap the red/blue channels during
 * the copy out of the WASM heap. Output is also unpremultiplied: Cairo
 * stores ARGB32 premultiplied (per its convention), and ImageData wants
 * non-premultiplied components. */
EM_JS(int, wasm_canvas_blit_bgra, (int w, int h, const void *bgra),
{
  if (typeof self === "undefined" || typeof self.postMessage !== "function") {
    return -1;
  }
  if (w <= 0 || h <= 0) return -1;
  var bytes = (w * h) << 2;
  var buf = new ArrayBuffer(bytes);
  var dst = new Uint8ClampedArray(buf);
  var src = HEAPU8;
  for (var i = 0, p = bgra; i < bytes; i += 4, p += 4) {
    var b = src[p],
        g = src[p + 1],
        r = src[p + 2],
        a = src[p + 3];
    if (a !== 0 && a !== 255) {
      // Un-premultiply: ImageData wants straight RGBA.
      var inv = 255 / a;
      r = (r * inv) | 0; if (r > 255) r = 255;
      g = (g * inv) | 0; if (g > 255) g = 255;
      b = (b * inv) | 0; if (b > 255) b = 255;
    }
    dst[i]     = r;
    dst[i + 1] = g;
    dst[i + 2] = b;
    dst[i + 3] = a;
  }
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
int wasm_canvas_blit_bgra(int w, int h, const void *bgra) {
  (void)w; (void)h; (void)bgra;
  return -1;
}
int wasm_canvas_blit_argb(int w, int h, const void *argb) {
  (void)w; (void)h; (void)argb;
  return -1;
}

#endif
