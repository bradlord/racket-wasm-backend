/* main_em.c
 *
 * Minimal entry point for the Racket CS WebAssembly (Emscripten) build.
 *
 * The native CS entry point in `main.c` does a lot of platform work
 * (Windows DLL injection, OS X frameworks, ELF section probing,
 * embedded boot-file offsets) before it can populate the
 * `racket_boot_arguments_t` struct that `boot.c` consumes. None of
 * that applies under Emscripten: the boot files are preloaded into
 * the WASM module's virtual filesystem at fixed paths, and there are
 * no DLLs or embedded segments to discover.
 *
 * This file replaces Chez's default `c/main.c` in the Emscripten link
 * line and constructs a minimal boot-args struct that points
 * `racket.boot` at the preloaded files, then calls `racket_boot`
 * (provided by `boot.c`).
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define BOOT_EXTERN extern
#include "boot.h"

int main(int argc, char **argv) {
  racket_boot_arguments_t ba;
  const char *self = (argc > 0 && argv[0]) ? argv[0] : "racket";

  memset(&ba, 0, sizeof(ba));

  /* The boot files are preloaded via Emscripten's --preload-file at
     absolute virtual-filesystem paths. boot_len == 0 means "read to
     EOF", and boot_offset == 0 means "from the start". */
  ba.boot1_path = "/petite.boot";
  ba.boot1_offset = 0;
  ba.boot1_len    = 0;
  ba.boot2_path = "/scheme.boot";
  ba.boot2_offset = 0;
  ba.boot2_len    = 0;
  ba.boot3_path = "/racket.boot";
  ba.boot3_offset = 0;
  ba.boot3_len    = 0;

  /* Command-line arguments are passed straight through; argv[0] is
     stripped to match the native entry point's convention. */
  if (argc > 0) {
    ba.argc = argc - 1;
    ba.argv = argv + 1;
  } else {
    ba.argc = 0;
    ba.argv = NULL;
  }

  ba.exec_file = self;
  ba.run_file  = self;
  ba.k_file    = self;

  /* Mount the top-level Racket tree into MEMFS so the resolver can
     find collections and config data using stable absolute paths.

     collects_dir is NOT a plain C string: boot.c's parse_coldirs() reads
     it as a NUL-separated *list* of paths terminated by a second NUL (see
     start/config.inc's scheme_coldir: `INITIAL_COLLECTS_DIRECTORY "\0\0"`
     -- 1st NUL ends the path, 2nd ends the list). The trailing "\0" below
     supplies that list terminator (the literal's own implicit NUL ends the
     path). Without it, parse_coldirs reads the byte past the path's
     terminator out of bounds into adjacent rodata; when nonzero it takes
     the multi-path branch and slurps the C string-constant pool (cairo PS
     templates, glib paths, ...) as bogus collection dirs, which then
     pollute (current-library-collection-paths). config_dir takes the plain
     single-string path (Sbytevector), so it needs no terminator. */
  ba.collects_dir = "/collects\0";
  ba.config_dir   = "/etc";

  /* segment_offset is for `-k` embedded bytecode, which we never
     produce on this target. */
  ba.segment_offset = 0;

  /* Run as a regular command-line `racket`, exit when done. */
  ba.exit_after = 1;

  /* No GUI under headless WASM. */
  ba.is_gui = 0;
  ba.wm_is_gracket_or_x11_arg_count = 0;
  ba.gracket_guid_or_x11_args = "";

  racket_boot(&ba);
  return 0;
}
