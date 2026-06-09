#lang racket/base
;; The build-metadata sidecar: a `racket-wasm.build.rktd` file (an S-expression
;; `hash`) that records a build's `build-key` AND the components that produced it
;; (build/cache.rkt `build-key-components`). It is written into:
;;   - every app build's output (`dist/`),
;;   - runtime cache entries (`.work/runtime-cache/<key>/`),
;;   - distributable binary packages (the `package` subcommand).
;;
;; A distributable package is a directory of `runtime-output-names` plus this
;; file. Consuming one (`app <dir> --runtime <pkg-dir>`) recomputes the app's
;; *expected* components/key from the local repo + manifest and compares them to
;; the package's recorded values -- a mismatch means the package was built from a
;; different delta / dep set than the app expects, and is reported
;; component-by-component (`key-mismatch-report`) before erroring (or warning,
;; under `--force`).
;;
;; `racket-version` is recorded for the record but is deliberately NOT part of
;; the key (the key is determined by the delta + dep set; the host == target
;; version per CLAUDE.md, so it is informational provenance, not an input).
(require racket/format
         racket/list
         racket/string
         racket/date
         "util.rkt")

(provide build-metadata-filename
         make-build-metadata write-build-metadata! read-build-metadata
         key-mismatch-report host-racket-version)

(define build-metadata-filename "racket-wasm.build.rktd")

;; ISO-8601 UTC timestamp, e.g. "2026-06-09T17:04:22Z".
(define (iso-now)
  (define d (seconds->date (current-seconds) #f))
  (define (p n) (~r n #:min-width 2 #:pad-string "0"))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d) (p (date-month d)) (p (date-day d))
          (p (date-hour d)) (p (date-minute d)) (p (date-second d))))

;; Build the metadata hash. `components` is a build-key-components hash; `key`
;; its `key-from-components`; `runtime-files` the file names present alongside
;; this metadata; `racket-version` the build's Racket version (or #f).
(define (make-build-metadata #:key key #:components components
                             #:racket-version [racket-version #f]
                             #:runtime-files [runtime-files '()])
  (hash 'format-version 1
        'build-key      key
        'components     components
        'racket-version racket-version
        'runtime-files  runtime-files
        'created        (iso-now)))

(define (write-build-metadata! dir meta)
  (call-with-output-file (build-path dir build-metadata-filename)
    (lambda (out) (writeln meta out))
    #:exists 'replace))

;; Read a package/dist metadata hash from `dir`, or #f when absent/unreadable.
(define (read-build-metadata dir)
  (define f (build-path dir build-metadata-filename))
  (and (file-exists? f)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define v (call-with-input-file f read))
         (and (hash? v) v))))

;; Render a component value for a human-readable diff line.
(define (fmt-component k v)
  (cond
    [(eq? k 'local-pkgs)
     (if (null? v) "(none)"
         (string-join (for/list ([p (in-list v)])
                        (format "~a@~a" (car p) (substring (cdr p) 0 (min 8 (string-length (cdr p))))))
                      " "))]
    [(eq? v #f) "(none)"]
    [(equal? v "") "(empty)"]
    [else (format "~a" v)]))

;; A human-readable report of how the app's expected components differ from a
;; package's recorded components. `pkg-meta` is a read-build-metadata hash.
;; Returns "" when they fully agree.
(define (key-mismatch-report expected-key expected-components pkg-meta)
  (define pkg-key (hash-ref pkg-meta 'build-key "?"))
  (define pkg-components (hash-ref pkg-meta 'components (hash)))
  (define keys
    (remove-duplicates (append (hash-keys expected-components) (hash-keys pkg-components))))
  (define lines
    (for/list ([k (in-list (sort keys symbol<?))]
               #:unless (equal? (hash-ref expected-components k #f)
                                (hash-ref pkg-components k #f)))
      (format "    ~a: app expects ~a / package has ~a"
              k
              (fmt-component k (hash-ref expected-components k #f))
              (fmt-component k (hash-ref pkg-components k #f)))))
  (string-append
   (format "build-key mismatch: app expects ~a, package is ~a" expected-key pkg-key)
   (if (null? lines) "" (string-append "\n" (string-join lines "\n")))))

;; The Racket version a build will produce, captured from the resolved host
;; Racket (CLAUDE.md requires host == target version). `raco version` /
;; `racket --version` prints e.g. "Welcome to Racket v8.17 [cs].".
(define (host-racket-version racket-path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (string-trim (run/string racket-path #:args '("--version")))))
