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

(provide build-key cache-dir-for cache-complete? snapshot-runtime!)

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

;; The cache key for a (pkgs, wasm-deps, local-pkgs) build. pkgs/wasm-deps are
;; the make-var strings ("" = none); local-pkgs is a list of source dirs whose
;; *contents* are hashed in (so editing a local package invalidates the cache).
;; `link-js` is the app's emcc link-JS files (--pre/--post/--extern-pre-js,
;; combined): they change the linked binary, so their *contents* are hashed in,
;; together with the surface they target (only that surface gets the JS at the
;; link). When `link-js` is empty the component is "" and is omitted entirely, so
;; keys for link-JS-free apps stay byte-identical to before this field existed --
;; and a node and a browser app with the same pkgs still share one entry.
;; Truncated to 16 hex chars -- ample for a local cache.
(define (build-key #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs [local-pkgs '()]
                   #:link-js [link-js '()] #:target [target 'browser])
  (define delta
    (sha1 (open-input-string
           (string-append (dir-content-hash patches-dir) "|"
                          (dir-content-hash overlay-dir) "|"
                          (dir-content-hash overlay-local-dir)))))
  ;; Identify each local package by its basename + a hash of its contents, so
  ;; both *which* packages and *what's in them* feed the key. Sorted for order
  ;; independence.
  (define locals
    (sha1 (open-input-string
           (string-join
            (sort
             (for/list ([p (in-list local-pkgs)])
               (define dir (if (path? p) p (string->path p)))
               (string-append (path->string (file-name-from-path dir)) ":"
                              (dir-content-hash dir)))
             string<?)
            "|"))))
  ;; Surface-tagged hash of the link-JS file contents (basename + file sha1,
  ;; sorted). "" when there is no link JS -- see the note above.
  (define link-component
    (if (null? link-js)
        ""
        (string-append
         (format "~a" target) ":"
         (sha1 (open-input-string
                (string-join
                 (sort
                  (for/list ([p (in-list link-js)])
                    (define f (if (path? p) p (string->path p)))
                    (string-append (path->string (file-name-from-path f)) ":"
                                   (if (file-exists? f) (call-with-input-file f sha1) "")))
                  string<?)
                 "|"))))))
  (substring
   (sha1 (open-input-string
          (string-join (append (list upstream-sha delta wasm-deps pkgs locals)
                               (if (equal? link-component "") '() (list link-component)))
                       "|")))
   0 16))

(define (cache-dir-for key) (build-path cache-root key))

;; A cache entry is usable only if every runtime file is present.
(define (cache-complete? key)
  (define d (cache-dir-for key))
  (and (directory-exists? d)
       (for/and ([n (in-list runtime-output-names)])
         (file-exists? (build-path d n)))))

;; Copy the runtime-output set from `src` (the clone's wasm out dir) into the
;; cache for `key`.
(define (snapshot-runtime! key src)
  (define d (cache-dir-for key))
  (make-directory* d)
  (for ([n (in-list runtime-output-names)])
    (define s (build-path src n))
    (when (file-exists? s)
      (define dst (build-path d n))
      (when (file-exists? dst) (delete-file dst))
      (copy-file s dst)))
  (info-msg "runtime cached under ~a" d))
