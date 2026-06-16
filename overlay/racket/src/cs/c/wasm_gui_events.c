/* wasm_gui_events.c
 *
 * A shared-memory ring carrying GUI input events from the page to the
 * runtime worker, for a browser mred (racket/gui) backend. It is the
 * page->worker mirror of the stdin ring in wasm_shell_io.c: the page
 * (ide.js) is the producer (it owns the DOM and its mouse/key/resize
 * listeners), the runtime worker is the consumer (mred's event pump
 * turns records into mouse-event% / key-event% and queue-event's them
 * onto the right eventspace).
 *
 * Unlike the byte-stream console rings, this ring stores fixed-width
 * RECORDS: GUI events have several integer fields, so a byte stream
 * would force a framing protocol on both sides. Each record is
 * GUI_EVT_FIELDS int32 slots; head/tail are free-running record
 * counters and the record index wraps with `% cap`.
 *
 *     int[0]              = head (next record index the worker reads)
 *     int[1]              = tail (next record index the page writes)
 *     int[2 + (i%cap)*F]  = field 0 of record i  (F = GUI_EVT_FIELDS)
 *     ... through field F-1
 *
 * Field layout of a record (all int32):
 *     [0] type      -- one of the GUI_EVT_* codes below
 *     [1] frame-id  -- which top-level frame/canvas the event targets
 *     [2] x         -- mouse x (client coords); resize: new width
 *     [3] y         -- mouse y; resize: new height
 *     [4] k         -- mouse button code, key code, or wheel delta
 *     [5] mods      -- modifier bitmask (GUI_MOD_*)
 *
 * Wake/park: the worker's event pump does not busy-poll. It parks via
 * `Atomics.wait` on the ring's `tail` cell (index 1) with a timeout =
 * the next pending timer's deadline (so timers still fire), and the
 * page bumps `tail` and `Atomics.notify`s after writing a record. This
 * is the same SAB discipline as the stdin ring; the difference is the
 * timed wait, which lets a single park serve both "page delivered an
 * event" and "a timer is due". See the wasm mred backend's queue.rkt
 * (wx/wasm/queue.rkt) and wasmfs-gui-events handling in shell-worker.js
 * / ide.js.
 *
 * The C side never interprets records; it only reserves the storage in
 * shared linear memory and exposes its address/shape. The worker drains
 * records with `wasm_gui_events_poll` (registered as a foreign symbol
 * via wasm_extras.inc); the page writes them with a plain Int32Array
 * over the same shared buffer. Like wasm_canvas.c this object is linked
 * into BOTH surfaces (node + browser); under node nothing ever writes
 * the ring, so the poll just returns 0.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __EMSCRIPTEN__
# include <emscripten.h>
#else
# define EMSCRIPTEN_KEEPALIVE
#endif

#define GUI_EVT_FIELDS 6
#define GUI_EVT_CAP    (1 << 12)   /* 4096 pending event records */

/* head, tail, then cap records of GUI_EVT_FIELDS int32 each. */
static volatile int gui_evt_ring[2 + GUI_EVT_CAP * GUI_EVT_FIELDS];

EMSCRIPTEN_KEEPALIVE int *gui_events_addr(void)   { return (int *)gui_evt_ring; }
EMSCRIPTEN_KEEPALIVE int  gui_events_cap(void)    { return GUI_EVT_CAP; }
EMSCRIPTEN_KEEPALIVE int  gui_events_fields(void) { return GUI_EVT_FIELDS; }

/* Drain up to `max_records` pending records into `out` (a caller buffer
 * of at least max_records*GUI_EVT_FIELDS int32, passed from Racket as a
 * byte buffer). Non-blocking: returns the number of records copied (0 if
 * empty). The worker calls this after the park wakes; parking itself is
 * done in JS via Atomics.wait on the tail cell (the C side can't block
 * the proxied main pthread on a futex without freezing the runtime, and
 * the timed wait belongs with the timer-deadline logic in queue.rkt).
 *
 * head/tail are plain volatile loads here; correctness relies on the JS
 * producer having done a release (Atomics.store of tail) before notify,
 * and on this consumer running after the wait observed that store. */
EMSCRIPTEN_KEEPALIVE
int wasm_gui_events_poll(int *out, int max_records) {
  if (!out || max_records <= 0) return 0;
  int head = gui_evt_ring[0];
  int tail = gui_evt_ring[1];
  int n = 0;
  while (head != tail && n < max_records) {
    int base = 2 + (head % GUI_EVT_CAP) * GUI_EVT_FIELDS;
    for (int f = 0; f < GUI_EVT_FIELDS; f++)
      out[n * GUI_EVT_FIELDS + f] = gui_evt_ring[base + f];
    head++;
    n++;
  }
  gui_evt_ring[0] = head;
  return n;
}
