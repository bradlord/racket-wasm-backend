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

/* libc / libpthread shims for symbols GLib references but the
 * Emscripten sysroot doesn't provide. None of these get called on
 * the racket/draw path -- they're behind code branches our paths
 * never enter -- but the linker needs the symbols to exist. Stub
 * each as "operation not permitted" so any accidental invocation
 * fails loudly rather than silently corrupts. */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>

typedef long ssize_t_local;     /* avoid pulling sys/types.h here */

/* copy_file_range / splice / fallocate / close_range: Linux-only
   syscalls. Return -1 ENOTSUP. */
EMSCRIPTEN_KEEPALIVE
ssize_t_local copy_file_range(int fd_in, long long *off_in,
                              int fd_out, long long *off_out,
                              unsigned long len, unsigned int flags) {
  (void)fd_in; (void)off_in; (void)fd_out; (void)off_out;
  (void)len;   (void)flags;
  errno = ENOTSUP; return -1;
}
EMSCRIPTEN_KEEPALIVE
ssize_t_local splice(int fd_in, long long *off_in,
                     int fd_out, long long *off_out,
                     unsigned long len, unsigned int flags) {
  (void)fd_in; (void)off_in; (void)fd_out; (void)off_out;
  (void)len;   (void)flags;
  errno = ENOTSUP; return -1;
}
EMSCRIPTEN_KEEPALIVE
int fallocate(int fd, int mode, long long offset, long long len) {
  (void)fd; (void)mode; (void)offset; (void)len;
  errno = ENOTSUP; return -1;
}
EMSCRIPTEN_KEEPALIVE
int close_range(unsigned int first, unsigned int last, int flags) {
  (void)first; (void)last; (void)flags;
  errno = ENOTSUP; return -1;
}

/* C23 free_sized / free_aligned_sized: just drop to free(). GLib
   implicitly declares these as returning int (no header), so the
   wasm signature must match. */
extern void free(void *);
EMSCRIPTEN_KEEPALIVE
int free_sized(void *p, unsigned long sz) {
  (void)sz; free(p); return 0;
}
EMSCRIPTEN_KEEPALIVE
int free_aligned_sized(void *p, unsigned long a, unsigned long sz) {
  (void)a; (void)sz; free(p); return 0;
}

/* pthread name / affinity Linux extensions. The Emscripten libpthread
   has pthread_setname_np in some configurations and not others. Provide
   weak fallbacks that succeed-with-no-op or report unsupported. */
EMSCRIPTEN_KEEPALIVE
int pthread_setname_np(unsigned long thread, const char *name) {
  (void)thread; (void)name;
  return 0;  /* succeed silently; debug-only feature */
}
EMSCRIPTEN_KEEPALIVE
int pthread_getaffinity_np(unsigned long thread, unsigned long cpusetsize,
                           void *cpuset) {
  (void)thread; (void)cpusetsize; (void)cpuset;
  errno = ENOTSUP; return ENOTSUP;
}
EMSCRIPTEN_KEEPALIVE
int __sched_cpucount(unsigned long setsize, const void *set) {
  (void)setsize; (void)set; return 1;  /* one CPU */
}

/* posix_spawnp: no fork+exec on wasm32. */
EMSCRIPTEN_KEEPALIVE
int posix_spawnp(int *pid, const char *file,
                 const void *file_actions, const void *attrp,
                 char *const argv[], char *const envp[]) {
  (void)pid; (void)file; (void)file_actions; (void)attrp;
  (void)argv; (void)envp;
  errno = ENOTSUP; return ENOTSUP;
}

/* DNS resolver -- libresolv isn't shipped. */
EMSCRIPTEN_KEEPALIVE
int res_query(const char *dname, int klass, int type,
              unsigned char *answer, int anslen) {
  (void)dname; (void)klass; (void)type;
  (void)answer; (void)anslen;
  errno = ENOTSUP; return -1;
}

/* GLib's inotify monitor wouldn't compile if inotify weren't
   detected -- but it links against this glue type even when the
   actual monitor isn't pulled in. Stub the type-id getter. */
EMSCRIPTEN_KEEPALIVE
unsigned long g_inotify_file_monitor_get_type(void) { return 0; }

/* BSD-style program-name getter (FontConfig uses it for cache paths).
   Emcc's libc doesn't ship it; static stub returns the build's
   conventional name. */
EMSCRIPTEN_KEEPALIVE
const char *getprogname(void) { return "racket"; }


