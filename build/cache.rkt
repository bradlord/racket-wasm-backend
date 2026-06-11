#lang racket/base
;; A content-complete runtime cache, keyed by everything that determines the
;; runtime binary + package payload: the pinned upstream SHA, a hash of the delta
;; (patches/ + overlay/ + overlay-local/), the native-dep selection (WASM_DEPS),
;; and the package set (PKGS). Two app configs that differ in any of these get
;; separate cache entries and never clobber each other in the one shared clone --
;; the Phase 3 "build isolation" win. A config that has already been built is
;; reassembled by *copying from cache*: no `make`, no relink, no clone mutation.
;;
;; Only the heavy runtime set (`runtime-output-names`) is cached; the glue and
;; page surface are repo-side and copied fresh on every assemble, so editing a
;; surface never invalidates the cache.
(require racket/file
         racket/path
         racket/string
         file/sha1
         "config.rkt"
         "util.rkt")

(provide build-key build-key-components key-from-components
         cache-dir-for cache-complete? snapshot-runtime!
         sdk-cache-dir-for sdk-cached?
         app-payload-cache-dir-for app-payload-cached?
         consume-work-dir-for pkg-catalog-dir-for)

(define cache-root (build-path work-dir "runtime-cache"))

;; sha1 of a directory tree's contents: sorted "<relpath>:<file-sha1>" lines,
;; hashed. "" when the dir is absent. Cheap on patches/overlay (modest size); the
;; point is that any edit to the delta invalidates caches even when PKGS /
;; WASM_DEPS are unchanged.
(define (dir-content-hash dir)
  (cond
    [(not (directory-exists? dir)) ""]
    [else
     (define base (simplify-path (path->complete-path dir)))
     (define lines
       (sort
        (for/list ([p (in-directory dir)] #:when (file-exists? p))
          (string-append
           (path->string (find-relative-path base (path->complete-path p)))
           ":"
           (call-with-input-file p sha1)))
        string<?))
     (sha1 (open-input-string (string-join lines "\n")))]))

;; The *components* that determine a (pkgs, wasm-deps, local-pkgs[, link-js])
;; build, as an inspectable hash. This is the single source of truth for the
;; build-key -- `key-from-components` hashes these into the key, and the
;; package/dist metadata records them verbatim so a key mismatch can be reported
;; component-by-component (build/metadata.rkt). pkgs/wasm-deps are the make-var
;; strings ("" = none).
;;   'upstream-sha 'upstream-url  the pinned upstream the delta applies onto.
;;   'delta-hash   sha1 of patches/ + overlay/ + overlay-local/ contents.
;;   'wasm-deps 'pkgs  the make-var strings.
;;   'local-pkgs   a list of (basename . content-hash) -- both *which* packages
;;                 and *what's in them* feed the key (so editing one rebuilds).
;;   'link-js      surface-tagged hash of the emcc link-JS contents, or #f when
;;                 the app supplies none (see the note in key-from-components).
;;   'target       the surface the link JS targets (only meaningful with link-js).
(define (build-key-components #:pkgs pkgs #:wasm-deps wasm-deps
                             #:local-pkgs [local-pkgs '()]
                             #:link-js [link-js '()] #:target [target 'browser])
  (define delta
    (sha1 (open-input-string
           (string-append (dir-content-hash patches-dir) "|"
                          (dir-content-hash overlay-dir) "|"
                          (dir-content-hash overlay-local-dir)))))
  ;; Identify each local package by its basename + a hash of its contents.
  (define locals
    (for/list ([p (in-list local-pkgs)])
      (define dir (if (path? p) p (string->path p)))
      (cons (path->string (file-name-from-path dir)) (dir-content-hash dir))))
  ;; Surface-tagged hash of the link-JS file contents (basename + file sha1,
  ;; sorted). #f when there is no link JS -- so it is omitted from the key.
  (define link-component
    (if (null? link-js)
        #f
        (string-append
         (format "~a" (normalize-target target)) ":"
         (sha1 (open-input-string
                (string-join
                 (sort
                  (for/list ([p (in-list link-js)])
                    (define f (if (path? p) p (string->path p)))
                    (string-append (path->string (file-name-from-path f)) ":"
                                   (if (file-exists? f) (call-with-input-file f sha1) "")))
                  string<?)
                 "|"))))))
  (hash 'upstream-sha upstream-sha
        'upstream-url upstream-url
        'delta-hash   delta
        'wasm-deps    wasm-deps
        'pkgs         pkgs
        'local-pkgs   locals
        'link-js      link-component
        'target       (normalize-target target)))

;; Hash a components hash into the 16-hex build-key. The join is, byte for byte,
;; the one this code has always produced: `upstream-sha | delta | wasm-deps |
;; pkgs | locals [| link-component]`, where `locals` is the sha1 of the sorted
;; "basename:content-hash" lines and the link component is appended only when an
;; app supplies link JS. Keeping the join in one place means the recorded
;; components and the key can never drift. Truncated to 16 hex -- ample locally.
(define (key-from-components c)
  (define locals
    (sha1 (open-input-string
           (string-join
            (sort (for/list ([p (in-list (hash-ref c 'local-pkgs))])
                    (string-append (car p) ":" (cdr p)))
                  string<?)
            "|"))))
  (define link-component (hash-ref c 'link-js))
  (substring
   (sha1 (open-input-string
          (string-join (append (list (hash-ref c 'upstream-sha)
                                     (hash-ref c 'delta-hash)
                                     (hash-ref c 'wasm-deps)
                                     (hash-ref c 'pkgs)
                                     locals)
                               (if link-component (list link-component) '()))
                       "|")))
   0 16))

(define (build-key #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs [local-pkgs '()]
                   #:link-js [link-js '()] #:target [target 'browser])
  (key-from-components
   (build-key-components #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs local-pkgs
                         #:link-js link-js #:target target)))

(define (cache-dir-for key) (build-path cache-root key))

;; A cache entry is usable only if every file in `names` is present. `names`
;; defaults to the full runtime set; the split build passes `base-runtime-names`
;; (package-agnostic binaries) or `pkg-payload-names` (share.data*) so each layer
;; caches under its own key independently.
(define (cache-complete? key [names runtime-output-names])
  (define d (cache-dir-for key))
  (and (directory-exists? d)
       (for/and ([n (in-list names)])
         (file-exists? (build-path d n)))))

;; Copy the files in `names` from `src` into the cache for `key`. `names`
;; defaults to the full runtime set (see `cache-complete?`).
(define (snapshot-runtime! key src [names runtime-output-names])
  (define d (cache-dir-for key))
  (make-directory* d)
  (for ([n (in-list names)])
    (define s (build-path src n))
    (when (file-exists? s)
      (define dst (build-path d n))
      (when (file-exists? dst) (delete-file dst))
      (copy-file s dst)))
  (info-msg "cached ~a file(s) under ~a" (length names) d))

;; --- the clone-free package layer caches --------------------------------
;;
;; The app's packages no longer flow through a clone-bound cross-root. Instead a
;; pure cross-compiler SDK is built once per (delta, wasm-deps) and the app's
;; packages are cross-installed against it into the base `share.data`
;; (build/consume.rkt). Three regenerable caches under .work/ replace the old
;; cross-root cache:

;; The pure cross-compiler SDK, keyed by (delta, wasm-deps) -- one SDK serves
;; every app on that native-dep profile. `sdk-cached?` checks the pieces the
;; consume needs: the retarget files, the tpb32l `system.rktd`, and the in-tree
;; pkgs (so the base packages register as installed).
(define sdk-cache-root (build-path work-dir "sdk-cache"))
(define (sdk-cache-dir-for key) (build-path sdk-cache-root key))
(define (sdk-cached? key)
  (define d (sdk-cache-dir-for key))
  (and (directory-exists? (build-path d "cross-compiler"))
       (file-exists? (build-path d "cross-root" "lib" "system.rktd"))
       (directory-exists? (build-path d "pkgs"))))

;; The cross-installed app payload: the base `share.data` extended with the app's
;; packages, keyed by the package set (pkg-key) so it is reused across surfaces /
;; link-JS variants. `build-runtime` copies it into dist/.
(define app-payload-cache-root (build-path work-dir "app-payload-cache"))
(define (app-payload-cache-dir-for key) (build-path app-payload-cache-root key))
(define (app-payload-cached? key)
  (define d (app-payload-cache-dir-for key))
  (and (file-exists? (build-path d "share.data"))
       (file-exists? (build-path d "share.data.js"))))

;; A persistent scratch dir for the cross-install's host-form/target compile
;; shadows (hostzo/xtgt), keyed by the SDK (delta, wasm-deps). Reused across
;; consumes so only the NEW packages compile after the first (the addon is wiped
;; fresh each consume; see build/consume.rkt). Purely a speed cache.
(define consume-work-root (build-path work-dir "consume-work"))
(define (consume-work-dir-for key) (build-path consume-work-root key))

;; The persistent built-package catalog the consume installs from, keyed by the
;; SDK (delta, wasm-deps) so its `tpb32l` `.zo` always match what is being built.
;; ACCUMULATING (never wiped): each app's packages are staged + stripped into it
;; once and reused; the final consume selects an app's closure out of it. See
;; build/consume.rkt `refresh-pkg-catalog!`.
(define pkg-catalog-root (build-path work-dir "pkg-catalog"))
(define (pkg-catalog-dir-for key) (build-path pkg-catalog-root key))
