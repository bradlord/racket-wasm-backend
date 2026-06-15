/* wasm_shell_io.c
 *
 * Shared-memory console rings for the WASM browser shell.
 *
 * The browser build runs the runtime inside a dedicated Web Worker that
 * the page (ide.js) spawns explicitly -- shell-worker.js
 * `importScripts`'s racket-web.js and `main()` runs on that worker's
 * own thread, leaving the page's main thread free to drive xterm.js.
 * The two threads exchange console bytes through these ring buffers,
 * which live in the module's *shared* linear memory (the build uses
 * `-pthread`, which makes `WebAssembly.Memory({shared:true})` and
 * therefore `Module.HEAPU8.buffer` a SharedArrayBuffer), so a plain
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
 * stdin  ring: producer = page (keystrokes), consumer = runtime worker.
 *              The consumer blocks with `Atomics.wait` on `tail` when
 *              empty; the producer bumps `tail` and `Atomics.notify`s.
 * stdout ring: producer = runtime worker (put_char), consumer = page,
 *              which polls each animation frame (the page's main thread
 *              may not Atomics.wait).
 *
 * The C side never touches the contents; it only reserves the storage in
 * the data segment and hands its address to JS. The address is resolved
 * once on the runtime worker (after onRuntimeInitialized) and posted to
 * the page along with the shared HEAP buffer; both sides then index the
 * same memory.
 */

#include <emscripten.h>

#define SHELL_IN_CAP   (1 << 16)  /* 64 KiB of pending input  */
#define SHELL_OUT_CAP  (1 << 18)  /* 256 KiB of pending output */

static volatile int shell_in_ring[2 + SHELL_IN_CAP];
static volatile int shell_out_ring[2 + SHELL_OUT_CAP];

/* A single int the runtime worker (shell-tty.js) flips while it is parked
 * in `Atomics.wait` on the stdin ring -- i.e. while the process is blocked
 * waiting for the user to type a line (a program's `read-line`, or the
 * REPL prompt; the two are indistinguishable at the fd level). The page
 * (ide.js) polls it each animation frame to show a "waiting for input"
 * affordance and focus the input box. 0 = running/not blocked, 1 =
 * blocked waiting for stdin. Lives in the same shared linear memory as
 * the rings, so a plain Int32Array view on the page sees the writes. */
static volatile int shell_io_state[1];

EMSCRIPTEN_KEEPALIVE int *shell_in_addr(void)     { return (int *)shell_in_ring; }
EMSCRIPTEN_KEEPALIVE int  shell_in_cap(void)      { return SHELL_IN_CAP; }
EMSCRIPTEN_KEEPALIVE int *shell_out_addr(void)    { return (int *)shell_out_ring; }
EMSCRIPTEN_KEEPALIVE int  shell_out_cap(void)     { return SHELL_OUT_CAP; }
EMSCRIPTEN_KEEPALIVE int *shell_io_state_addr(void) { return (int *)shell_io_state; }
