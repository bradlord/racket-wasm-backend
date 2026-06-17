#lang racket/base
;; racket-wasm build orchestrator CLI.
;;
;;   racket build/main.rkt <subcommand> [args...]
;;
;; Subcommands:
;;   sync                      clone/fast-forward upstream to the pinned commit
;;   apply [--check]           apply patches/ + overlay/ into the clone
;;   build  [opts]             full cross-build (ensure clone+delta, then make) -> dist/
;;   app <dir> [opts]          build a custom app from <dir>/app.rkt -> <dir>/dist
;;   package [<dir>] [opts]    emit a distributable binary package (runtime set +
;;                             metadata + .tar.gz) for <dir>'s config (default IDE)
;;   cross-sdk [<dir>] [opts]  emit a standalone cross-compiler SDK (retarget files
;;                             + tpb32l cross-root + .tar.gz) -- emsdk-free; lets a
;;                             same-version host racket cross-build new packages
;;   cross-install --sdk <dir> --share-data <path> --dest <dir> [--racket <p>]
;;                 [--work <d>] [--catalog <d>] [--local <dir>]... <catalog-name>...
;;                             fetch + cross-compile package(s) for tpb32l with a
;;                             cross-SDK, stage them into a built-package catalog,
;;                             then install the app's closure from it and fold into
;;                             a runtime's share.data (no clone, no emsdk). Bare
;;                             args = catalog names; --local <dir> = a local package
;;                             source dir; --catalog <d> = the persistent built-
;;                             package catalog dir (default: under --work).
;;   pack-pkgs                 repack the browser package data file (share.data)
;;                             from the already-installed tree -- no emcc relink
;;   serve <dir> [port]        COOP/COEP server over <dir> (e.g. an app's dist/)
;;   clean                     remove the cloned tree (.work/racket)
;;
;; build options:
;;   --pkgs "<p1 p2 ...>"   packages to install (default from config.rkt)
;;   --wasm-deps "<d ...>"  native dep selection ("draw" alias) (default from config)
;;   --scheme <path>        native threaded host Chez (else resolve/build)
;;   --racket <path>        same-version host Racket (else resolve)
;;
;; app / build options:
;;   --runtime <pkg-dir>    assemble against a prebuilt binary package (no clone/
;;                          make); errors on a build-key mismatch unless --force
;;   --force                bypass the cache / proceed despite a key mismatch
(require racket/list
         racket/file
         racket/string
         "config.rkt"
         "util.rkt"
         "upstream.rkt"
         "patches.rkt"
         "stages.rkt"
         "pack.rkt"
         "app.rkt"
         "consume.rkt")

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
         [("--pkgs") (val 'pkgs)]
         [("--wasm-deps") (val 'wasm-deps)]
         [("--scheme") (val 'scheme)]
         [("--racket") (val 'racket)]
         [("--dest") (val 'dest)]
         ;; A prebuilt binary package dir to assemble against (no clone/make).
         [("--runtime") (val 'runtime)]
         ;; Boolean flag: bypass the runtime cache and force a real build; with
         ;; --runtime, proceed despite a build-key mismatch.
         [("--force") (loop (cdr as) (hash-set h 'force? #t))]
         [("--emcc-flags") (val 'emcc-flags)]
         [else (error 'build "unknown option: ~a" a)])])))

;; --- subcommands --------------------------------------------------------

(define (cmd-sync args) (sync))

(define (cmd-apply args)
  (apply-delta #:check-only? (and (member "--check" args) #t)))

;; `build` builds the repo's canonical app -- the IDE (apps/ide) -- into dist/,
;; through the same generic make-wasm-racket path any custom app uses (the
;; dogfood). For a different config, write an app and use `app <dir>`.
(define (cmd-build args)
  (define opts (parse-build-opts args))
  (run-app-manifest ide-app-dir
                    #:dest dist-dir
                    #:scheme (hash-ref opts 'scheme #f)
                    #:racket (hash-ref opts 'racket #f)
                    #:runtime-pkg (hash-ref opts 'runtime #f)
                    #:force? (hash-ref opts 'force? #f)
                    #:emcc-flags (hash-ref opts 'emcc-flags "")))

;; Build a custom app: `app <dir> [--dest <dir>] [--scheme <p>] [--racket <p>]`.
;; <dir>/app.rkt provides `app` (a hash); output lands in <dir>/dist (or --dest).
(define (cmd-app args)
  (when (null? args)
    (error 'app "usage: app <dir> [--dest <dir>] [--scheme <path>] [--racket <path>]"))
  (define dir (car args))
  (define opts (parse-build-opts (cdr args)))
  (run-app-manifest dir
                    #:dest (hash-ref opts 'dest #f)
                    #:scheme (hash-ref opts 'scheme #f)
                    #:racket (hash-ref opts 'racket #f)
                    #:runtime-pkg (hash-ref opts 'runtime #f)
                    #:force? (hash-ref opts 'force? #f)
                    #:emcc-flags (hash-ref opts 'emcc-flags "")))

;; Emit a distributable binary package: `package [<app-dir>] [--dest <dir>]
;; [opts]`. Default app = the IDE; default dest = <app-dir>/package. Produces the
;; package dir (runtime set + metadata) and a sibling .tar.gz.
(define (cmd-package args)
  (define-values (dir rest)
    (if (or (null? args) (string-prefix? (car args) "--"))
        (values ide-app-dir args)
        (values (car args) (cdr args))))
  (define opts (parse-build-opts rest))
  (package-app-manifest dir
                        #:dest (hash-ref opts 'dest #f)
                        #:scheme (hash-ref opts 'scheme #f)
                        #:racket (hash-ref opts 'racket #f)
                        #:force? (hash-ref opts 'force? #f)))

;; Emit a standalone cross-compiler SDK: `cross-sdk [<app-dir>] [--dest <dir>]
;; [opts]`. Default app = the IDE; default dest = <app-dir>/cross-sdk. Builds the
;; cross-compiler + tpb32l cross-root emsdk-free (no --runtime / --force: the SDK
;; is its own from-scratch artifact) and writes the dir + a sibling .tar.gz.
(define (cmd-cross-sdk args)
  (define-values (dir rest)
    (if (or (null? args) (string-prefix? (car args) "--"))
        (values ide-app-dir args)
        (values (car args) (cdr args))))
  (define opts (parse-build-opts rest))
  (cross-sdk-app-manifest dir
                          #:dest (hash-ref opts 'dest #f)
                          #:scheme (hash-ref opts 'scheme #f)
                          #:racket (hash-ref opts 'racket #f)))

;; Fetch + cross-compile new package(s) for tpb32l with a cross-SDK and fold them
;; into a runtime's share.data: `cross-install --sdk <dir> --share-data <path>
;; --dest <dir> [--racket <p>] [--work <d>] [--local <dir>]... <catalog-name>...`.
;; Bare args are catalog package names; `--local <dir>` adds a local source dir.
;; No clone, no emsdk -- just a same-version host racket + the SDK. See
;; build/consume.rkt.
(define (cmd-cross-install args)
  (let loop ([as args] [sdk #f] [share-data #f] [dest #f] [racket #f] [work #f]
                       [catalog #f] [pkgs '()] [locals '()])
    (define (val k) (when (null? (cdr as)) (error 'cross-install "~a requires a value" (car as))) (cadr as))
    (cond
      [(null? as)
       (unless sdk (error 'cross-install "missing --sdk <dir>"))
       (unless share-data (error 'cross-install "missing --share-data <path/share.data>"))
       (unless dest (error 'cross-install "missing --dest <dir>"))
       (when (and (null? pkgs) (null? locals))
         (error 'cross-install "nothing to install (give catalog names and/or --local <dir>)"))
       (cross-install #:sdk sdk #:share-data share-data #:dest dest
                      #:racket racket #:work work #:catalog-dir catalog
                      #:pkgs (reverse pkgs) #:local-pkgs (reverse locals))]
      [else
       (case (car as)
         [("--sdk")        (loop (cddr as) (val '_) share-data dest racket work catalog pkgs locals)]
         [("--share-data") (loop (cddr as) sdk (val '_) dest racket work catalog pkgs locals)]
         [("--dest")       (loop (cddr as) sdk share-data (val '_) racket work catalog pkgs locals)]
         [("--racket")     (loop (cddr as) sdk share-data dest (val '_) work catalog pkgs locals)]
         [("--work")       (loop (cddr as) sdk share-data dest racket (val '_) catalog pkgs locals)]
         [("--catalog")    (loop (cddr as) sdk share-data dest racket work (val '_) pkgs locals)]
         [("--local")      (loop (cddr as) sdk share-data dest racket work catalog pkgs (cons (val '_) locals))]
         [else
          (when (string-prefix? (car as) "--") (error 'cross-install "unknown option: ~a" (car as)))
          (loop (cdr as) sdk share-data dest racket work catalog (cons (car as) pkgs) locals)])])))

;; Repack only the browser package data file (share.data/share.data.js) from
;; the already-installed share/pkgs tree, then refresh dist/. The point of the
;; split: this avoids the emcc relink, so changing packages is cheap.
(define (cmd-pack-pkgs args)
  (pack-packages #:dest (clone-wasm-out) #:cross-root clone-dir)
  (collect-outputs))

(define (parse-serve-args args)
  (when (empty? args) (error "must specify directory to serve"))
  (define path (car args))
  (define port (if (>= (length args) 2)
                   (car (cdr args))
                   "8123"))

  (values path port)
  )
(define (cmd-serve args)
  (define-values (path port) (parse-serve-args args))
  ; (define port (if (pair? args) (car args) "8123"))
  ; (define path (build-path "apps" "ide" "dist"))
  (unless (directory-exists? path)
    (error 'serve "no ~a -- run `build` first" path))
  ;; serve.rkt is repo-side glue, not copied into dist/; run it in place with the
  ;; process cwd set to dist/ (it serves the current directory).
  (define serve.rkt (build-path runtime-glue-dir "serve.rkt"))
  (info-msg "serving ~a on port ~a (COOP/COEP) -> http://127.0.0.1:~a/"
            path port port)
  (run "racket" #:dir path #:args (list (path->string serve.rkt) port)))

(define (cmd-clean args)
  (when (directory-exists? clone-dir)
    (info-msg "removing ~a" clone-dir)
    (delete-directory/files clone-dir))
  (info-msg "clean done"))

(define commands
  (list (cons "sync" cmd-sync)
        (cons "apply" cmd-apply)
        (cons "build" cmd-build)
        (cons "app" cmd-app)
        (cons "package" cmd-package)
        (cons "cross-sdk" cmd-cross-sdk)
        (cons "cross-install" cmd-cross-install)
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
