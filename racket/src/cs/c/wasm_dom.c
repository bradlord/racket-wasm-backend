/* wasm_dom.c -- synchronous DOM-RPC primitive for the WASM browser
 * shell.
 *
 * Workers have no DOM (no document/window). To let Racket touch the
 * page synchronously without moving the runtime off-worker, we use a
 * pair of shared-memory slots:
 *
 *   command slot (worker -> page):
 *     [cmd_seq : u32]  bumped each call
 *     [cmd_len : u32]  bytes of UTF-8 JS source in cmd_data
 *     [cmd_data: u8[CMD_CAP]]
 *
 *   reply slot (page -> worker):
 *     [reply_seq : u32]  set to cmd_seq when reply is ready
 *     [reply_len : u32]  bytes of UTF-8 result in reply_data
 *     [reply_data: u8[REPLY_CAP]]
 *
 * Worker side (`wasm_dom_eval`): copy JS source to cmd_data, bump
 * cmd_seq, then `Atomics.wait` on reply_seq until it matches cmd_seq.
 * Read reply_data, return.
 *
 * Page side (a poller installed on requestAnimationFrame in
 * browser-shell.js / playground.js): each frame, check whether
 * cmd_seq advanced past the last value the page handled; if so,
 * decode the JS, `eval` it, encode the result, write into reply_data
 * + reply_len, store reply_seq (release), `Atomics.notify` the worker.
 *
 * This is the v0 prototype documented in build-wasm.md's "DOM
 * interaction" section -- a single eval-the-string primitive, not a
 * typed DOM surface. Anything reachable from the page's JS scope is
 * reachable here (including `document`, `window`, the page's own
 * helpers). That makes it unsafe to expose to untrusted Racket code
 * verbatim; the right next step is a typed protocol on top of this
 * transport.
 *
 * Latency cap: one animation frame (~16 ms) per call, because the
 * page only services commands on rAF.
 */

#include <stdint.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
# include <emscripten.h>
#else
# define EMSCRIPTEN_KEEPALIVE
#endif

#define DOM_CMD_CAP   (1 << 16)
#define DOM_REPLY_CAP (1 << 16)

/* Header layout: two int32s (seq, len) followed by data. We expose
   addresses (and capacities) so both shell-worker.js (forwarding to
   the page) and the EM_JS primitive can find them. */
static volatile int wasm_dom_cmd_seq;
static volatile int wasm_dom_cmd_len;
static volatile uint8_t wasm_dom_cmd_buf[DOM_CMD_CAP];

static volatile int wasm_dom_reply_seq;
static volatile int wasm_dom_reply_len;
static volatile uint8_t wasm_dom_reply_buf[DOM_REPLY_CAP];

EMSCRIPTEN_KEEPALIVE int *wasm_dom_cmd_seq_addr(void)     { return (int *)&wasm_dom_cmd_seq; }
EMSCRIPTEN_KEEPALIVE int *wasm_dom_cmd_len_addr(void)     { return (int *)&wasm_dom_cmd_len; }
EMSCRIPTEN_KEEPALIVE uint8_t *wasm_dom_cmd_buf_addr(void) { return (uint8_t *)wasm_dom_cmd_buf; }
EMSCRIPTEN_KEEPALIVE int wasm_dom_cmd_cap(void)           { return DOM_CMD_CAP; }

EMSCRIPTEN_KEEPALIVE int *wasm_dom_reply_seq_addr(void)     { return (int *)&wasm_dom_reply_seq; }
EMSCRIPTEN_KEEPALIVE int *wasm_dom_reply_len_addr(void)     { return (int *)&wasm_dom_reply_len; }
EMSCRIPTEN_KEEPALIVE uint8_t *wasm_dom_reply_buf_addr(void) { return (uint8_t *)wasm_dom_reply_buf; }
EMSCRIPTEN_KEEPALIVE int wasm_dom_reply_cap(void)           { return DOM_REPLY_CAP; }

#ifdef __EMSCRIPTEN__

EM_JS(int, wasm_dom_eval,
      (const char *src, int src_len, char *out, int out_cap),
{
  /* Slot addresses + caps come from the keepalive accessors above.
     Resolve once via Module since the EM_JS body runs in the wasm
     module's JS closure where Module is in scope. */
  var cmdSeqAddr   = Module["_wasm_dom_cmd_seq_addr"]();
  var cmdLenAddr   = Module["_wasm_dom_cmd_len_addr"]();
  var cmdBufAddr   = Module["_wasm_dom_cmd_buf_addr"]();
  var cmdCap       = Module["_wasm_dom_cmd_cap"]();
  var replySeqAddr = Module["_wasm_dom_reply_seq_addr"]();
  var replyLenAddr = Module["_wasm_dom_reply_len_addr"]();
  var replyBufAddr = Module["_wasm_dom_reply_buf_addr"]();
  var replyCap     = Module["_wasm_dom_reply_cap"]();

  var H32 = HEAP32;
  var H8  = HEAPU8;

  /* Copy command data. */
  var n = src_len < cmdCap ? src_len : cmdCap;
  H8.set(H8.subarray(src, src + n), cmdBufAddr);
  Atomics.store(H32, cmdLenAddr >> 2, n);

  /* Release-store: cmd_seq bump signals data ready. */
  var newSeq = Atomics.add(H32, cmdSeqAddr >> 2, 1) + 1;

  /* Wait for the page to advance reply_seq to newSeq. */
  while (Atomics.load(H32, replySeqAddr >> 2) !== newSeq) {
    Atomics.wait(H32, replySeqAddr >> 2,
                 Atomics.load(H32, replySeqAddr >> 2));
  }

  /* Re-read views: ALLOW_MEMORY_GROWTH could have swapped them. */
  H32 = HEAP32; H8 = HEAPU8;

  var len = Atomics.load(H32, replyLenAddr >> 2);
  var outN = len < out_cap ? len : out_cap;
  H8.set(H8.subarray(replyBufAddr, replyBufAddr + outN), out);
  return outN;
});

#else

int wasm_dom_eval(const char *src, int src_len, char *out, int out_cap) {
  (void)src; (void)src_len; (void)out; (void)out_cap;
  return -1;
}

#endif
