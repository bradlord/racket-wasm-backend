/* wasm_stubs.c
 *
 * Placeholder for symbols racket/draw (and similar packages) try to
 * resolve at module-load time from libraries that aren't yet linked
 * into the WASM build -- e.g. libjpeg, expat, fontconfig, pango when
 * those phases haven't landed. Registering each missing name to this
 * single stub lets `(require racket/draw)` complete; calling code
 * that actually exercises those functions then fails with a NULL
 * return / crash, which is the right "not implemented" signal until
 * we add the real library.
 *
 * Used together with wasm_extras.inc hand-written Sforeign_symbol
 * lines that bind missing names to wasm_unimplemented_stub. Each new
 * load-time failure (`could not find export from foreign library`)
 * gets added there as it's hit -- no compile-time list to maintain.
 */

#ifdef __EMSCRIPTEN__
# include <emscripten.h>
#endif

#ifndef EMSCRIPTEN_KEEPALIVE
# define EMSCRIPTEN_KEEPALIVE
#endif

EMSCRIPTEN_KEEPALIVE
void *wasm_unimplemented_stub(void) {
  return 0;
}

/* Passthrough variant: returns its first arg. Some library init
   probes (notably draw-lib's JPEG_LIB_VERSION detection) call a
   function with a non-null pointer expecting the same pointer back.
   A NULL-returning stub fails the FFI's non-null type contract;
   passthrough makes the type contract pass and lets the probe
   handle the "no real library" case via its existing exception
   handler. */
EMSCRIPTEN_KEEPALIVE
void *wasm_passthrough_stub(void *p) {
  return p;
}


