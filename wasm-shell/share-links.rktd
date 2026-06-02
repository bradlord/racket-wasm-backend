;; Installation-level link table for the WASM build's MEMFS.
;;
;; This file is preloaded as /share/links.rktd; Racket finds it via
;; the default rule (installation-links-file) = <config-dir>/../share/
;; /links.rktd, where <config-dir> is /etc per main_em.c. Each entry
;; declares a package whose contents become accessible from Racket's
;; collection resolver. `(root (#"pkgs" #"<name>"))` says "treat
;; everything under /share/pkgs/<name>/ as if it were on the
;; collection root path."
;;
;; Add a new entry here when preloading another package; remember to
;; also add the corresponding `--preload-file ../../share/pkgs/<name>`
;; line to build.sh's LDFLAGS_COMMON.
((root (#"pkgs" #"draw-lib")))
