/* wasm_canvas.c -- pixel-buffer-to-canvas primitive for the WASM build.
 *
 * Adds foreign-callable functions that copy an RGBA buffer from the
 * runtime worker out to the page so the page can render it onto a
 * <canvas> via putImageData. This is the Tier 1 output path used by
 * anything in Racket that generates pixels (manual byte-pushing, the
 * racket/draw backend, the GUI backend, plot, etc.).
 *
 * Calling convention: caller passes a canvas id, width, height, and a
 * pointer to a w*h*4 byte buffer in RGBA8888 order (one row at a time,
 * top-down -- the same layout ImageData expects). The worker copies the
 * buffer out into a transferable ArrayBuffer and postMessages it to the
 * page; the page's canvas surface (ide.js) receives it and putImageData's
 * it onto a <canvas>.
 *
 * Canvas id contract (the page routes on it):
 *   id == 0  -- ephemeral: append a FRESH <canvas> per blit (REPL pict /
 *               bitmap printing -- a scrollback of inline images).
 *   id  > 0  -- addressable: the page creates the <canvas> on first blit
 *               for that id, then reuses + updates it in place. Each GUI
 *               window / web-repl canvas-window owns one such id, handed
 *               out by `wasm_canvas_alloc_id` (a single global counter so
 *               GUI frames and web-repl windows never collide). Destroy
 *               with `wasm_canvas_destroy`, which posts {type:"canvas-
 *               destroy", id} so the page drops the element.
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

/* Delivery runs on the MAIN browser thread via MAIN_THREAD_EM_ASM, not on
 * whatever thread Racket happens to run on. Under -sPROXY_TO_PTHREAD Racket
 * runs on a child pthread whose `self.postMessage` reaches the shell worker
 * (the pthread's parent), NOT the page -- so the blit would be silently
 * dropped. MAIN_THREAD_EM_ASM proxies the JS to the main thread (the shell
 * worker), whose `self.postMessage` reaches the page; when Racket already runs
 * ON the main thread (no proxy, and the node CLI) it runs inline. The call is
 * synchronous, so the pixel copy out of the (shared, -pthread) heap completes
 * before Racket may reuse the buffer. $0=id $1=w $2=h $3=pixel pointer. */

int wasm_canvas_blit(int id, int w, int h, const void *rgba) {
  /* NB: one `var` per statement -- the C preprocessor protects commas only
     inside parens, not the EM_ASM braces, so `var a=$0, b=$1` would split the
     macro args. */
  return MAIN_THREAD_EM_ASM_INT({
    if (typeof self === "undefined" || typeof self.postMessage !== "function") return -1;
    var id = $0;
    var w = $1;
    var h = $2;
    var rgba = $3;
    if (w <= 0 || h <= 0) return -1;
    var bytes = (w * h) << 2;
    var buf = new ArrayBuffer(bytes);
    new Uint8Array(buf).set(HEAPU8.subarray(rgba, rgba + bytes));
    self.postMessage({ type: "canvas", id: id, w: w, h: h, pixels: buf }, [buf]);
    return 0;
  }, id, w, h, rgba);
}

/* Variant for racket/draw's bitmap% pixel format: `get-argb-pixels`
 * fills bytes in memory order A R G B (one alpha byte then RGB). Canvas
 * putImageData expects R G B A, so we rotate by one byte per pixel.
 * The pixels are non-premultiplied (Racket's documented surface). */
int wasm_canvas_blit_argb(int id, int w, int h, const void *argb) {
  return MAIN_THREAD_EM_ASM_INT({
    if (typeof self === "undefined" || typeof self.postMessage !== "function") return -1;
    var id = $0;
    var w = $1;
    var h = $2;
    var argb = $3;
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
    self.postMessage({ type: "canvas", id: id, w: w, h: h, pixels: buf }, [buf]);
    return 0;
  }, id, w, h, argb);
}

/* Variant for callers whose pixel buffer is in Cairo's CAIRO_FORMAT_ARGB32
 * memory layout, which on little-endian is byte order B G R A. Canvas
 * putImageData expects R G B A, so we swap the red/blue channels during
 * the copy out of the WASM heap. Output is also unpremultiplied: Cairo
 * stores ARGB32 premultiplied (per its convention), and ImageData wants
 * non-premultiplied components. */
int wasm_canvas_blit_bgra(int id, int w, int h, const void *bgra) {
  return MAIN_THREAD_EM_ASM_INT({
    if (typeof self === "undefined" || typeof self.postMessage !== "function") return -1;
    var id = $0;
    var w = $1;
    var h = $2;
    var bgra = $3;
    if (w <= 0 || h <= 0) return -1;
    var bytes = (w * h) << 2;
    var buf = new ArrayBuffer(bytes);
    var dst = new Uint8ClampedArray(buf);
    var src = HEAPU8;
    for (var i = 0, p = bgra; i < bytes; i += 4, p += 4) {
      var b = src[p];
      var g = src[p + 1];
      var r = src[p + 2];
      var a = src[p + 3];
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
    self.postMessage({ type: "canvas", id: id, w: w, h: h, pixels: buf }, [buf]);
    return 0;
  }, id, w, h, bgra);
}

/* Hand out canvas ids from a single global counter, so GUI frames and
 * web-repl canvas-windows share one collision-free id space (the page keys
 * its id->element map on these). 0 is reserved for the ephemeral path, so
 * we start at 1. The runtime is cooperatively scheduled around this call
 * (it runs in ordinary Racket code, not a signal handler), so a plain
 * increment is sufficient. */
static int wasm_canvas_id_counter = 0;
int wasm_canvas_alloc_id(void) {
  return ++wasm_canvas_id_counter;
}

/* Tell the page to drop the <canvas> for `id` (window closed). Posts
 * {type:"canvas-destroy", id}; a no-op for id 0 / ephemeral canvases. */
int wasm_canvas_destroy(int id) {
  return MAIN_THREAD_EM_ASM_INT({
    if (typeof self === "undefined" || typeof self.postMessage !== "function") return -1;
    self.postMessage({ type: "canvas-destroy", id: $0 });
    return 0;
  }, id);
}

#else

/* Stub for non-Emscripten builds: the table still has the entry so
   programs don't error out before reaching the renderer; calling it
   just reports "no canvas." */
int wasm_canvas_blit(int id, int w, int h, const void *rgba) {
  (void)id; (void)w; (void)h; (void)rgba;
  return -1;
}
int wasm_canvas_blit_bgra(int id, int w, int h, const void *bgra) {
  (void)id; (void)w; (void)h; (void)bgra;
  return -1;
}
int wasm_canvas_blit_argb(int id, int w, int h, const void *argb) {
  (void)id; (void)w; (void)h; (void)argb;
  return -1;
}
int wasm_canvas_alloc_id(void) {
  static int counter = 0;
  return ++counter;
}
int wasm_canvas_destroy(int id) {
  (void)id;
  return -1;
}

#endif
