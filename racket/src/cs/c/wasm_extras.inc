/* wasm_extras.inc -- foreign-symbol registrations injected into
   boot.c's init_foreign for the WASM/Emscripten build (gated by
   -DRACKET_EXTRA_FOREIGN_INC=\"wasm_extras.inc\"). Each line
   registers one C symbol so it's reachable from Racket via
   foreign-procedure / get-ffi-obj, the same way rktio.inc registers
   the rktio surface. Add new wasm-specific primitives here. */

{
  extern int wasm_http_get(const char *, void *, int);
  Sforeign_symbol("wasm_http_get",  (void *)wasm_http_get);
}
