/* wasm_http.c -- minimal HTTP-via-sync-XHR primitive for the WASM build.
 *
 * Adds one foreign-callable function, `wasm_http_get`, that performs a
 * synchronous HTTP GET from within the runtime worker. Sync XMLHttpRequest
 * is still permitted inside Web Workers (it's only forbidden on the page
 * main thread), so the call blocks the worker thread until the response
 * arrives -- no event-loop yield, no Asyncify, no IDB/WebSocket plumbing.
 *
 * Calling convention: the caller passes a pre-allocated bytevector. On
 * success, the first 4 bytes get the HTTP status (host byte order, int32)
 * and the rest of the bytevector gets the response body. The return value
 * is the total bytes written (4 + body_len), or -1 on a transport-level
 * failure (network error, sync XHR not allowed), or -(4 + body_len) when
 * the response wouldn't fit -- the caller can grow its buffer and retry.
 *
 * Registered with Sforeign_symbol via wasm_extras.inc, so it's reachable
 * from Racket via `(ffi/unsafe/vm)`'s `vm-eval` running a Chez
 * `foreign-procedure` form. See racket/collects/wasm/http.rkt for the
 * user-facing wrapper.
 *
 * v0 scope: GET only, no headers, no streaming, no timeouts. Browser only
 * -- the node build links the stub.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
# include <emscripten.h>
#endif

#ifdef __EMSCRIPTEN__

EM_JS(int, wasm_http_get,
      (const char *url_ptr, void *out, int max_len),
{
  var url = UTF8ToString(url_ptr);
  var xhr = new XMLHttpRequest();
  try {
    xhr.open("GET", url, false /* synchronous */);
    xhr.responseType = "arraybuffer";
    xhr.send();
  } catch (e) {
    return -1;
  }
  var status = xhr.status | 0;
  var resp = xhr.response;
  var body = resp ? new Uint8Array(resp) : new Uint8Array(0);
  var needed = 4 + body.length;
  if (needed > max_len) return -needed;       // signal "buf too small, try this size"
  setValue(out, status, "i32");
  if (body.length > 0) HEAPU8.set(body, out + 4);
  return needed;
});

#else

/* Stub for non-Emscripten builds: same symbol exists in the table but
   reports "no transport" if anyone tries to call it. node-side HTTP
   should go through Racket's normal net/http-easy / fetch path. */
int wasm_http_get(const char *url_ptr, void *out, int max_len) {
  (void)url_ptr; (void)out; (void)max_len;
  return -1;
}

#endif
