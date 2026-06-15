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
#include <emscripten/console.h>
#include <emscripten/wasmfs.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define SHELL_IN_CAP   (1 << 16)  /* 64 KiB of pending input  */
#define SHELL_OUT_CAP  (1 << 18)  /* 256 KiB of pending output */

static volatile int shell_in_ring[2 + SHELL_IN_CAP];
static volatile int shell_out_ring[2 + SHELL_OUT_CAP];

/* A single int the runtime worker (wasmfs-stdin.js) flips while it is parked
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

/* Browser-surface filesystem + console wiring, called once from main_em.c
 * before Racket starts. This object (wasm_shell_io.o) is linked into the
 * browser surface (`racket-web.*`) only, so main_em.c declares this symbol weak
 * with a no-op default; the node surface, which never links this object, gets
 * the no-op. The build is -sWASMFS for the browser link, so the wasmfs_* and
 * dup2 calls below resolve there (and never reach the legacy-FS node link).
 *
 *  1. Redirect stdout/stderr onto /dev/console -- a per-byte ring device.
 *     WasmFS's built-in stdout/stderr line-buffer the fd until a newline
 *     (special_files.cpp WritingStdFile), which would hide the REPL prompt and
 *     unterminated `display` output; the device pushes every byte to the output
 *     ring immediately. `rkt_console_setup` (wasmfs-console.js, --js-library)
 *     creates the device; we call it here, NOT in preRun, because WasmFS jsimpl
 *     device ops run on the calling thread against per-thread JS state and are
 *     not proxied -- so the device must be created on this proxied main pthread,
 *     the one that runs every Racket stdout write(). Then dup2 fds 1/2 onto it.
 *
 *  2. Mount an OPFS-backed persistent home at /home/web_user. OPFS gives
 *     synchronous, durable-on-close I/O directly on this pthread -- no
 *     exit-window flush, unlike the old IDBFS save-on-onExit path. Fail-soft: if
 *     OPFS is unavailable or locked by another tab (the FileSystemSyncAccessHandle
 *     single-tab limit, emscripten #24648), fall back to an in-memory
 *     /home/web_user so the IDE still runs (without persistence) this session.
 */
/* Provided by wasmfs-console.js (--js-library); creates the /dev/console ring
 * device on the calling thread. Must run on this thread (the proxied main
 * pthread) so the jsimpl backend it registers is found by writes from here. */
extern void rkt_console_setup(void);

void racket_wasm_browser_fs_init(void) {
  /* (1) stdout/stderr -> /dev/console (the per-byte ring device). */
  rkt_console_setup();
  int fd = open("/dev/console", O_WRONLY);
  if (fd >= 0) {
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) close(fd);
  }

  /* (2) OPFS-backed /home/web_user, fail-soft to in-memory. */
  mkdir("/home", 0777);
  backend_t opfs = wasmfs_create_opfs_backend();
  if (!opfs || wasmfs_create_directory("/home/web_user", 0777, opfs) != 0) {
    emscripten_err("racket-wasm: OPFS unavailable; /home/web_user is not persistent this session");
    mkdir("/home/web_user", 0777);
  }
}
