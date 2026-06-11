#lang racket/base
;; Subprocess strip: re-emit each staged, in-place tpb32l-compiled package as a
;; stripped package directory (`pkg/strip`'s `generate-stripped-directory`) and
;; (re)build a `pkg/dirs-catalog` index over the result.
;;
;; This runs as a SUBPROCESS of the host racket WITH the cross flags
;;   <host-racket> -G <etc> -MCR <hostzo>:<xtgt> --cross-compiler tpb32l <cc> \
;;                 strip-catalog.rkt <staged-pkgs> <cat-pkgs> <mode> <cat-index>
;; (spawned by build/consume.rkt's `strip-into-catalog!`). The cross context is
;; load-bearing for `'binary-lib`: that mode's `fixup-zo` `(read)`s each module
;; `.zo` with `read-accept-compiled`, and only the cross xpatch can decode tpb32l
;; target fasl on the host -- a plain host racket traps with `fasl-read:
;; incompatible ... machine-type 'tpb32l`. `get-info/full` (here and in
;; `create-dirs-catalog`) resolves host-form bytecode the same way. See
;; build-wasm.md "Binary-only packages via the catalog".
(require racket/cmdline
         racket/file
         pkg/strip
         (only-in pkg/dirs-catalog create-dirs-catalog))

(define args (current-command-line-arguments))
(unless (= 4 (vector-length args))
  (error 'strip-catalog
         "usage: strip-catalog.rkt <staged-pkgs> <cat-pkgs> <mode> <cat-index>"))
(define staged    (vector-ref args 0))
(define cat-pkgs  (vector-ref args 1))
(define mode      (string->symbol (vector-ref args 2)))
(define cat-index (vector-ref args 3))

(make-directory* cat-pkgs)
;; `strip-binary-compile-info #f`: never recompile a stripped `info.rkt` on the
;; HOST -- that would inject host bytecode into a tpb32l package. The final cross
;; `raco setup` compiles it for tpb32l if anything needs it.
(parameterize ([strip-binary-compile-info #f])
  (for ([name (in-list (directory-list staged))]
        #:when (directory-exists? (build-path staged name)))
    (define dst (build-path cat-pkgs name))
    ;; A package is stripped once and reused; consume.rkt wipes `cat-pkgs` when
    ;; the strip mode changes, so a present dir is current.
    (unless (directory-exists? dst)
      (printf "  stripping ~a (~a)\n" name mode)
      (flush-output)
      (make-directory* dst)
      (generate-stripped-directory mode (build-path staged name) dst))))
(create-dirs-catalog cat-index (list cat-pkgs) #:status-printf void)
