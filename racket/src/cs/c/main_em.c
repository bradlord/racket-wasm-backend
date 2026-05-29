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
     find collections and config data using stable absolute paths. */
  ba.collects_dir = "/collects";
  ba.config_dir   = "/etc";

  /* Use a machine-specific compiled-file subdirectory so the WASM
     runtime does not try to load host-native fasls from `compiled/`. */
  ba.cs_compiled_subdir = 1;

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
