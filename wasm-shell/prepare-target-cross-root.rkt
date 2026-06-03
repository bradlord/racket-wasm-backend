#lang racket/base

;; Build only the cross-root scaffolding for a target machine -- the
;; lib/ (system.rktd + xpatches) and etc/ (config.rktd) -- without
;; compiling any collections. This is the setup half of
;; precompile-target-compiled.rkt, split out so the cross-root that
;; `racket-cross` points at can be (re)generated cheaply.

(require racket/cmdline
         racket/file
         racket/path
         racket/string
         racket/system)

(define cross-library-names '("chezpart" "rumble" "thread" "io"
                              "regexp" "schemify" "linklet" "expander"))

(define script-path (path->complete-path (find-system-path 'run-file)))
;; This script lives in wasm-shell/ at the repo root; src-dir is racket/src.
(define shell-dir (simplify-path (path-only script-path)))
(define src-dir (simplify-path (build-path shell-dir 'up "racket" "src")))
(define cs-c-dir (build-path src-dir "cs" "c"))
(define expander-env-path (build-path src-dir "cs" "expander" "env.ss"))
(define gen-system-path (build-path cs-c-dir "gen-system.rkt"))
(define racket-exe-path
  (or (find-executable-path (find-system-path 'exec-file))
      (find-system-path 'exec-file)))

(define target-machine "tpb32l")
(define build-dir #f)

(command-line
 #:program "prepare-target-cross-root.rkt"
 #:once-each
 [("--target") machine
  "Target machine for the cross-root (default: tpb32l)"
  (set! target-machine machine)]
 [("--build-dir") dir
  "Cross-build workarea to use for target artifacts (default: src/build-cs-<target>)"
  (set! build-dir (path->complete-path dir))])

(define build-dir*
  (or build-dir
      (build-path src-dir (format "build-cs-~a" target-machine))))

(define plugin-dir (build-path build-dir* "cross-compiler"))
(define cross-root-dir (build-path build-dir* "cross-root" target-machine))
(define cross-lib-dir (build-path cross-root-dir "lib"))
(define cross-etc-dir (build-path cross-root-dir "etc"))
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
          ;; standalone host Chez from wasm-shell/build-chez-host.sh
          (build-path src-dir "ChezScheme" host-machine "bin" host-machine "scheme")
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

(define who 'prepare-target-cross-root.rkt)

(printf "target machine: ~a\n" target-machine)
(printf "build dir: ~a\n" build-dir*)
(printf "cross plugin dir: ~a\n" plugin-dir)
(printf "cross root dir: ~a\n" cross-root-dir)

(void (ensure-cross-compiler-plugin! who))
(write-cross-config! who)

(printf "wrote ~a\n" (build-path cross-lib-dir "system.rktd"))
(printf "wrote ~a\n" (build-path cross-etc-dir "config.rktd"))
