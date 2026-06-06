/* init_rktio.c
 *
 * Registers every symbol in librktio with the Chez Scheme runtime via
 * Sforeign_symbol, so that Racket's `io` layer can find them through
 * `foreign-entry?` without going through `load-shared-object`.  This
 * is needed for the WebAssembly/Emscripten build where dynamic linking
 * is not available, and is hooked up via `-DCUSTOM_INIT=init_rktio_symbols`
 * when compiling the Chez kernel's `main.c`.  See `build-wasm.md` for
 * how it fits into the build pipeline.
 */

#include "scheme.h"
#include "rktio.h"

void init_rktio_symbols(void) {
# include "rktio.inc"
}
