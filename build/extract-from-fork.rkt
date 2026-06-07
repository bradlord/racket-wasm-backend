#lang racket/base
;; Regenerate patches/ and overlay/ from the existing Racket WASM *fork*.
;;
;; Classifies `git diff --name-status <pinned-sha> <fork-tip>`:
;;   M (modified upstream file) -> a diff under patches/<path>.patch
;;   A (added file)             -> a verbatim copy under overlay/<path>
;; with two deliberate exclusions:
;;   * racket/collects/setup/setup-core.rkt  -- committed by accident; dropped.
;;   * Group C top-level files               -- native to this repo, not the clone.
;;
;; Usage (from the racket-wasm repo root):
;;   racket build/extract-from-fork.rkt [--fork <path>] [--ref <fork-tip>]
;; Defaults: --fork /Users/brad/oss/racket  --ref HEAD, base = upstream.lock sha.
(require racket/cmdline
         racket/string
         racket/list
         racket/file
         racket/path
         racket/port
         racket/system
         "config.rkt")

;; --- git helpers (run in the fork checkout) -----------------------------

(define fork-dir (make-parameter "/Users/brad/oss/racket"))
(define fork-ref (make-parameter "HEAD"))

(define (git-run #:binary? [binary? #f] . args)
  (define-values (sp out in err)
    (apply subprocess #f #f #f (find-executable-path "git")
           "-C" (path->string (path->complete-path (fork-dir))) args))
  (close-output-port in)
  (define bytes (port->bytes out))
  (define errstr (port->string err))
  (subprocess-wait sp)
  (define code (subprocess-status sp))
  (close-input-port out) (close-input-port err)
  (unless (zero? code)
    (error 'git "exit ~a for `git ~a`:\n~a" code (string-join args " ") errstr))
  (if binary? bytes (bytes->string/utf-8 bytes)))

(define (git-lines . args)
  (filter (lambda (s) (not (string=? s "")))
          (string-split (apply git-run args) "\n")))

;; --- exclusions ---------------------------------------------------------

(define excluded-from-patches
  ;; Accidental commit; see build-wasm.md / the plan's "warts" section.
  (list "racket/collects/setup/setup-core.rkt"))

(define group-c-native
  ;; Top-level files that live natively in racket-wasm, not in the clone.
  (list "CLAUDE.md" "build-wasm.md" "buildit.sh" "rebuild-binary-catalog.sh"))

;; The fork ships web-repl under racket/collects; this repo instead manages it as
;; a *package* (overlay-local/pkgs/web-repl/, with an info.rkt depending on
;; pict-lib) so a clean cross build compiles it after its package deps. Skip the
;; fork's collects copy entirely so the two don't both ship. See the package's
;; info.rkt and build-wasm.md "web-repl".
(define (repo-managed-as-package? path)
  (regexp-match? #rx"^racket/collects/web-repl/" path))

;; --- main ---------------------------------------------------------------

(define (ensure-empty-dir! d)
  (when (directory-exists? d) (delete-directory/files d))
  (make-directory* d))

(define (write-patch! base path)
  (define diff (git-run "diff" base (fork-ref) "--" path))
  (define dest (build-path patches-dir (string-append path ".patch")))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'truncate
    (lambda (o) (write-string diff o)))
  dest)

;; The git tree mode for a path at the fork tip, e.g. "100644" or "100755".
(define (git-mode path)
  (define line (git-run "ls-tree" (fork-ref) "--" path))
  (car (string-split line)))

(define (write-overlay! path)
  ;; Exact file content at the fork tip (independent of working-tree state).
  (define content (git-run #:binary? #t "show" (string-append (fork-ref) ":" path)))
  (define dest (build-path overlay-dir path))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'truncate
    (lambda (o) (write-bytes content o)))
  ;; Preserve the executable bit (shell scripts under wasm-deps/, run-tests.sh).
  (when (string=? (git-mode path) "100755")
    (file-or-directory-permissions dest #o755))
  dest)

(module+ main
  (command-line
   #:once-each
   [("--fork") fd "Path to the Racket WASM fork checkout" (fork-dir fd)]
   [("--ref")  r  "Fork tip ref to diff against the pin"  (fork-ref r)])

  (define base upstream-sha)
  ;; Sanity: the pinned sha must be the merge-base of the fork tip and itself.
  (define actual-base (car (git-lines "merge-base" base (fork-ref))))
  (unless (string=? actual-base base)
    (eprintf "warning: pinned sha ~a is not the merge-base (~a) of ~a\n"
             base actual-base (fork-ref)))

  (ensure-empty-dir! patches-dir)
  (ensure-empty-dir! overlay-dir)

  (define name-status (git-lines "diff" "--name-status" base (fork-ref)))
  (define patched '())
  (define overlaid '())
  (define skipped '())

  (for ([line (in-list name-status)])
    (define parts (string-split line "\t"))
    (define status (substring (car parts) 0 1)) ; M / A / D / R...
    (define path (last parts))
    (cond
      [(member path group-c-native)
       (set! skipped (cons (list path "group-c-native") skipped))]
      [(repo-managed-as-package? path)
       (set! skipped (cons (list path "web-repl-package") skipped))]
      [(string=? status "A")
       (write-overlay! path)
       (set! overlaid (cons path overlaid))]
      [(string=? status "M")
       (cond
         [(member path excluded-from-patches)
          (set! skipped (cons (list path "accidental") skipped))]
         [else
          (write-patch! base path)
          (set! patched (cons path patched))])]
      [else
       (error 'extract "unhandled git status ~a for ~a (expected A/M)" status path)]))

  ;; Provenance manifest.
  (define manifest
    (hash 'base base
          'fork-ref (fork-ref)
          'patched (sort patched string<?)
          'overlaid (sort overlaid string<?)
          'skipped (sort skipped string<? #:key car)))
  (call-with-output-file (build-path repo-root "extract-manifest.rktd")
    #:exists 'truncate
    (lambda (o) (writeln manifest o)))

  (printf "patches:  ~a\n" (length patched))
  (printf "overlay:  ~a\n" (length overlaid))
  (printf "skipped:  ~a  ~a\n" (length skipped) (map car skipped)))
