#lang racket/base

;; Build a cached *binary* package catalog for the WASM build.
;;
;; Background: the WASM image preloads the package tree as source -- every
;; ".rkt" ships next to its ".zo" -- and `raco pkg install --deps
;; search-auto` resolves each package's build-deps (docs/tests) in addition
;; to its runtime deps (there is no `--no-build-deps` flag). Both bloat the
;; ".data" preload.
;;
;; This script turns the already-cross-compiled in-tree packages into a
;; binary-only catalog under `.wasm-pkgs-cache/`: for each installed
;; package it runs `pkg/strip`'s `generate-stripped-directory` in
;; 'binary-lib mode, which keeps `compiled/*.zo`, drops the ".rkt" source
;; (wherever a sibling ".zo" exists), drops tests/scribblings/doc, strips
;; test/doc submodules out of each ".zo", and -- crucially -- drops
;; `build-deps` from each emitted "info.rkt". It then builds a dirs-catalog
;; over the stripped trees.
;;
;; `make wasm` consumes the catalog (see main.zuo `install-base-pkgs`): it
;; clears `share/pkgs` and clean-installs PKGS from this catalog as the sole
;; source. Because every entry's "info.rkt" has build-deps stripped,
;; `--deps search-auto` only walks runtime deps, so build-only packages are
;; never fetched and the image ships ".zo"-only.
;;
;; IMPORTANT ordering: run this AFTER a bootstrap `make wasm`, so the
;; packages are installed and cross-compiled (tpb32l ".zo" present under
;; `share/pkgs` and the linked in-tree `pkgs/<name>`). See build-wasm.md,
;; "Binary-only package preload".
;;
;; IMPORTANT: run this in the **cross-compiler** context, not a plain host
;; racket. `pkg/strip`'s `fixup-zo` reads each package ".zo" (to strip
;; test/doc submodules), and tpb32l compiled fasl is machine-specific --
;; unreadable without the cross compiler loaded. Two compiled-file roots
;; are needed: `racket/src/build/cs/c/compiled` for the cross compiler's
;; own modules, and `build/zo` for the host-loadable machine-independent
;; package "info_rkt.zo" -- `generate-stripped-directory` EXECUTES each
;; package's "info.rkt" via `get-info/full`, and the per-package tpb32l
;; "info_rkt.zo" under share/pkgs can't load on the host. `build/zo` must
;; precede the trailing ":" ('same = the tpb32l tree). Supply the same
;; flags `raco setup` uses, e.g.:
;;
;;   racket -G build/config \
;;          -MCR racket/src/build/cs/c/compiled:build/zo: \
;;          --cross-compiler tpb32l racket/src/build/cs/c \
;;          racket/src/build-wasm-binary-pkgs.rkt
;;
;; `make wasm-binary-pkgs` (main.zuo) assembles exactly this. Run it from
;; the repo root, with a host RACKET matching the tree version.
;;
;; Trailing positional args (defaults relative to this script under
;; racket/src/):
;;   SHARE_PKGS_DIR = ../share/pkgs   (the installation-scope packages dir)
;;   CACHE_DIR      = .wasm-pkgs-cache

(require racket/cmdline
         racket/runtime-path
         racket/file
         racket/path
         setup/getinfo
         pkg/lib
         pkg/strip
         pkg/dirs-catalog)

(define-runtime-path default-share-pkgs "../share/pkgs")
(define-runtime-path default-cache ".wasm-pkgs-cache")

(define-values (share-pkgs-dir cache-dir)
  (command-line
   #:args ([share-pkgs #f] [cache #f])
   (values (path->complete-path (or share-pkgs default-share-pkgs))
           (path->complete-path (or cache default-cache)))))

(unless (directory-exists? share-pkgs-dir)
  (error 'build-wasm-binary-pkgs
         (string-append "no installation-scope packages directory\n"
                        "  expected: ~a\n"
                        "  run a bootstrap `make wasm` first")
         share-pkgs-dir))

(define cache-pkgs-dir (build-path cache-dir "pkgs"))
(define catalog-dir (build-path cache-dir "catalog"))

;; Fresh cache each run: the catalog/strip steps are cheap (copies, no
;; recompile) and a stale tree would mix old + new package contents.
(when (directory-exists? cache-pkgs-dir)
  (delete-directory/files cache-pkgs-dir))
(make-directory* cache-pkgs-dir)

;; Enumerate every installed package in the in-tree installation scope.
;; Pointing `current-pkg-scope` at the packages directory makes
;; `installed-pkg-names` read `<dir>/pkgs.rktd` and `pkg-directory`
;; resolve both catalog-copied (`<dir>/<name>`) and linked-in-place
;; (static-link to `<root>/pkgs/<name>`) packages.
(define names
  (parameterize ([current-pkg-scope share-pkgs-dir])
    (sort (installed-pkg-names) string<?)))

(printf "Stripping ~a packages to binary-lib into ~a\n"
        (length names) cache-pkgs-dir)

;; Scrub file-relocation directives from a stripped package tree.
;;
;; `generate-stripped-directory` rewrites `copy-man-pages`/
;; `copy-shared-files` to `move-man-pages`/`move-shared-files` (a binary
;; package is expected to relocate those files into the central man/share
;; dirs at install time). But an *in-place* `raco setup` -- which is what
;; the bootstrap ran -- already MOVED those files out of `share/pkgs` into
;; the installation's man/share dirs, and strip's `unmove-files` only
;; restores from the *user* dirs (`find-user-man-dir` etc.), not the
;; installation dirs. So the stripped package keeps a `move-man-pages`
;; directive with no file, and the consume's cross `raco setup` dies with
;; `copy-directory/files: encountered path that is neither file nor
;; directory` on e.g. `gui-lib/mred/mred.1`.
;;
;; A browser WASM image has no use for man pages or other relocated
;; shared files, so drop these directives from every emitted "info.rkt".
;; The files strip rewrote are module datums (`(module info
;; setup/infotab (#%module-begin (define ...) ...))`), readable with
;; `read`; only those carry the `move-*` tags, so a textual prefilter
;; keeps us from trying to `read` `#lang info` sources strip left as-is.
(define scrub-tags '(move-man-pages move-shared-files))

(define (scrub-relocation-directives! dest)
  (for ([info-path (in-directory dest)]
        #:when (and (file-exists? info-path)
                    (equal? (file-name-from-path info-path)
                            (string->path "info.rkt"))
                    (regexp-match? #rx"move-(man-pages|shared-files)"
                                   (file->string info-path))))
    (define form (call-with-input-file* info-path read))
    (define (drop? f)
      (and (pair? f) (eq? (car f) 'define)
           (pair? (cdr f)) (memq (cadr f) scrub-tags)))
    (define scrubbed
      (let loop ([f form])
        (if (list? f)
            (map loop (filter (lambda (x) (not (drop? x))) f))
            f)))
    (call-with-output-file* info-path #:exists 'truncate/replace
      (lambda (o) (write scrubbed o) (newline o)))))

(define stripped
  (for/list ([name (in-list names)])
    (define src
      (parameterize ([current-pkg-scope share-pkgs-dir])
        (pkg-directory name)))
    (cond
      [(and src (directory-exists? src))
       (define dest (build-path cache-pkgs-dir name))
       (make-directory* dest)
       ;; `strip-binary-compile-info` #f: do NOT let strip recompile the
       ;; rewritten "info.rkt" with the *host* compiler (it would inject a
       ;; host-machine "info_rkt.zo" into a tpb32l package). The cross
       ;; `raco setup` in `wasm-setup` compiles "info.rkt" for tpb32l.
       ;; `#:check-status? #f`: skip the built/binary precondition -- these
       ;; are source installs we cross-compiled ourselves.
       (parameterize ([strip-binary-compile-info #f])
         (generate-stripped-directory 'binary-lib src dest
                                      #:check-status? #f))
       ;; Drop `move-man-pages`/`move-shared-files` directives whose files
       ;; an in-place bootstrap setup already relocated away (see
       ;; `scrub-relocation-directives!`).
       (scrub-relocation-directives! dest)
       (printf "  ~a\n" name)
       name]
      [else
       (eprintf "  ~a: no directory (skipped)\n" name)
       #f])))

;; Build a dirs-catalog over the stripped trees. No `--link`: we want
;; `raco pkg install` to *copy* the binary packages into a fresh
;; `share/pkgs` so the wasm link's wholesale `share/pkgs` preload picks
;; them up.
(printf "Building catalog at ~a\n" catalog-dir)
(make-directory* catalog-dir)
(create-dirs-catalog catalog-dir
                     (list cache-pkgs-dir)
                     #:status-printf printf
                     #:link? #f)

;; A manifest makes a stale cache obvious (re-run when PKGS / the tree
;; version changes; `make wasm` does not auto-rebuild this).
(define manifest (build-path cache-dir "manifest.rktd"))
(call-with-output-file* manifest
                        #:exists 'truncate/replace
                        (lambda (o)
                          (write (hash 'version (version)
                                       'packages (filter values stripped))
                                 o)
                          (newline o)))

(printf "Done. ~a binary packages cataloged.\n"
        (length (filter values stripped)))
