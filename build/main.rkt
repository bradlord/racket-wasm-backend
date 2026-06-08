#lang racket/base
;; racket-wasm build orchestrator CLI.
;;
;;   racket build/main.rkt <subcommand> [args...]
;;
;; Subcommands:
;;   sync                      clone/fast-forward upstream to the pinned commit
;;   apply [--check]           apply patches/ + overlay/ into the clone
;;   build  [opts]             full cross-build (ensure clone+delta, then make) -> dist/
;;   rebuild-binary-catalog    4-stage clean rebuild of the binary pkg catalog
;;   pack-pkgs                 repack the browser package data file (share.data)
;;                             from the already-installed tree -- no emcc relink
;;   serve [port]              COOP/COEP server over dist/
;;   clean                     remove the cloned tree (.work/racket)
;;
;; build / rebuild-binary-catalog options:
;;   --pkgs "<p1 p2 ...>"   packages to install (default from config.rkt)
;;   --wasm-deps "<d ...>"  native dep selection ("draw" alias) (default from config)
;;   --scheme <path>        native threaded host Chez (else resolve/build)
;;   --racket <path>        same-version host Racket (else resolve)
(require racket/list
         racket/file
         "config.rkt"
         "util.rkt"
         "upstream.rkt"
         "patches.rkt"
         "stages.rkt"
         "pkgs.rkt")

;; --- option parsing for build-like subcommands --------------------------

;; Parse "--key value" / "--flag" pairs into a hash. Recognized value keys map
;; to symbols; unknown args error.
(define (parse-build-opts args)
  (let loop ([as args] [h (hash)])
    (cond
      [(null? as) h]
      [else
       (define a (car as))
       (define (val key)
         (when (null? (cdr as)) (error 'build "~a requires a value" a))
         (loop (cddr as) (hash-set h key (cadr as))))
       (case a
         [("--pkgs")      (val 'pkgs)]
         [("--wasm-deps") (val 'wasm-deps)]
         [("--scheme")    (val 'scheme)]
         [("--racket")    (val 'racket)]
         [else (error 'build "unknown option: ~a" a)])])))

;; --- subcommands --------------------------------------------------------

(define (cmd-sync args) (sync))

(define (cmd-apply args)
  (apply-delta #:check-only? (and (member "--check" args) #t)))

(define (cmd-build args) (build (parse-build-opts args)))

(define (cmd-rebuild-catalog args) (rebuild-binary-catalog (parse-build-opts args)))

;; Repack only the browser package data file (share.data/share.data.js) from
;; the already-installed share/pkgs tree, then refresh dist/. The point of the
;; split: this avoids the emcc relink, so changing packages is cheap.
(define (cmd-pack-pkgs args)
  (pack-share-data)
  (collect-outputs))

(define (cmd-serve args)
  (define port (if (pair? args) (car args) "8123"))
  (define serve.rkt (build-path dist-dir "serve.rkt"))
  (unless (file-exists? serve.rkt)
    (error 'serve "no ~a -- run `build` first" serve.rkt))
  (info-msg "serving ~a on port ~a (COOP/COEP) -> http://127.0.0.1:~a/ide.html"
            dist-dir port port)
  (run "racket" #:dir dist-dir #:args (list "serve.rkt" port)))

(define (cmd-clean args)
  (when (directory-exists? clone-dir)
    (info-msg "removing ~a" clone-dir)
    (delete-directory/files clone-dir))
  (info-msg "clean done"))

(define commands
  (list (cons "sync"  cmd-sync)
        (cons "apply" cmd-apply)
        (cons "build" cmd-build)
        (cons "rebuild-binary-catalog" cmd-rebuild-catalog)
        (cons "pack-pkgs" cmd-pack-pkgs)
        (cons "serve" cmd-serve)
        (cons "clean" cmd-clean)))

(define (usage)
  (eprintf "usage: racket build/main.rkt <subcommand> [args]\n")
  (eprintf "subcommands: ~a\n" (map car commands))
  (exit 2))

(module+ main
  (define argv (vector->list (current-command-line-arguments)))
  (when (null? argv) (usage))
  (define name (car argv))
  (define handler (assoc name commands))
  (unless handler (eprintf "unknown subcommand: ~a\n" name) (usage))
  ((cdr handler) (cdr argv)))
