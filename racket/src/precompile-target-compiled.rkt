#lang racket/base

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         racket/system)

(define default-collections '("racket" "syntax" "compiler" "setup" "reader"))
(define cross-library-names '("chezpart" "rumble" "thread" "io"
                              "regexp" "schemify" "linklet" "expander"))

(define script-path (path->complete-path (find-system-path 'run-file)))
(define src-dir (simplify-path (path-only script-path)))
(define repo-dir (simplify-path (build-path src-dir 'up)))
(define cs-c-dir (build-path src-dir "cs" "c"))
(define expander-env-path (build-path src-dir "cs" "expander" "env.ss"))
(define gen-system-path (build-path cs-c-dir "gen-system.rkt"))
(define collects-dir (build-path repo-dir "collects"))
(define racket-exe-path
  (or (find-executable-path (find-system-path 'exec-file))
      (find-system-path 'exec-file)))

(define target-machine "tpb32l")
(define jobs 1)
(define compile-all? #f)
(define build-dir #f)

(define collections
  (command-line
   #:program "precompile-target-compiled.rkt"
   #:once-each
   [("--target") machine
    "Target machine for compiled output (default: tpb32l)"
    (set! target-machine machine)]
   [("--jobs") worker-count
    "Parallel worker count for raco setup work (default: 1)"
    (define parsed-workers (string->number worker-count))
    (unless (and (exact-integer? parsed-workers) (positive? parsed-workers))
      (raise-user-error 'precompile-target-compiled.rkt
                        "expected a positive integer for --jobs, got ~e"
                        worker-count))
    (set! jobs parsed-workers)]
          [("--build-dir") dir
           "Cross-build workarea to use for target artifacts (default: src/build-cs-<target>)"
           (set! build-dir (path->complete-path dir))]
   [("--all")
    "Compile all installation collections instead of a focused subset"
    (set! compile-all? #t)]
   #:args collection
   collection))

(define selected-collections
  (cond
   [compile-all? #f]
   [(null? collections) default-collections]
   [else collections]))

(define build-dir*
  (or build-dir
      (build-path src-dir (format "build-cs-~a" target-machine))))
(define compiled-subdir (build-path "compiled" target-machine))

(define plugin-dir (build-path build-dir* "cross-compiler"))
(define cross-root-dir (build-path build-dir* "cross-root" target-machine))
(define cross-lib-dir (build-path cross-root-dir "lib"))
(define cross-etc-dir (build-path cross-root-dir "etc"))
(define host-zo-dir (build-path build-dir* "host-zo" target-machine))
(define source-list-path (build-path cross-root-dir "sources.rktd"))
(define compile-xpatch-path (build-path plugin-dir (format "compile-xpatch.~a" target-machine)))
(define library-xpatch-path (build-path plugin-dir (format "library-xpatch.~a" target-machine)))
(define xpatch-path (build-path src-dir "ChezScheme" (format "xc-~a" target-machine) "s" "xpatch"))

(define (path->shell-string p)
  (path->string (simplify-path p)))

(define (read-make-variable path key)
  (define m
    (regexp-match (pregexp (format "(?m:^~a = (.*)$)" (regexp-quote key)))
                  (file->string path)))
  (and m (string-trim (cadr m))))

(define (find-host-machine who)
  (define host-machine (read-make-variable (build-path build-dir* "Makefile") "MACH"))
  (unless host-machine
    (raise-user-error who
                      "could not determine MACH from ~a"
                      (build-path build-dir* "Makefile")))
  host-machine)

(define (require-existing-path who path description)
  (unless (file-exists? path)
    (raise-user-error who "missing ~a at ~a" description path)))

(define (ensure-build-inputs! who)
  (unless (directory-exists? build-dir*)
    (raise-user-error who
                      "missing build directory ~a; pass --build-dir or create the cross-build workarea first"
                      build-dir*))
  (require-existing-path who (build-path build-dir* "Makefile") "cross-build Makefile")
  (require-existing-path who xpatch-path "Chez cross-compiler xpatch"))

(define (build-host-library-paths who)
  (define host-machine (find-host-machine who))
  (for/list ([name (in-list cross-library-names)])
    (define path (build-path build-dir* (format "~a.~a" name host-machine)))
    (require-existing-path who path (format "cross-compiler library fragment for ~a" name))
    path))

(define (find-host-scheme-path who)
  (define host-machine (find-host-machine who))
  (define candidates
    (list (build-path src-dir "build" "cs" "c" "ChezScheme" host-machine "bin" host-machine "scheme")
          (build-path build-dir* "ChezScheme" host-machine "bin" host-machine "scheme")
          (build-path src-dir "build-cs-pb12" "ChezScheme" host-machine "bin" host-machine "scheme")
          (build-path src-dir "build-cs-pb13" "ChezScheme" host-machine "bin" host-machine "scheme")))
  (or (for/or ([path (in-list candidates)])
        (and (file-exists? path) path))
      (raise-user-error who
                        "could not find a native host Chez Scheme executable for ~a"
                        host-machine)))

(define (ensure-cross-compiler-plugin! who)
  (ensure-build-inputs! who)
  (define library-paths (build-host-library-paths who))
  (define host-scheme-path (find-host-scheme-path who))
  (make-directory* plugin-dir)
  (define cross-serve-path (build-path plugin-dir "cross-serve.so"))
  (unless (file-exists? cross-serve-path)
    (parameterize ([current-directory plugin-dir])
      (define exit-code
        (system*/exit-code host-scheme-path
                           "--script"
                           (build-path cs-c-dir "mk-cross-serve.ss")
                           cs-c-dir
                           "cross-serve.ss"
                           expander-env-path))
      (unless (zero? exit-code)
        (raise-user-error who
                          "failed to build cross-serve helper in ~a"
                          plugin-dir))))
  (call-with-output-file compile-xpatch-path
    #:exists 'truncate/replace
    (lambda (out)
      (write-bytes (file->bytes cross-serve-path) out)
      (write-bytes (file->bytes xpatch-path) out)))
  (call-with-output-file library-xpatch-path
    #:exists 'truncate/replace
    (lambda (out)
      (for ([path (in-list library-paths)])
        (write-bytes (file->bytes path) out))))
  plugin-dir)

(define (write-cross-config! who)
  (make-directory* cross-lib-dir)
  (make-directory* cross-etc-dir)
  (make-directory* host-zo-dir)
  (define host-machine (find-host-machine who))
  (define exit-code
    (system*/exit-code racket-exe-path
                       gen-system-path
                       (build-path cross-lib-dir "system.rktd")
                       target-machine
                       host-machine
                       "machine"
                       cs-c-dir
                       ""
                       "other"))
  (unless (zero? exit-code)
    (raise-user-error who
                      "failed to generate cross system description in ~a"
                      cross-lib-dir))
  (copy-file compile-xpatch-path
             (build-path cross-lib-dir (format "compile-xpatch.~a" target-machine))
             #t)
  (copy-file library-xpatch-path
             (build-path cross-lib-dir (format "library-xpatch.~a" target-machine))
             #t)
  (call-with-output-file (build-path cross-etc-dir "config.rktd")
    #:exists 'truncate/replace
    (lambda (out)
      (write (hash 'lib-search-dirs (list (path->shell-string cross-lib-dir))) out)
      (newline out))))

(define (collection-name->dir collection)
  (apply build-path collects-dir (string-split collection "/")))

(define (all-collection-names)
  (for/list ([p (in-list (directory-list collects-dir))]
             #:when (directory-exists? (build-path collects-dir p)))
    (path->string p)))

(define module-suffixes '(#".rkt" #".ss" #".scm"))

(define (bytes-has-suffix? bs suffix)
  (define bs-len (bytes-length bs))
  (define suffix-len (bytes-length suffix))
  (and (>= bs-len suffix-len)
       (bytes=? (subbytes bs (- bs-len suffix-len)) suffix)))

(define (module-source-path? path)
  (define path-bytes (path->bytes path))
  (and (file-exists? path)
       (for/or ([suffix (in-list module-suffixes)])
         (bytes-has-suffix? path-bytes suffix))))

(define (skip-dir-name? name)
  (member (path->string name)
          '("compiled" "doc" "scribblings")))

(define (collect-module-source-files dir)
  (let walk ([dir dir])
    (for/fold ([files null]) ([entry (in-list (directory-list dir))])
      (define path (build-path dir entry))
      (cond
       [(directory-exists? path)
        (if (skip-dir-name? entry)
            files
            (append (walk path) files))]
       [(module-source-path? path)
        (cons path files)]
       [else files]))))

(define (collection-source-files who)
  (define collection-names (or selected-collections (all-collection-names)))
  (for/fold ([files null]) ([collection (in-list collection-names)])
    (define dir (collection-name->dir collection))
    (unless (directory-exists? dir)
      (raise-user-error who "missing collection directory for ~a at ~a" collection dir))
    (append (collect-module-source-files dir)
            files)))

(define (write-source-list! who)
  (make-directory* cross-root-dir)
  (call-with-output-file source-list-path
    #:exists 'truncate/replace
    (lambda (out)
      (write (map path->shell-string (collection-source-files who)) out)
      (newline out))))

(define (run-cross-compile who)
  (ensure-cross-compiler-plugin! who)
  (write-cross-config! who)
  (write-source-list! who)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env
                              #"PLT_ZO_PATH"
                              (string->bytes/utf-8 (path->shell-string compiled-subdir)))
  (parameterize ([current-environment-variables env])
    (apply system*/exit-code
           racket-exe-path
           (append
            (list "--cross"
                  "--cross-compiler" target-machine cross-lib-dir
                  "-MCR" (format "~a:" (path->shell-string host-zo-dir))
                  "-G" cross-etc-dir
                  "-X" collects-dir
                  "-e"
                  (format
                       "(begin (require compiler/cm) (for-each managed-compile-zo (map string->path (call-with-input-file ~s read))))"
                   (path->shell-string source-list-path)))
            null))))

(printf "target machine: ~a\n" target-machine)
(printf "build dir: ~a\n" build-dir*)
(printf "cross plugin dir: ~a\n" plugin-dir)
(printf "cross root dir: ~a\n" cross-root-dir)
(printf "host zo dir: ~a\n" host-zo-dir)
(printf "compiled path: ~a\n" compiled-subdir)
(printf "jobs: ~a\n" jobs)
(if selected-collections
    (printf "collections: ~a\n" (string-join selected-collections ", "))
    (printf "collections: all installation collections\n"))

(unless (zero? (run-cross-compile 'precompile-target-compiled.rkt))
  (raise-user-error 'precompile-target-compiled.rkt
                    "cross compilation reported errors for target ~a"
                    target-machine))

(printf "finished writing target-specific compiled files under */~a\n"
        compiled-subdir)
