/* wasm_shell_io.c
 *
 * Shared-memory console rings for the WASM browser shell.
 *
 * The browser build links with -sPROXY_TO_PTHREAD, so Racket's `main`
 * (and therefore all of its stdin/stdout traffic) runs on a Web Worker
 * "compute" thread while the page's main thread stays free to drive the
 * xterm.js terminal. The two threads exchange console bytes through
 * these ring buffers, which live in the module's *shared* linear memory
 * (the build uses `WebAssembly.Memory({shared:true})`), so a plain
 * `Int32Array` view over the heap on either thread sees the same bytes
 * and `Atomics` can coordinate them.
 *
 * Layout of each ring (one byte per int32 slot, which keeps the JS side
 * trivial: every cell is independently addressable with Atomics):
 *
 *     int[0] = head   (next index the consumer will read)
 *     int[1] = tail   (next index the producer will write)
 *     int[2 + (i % cap)] = byte i of the stream
 *
 * head/tail are free-running counters; the data index wraps with `% cap`.
 *
 * stdin  ring: producer = main thread (keystrokes), consumer = compute
 *              thread. The consumer blocks with `Atomics.wait` on `tail`
 *              when empty; the producer bumps `tail` and `Atomics.notify`s.
 * stdout ring: producer = compute thread (put_char), consumer = main
 *              thread, which polls (the main thread may not Atomics.wait).
 *
 * The C side never touches the contents; it only reserves the storage in
 * the data segment and hands its address to JS. The fixed data-segment
 * address is identical on every thread, so both the page and the pthread
 * resolve the same buffer by calling these accessors.
 */

#include <emscripten.h>

#define SHELL_IN_CAP   (1 << 16)  /* 64 KiB of pending input  */
#define SHELL_OUT_CAP  (1 << 18)  /* 256 KiB of pending output */

static volatile int shell_in_ring[2 + SHELL_IN_CAP];
static volatile int shell_out_ring[2 + SHELL_OUT_CAP];

EMSCRIPTEN_KEEPALIVE int *shell_in_addr(void)  { return (int *)shell_in_ring; }
EMSCRIPTEN_KEEPALIVE int  shell_in_cap(void)   { return SHELL_IN_CAP; }
EMSCRIPTEN_KEEPALIVE int *shell_out_addr(void) { return (int *)shell_out_ring; }
EMSCRIPTEN_KEEPALIVE int  shell_out_cap(void)  { return SHELL_OUT_CAP; }
