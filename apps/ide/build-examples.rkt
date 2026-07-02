#lang racket/base
;; Post-build hook for the IDE app (wired in via `app.rkt`'s `hooks` field).
;;
;; The IDE's example programs live under `examples/`, one entry per example,
;; and the page driver source lives at `ide.js` (next to this module, *outside*
;; `public/` so collect-outputs doesn't copy it verbatim). This hook runs once
;; dist/ is assembled: it reads every example, builds the `EXAMPLES` array the
;; page expects (`[{name, files:[{name, code}, ...]}, ...]`), splices it into
;; `ide.js` in place of the `__EXAMPLES__` token, and writes the result to
;; `dist/ide.js`.
;;
;; An entry under `examples/` is either a **flat file** (`01-hello-world.rkt`,
;; a single-file example whose one tab is named `hello-world.rkt` -- the
;; ordering prefix stripped, extension kept) or a **directory**
;; (`09-two-file-demo/`, a multi-file example whose contents -- real
;; filenames, no ordering prefix -- become one tab each, sorted with
;; `main.rkt` first since that's the initial active tab). Either way, the
;; leading `NN-` ordering prefix on the entry itself picks the dropdown order
;; and, minus the prefix (and, for a flat file, the extension), gives its
;; display name: dashes become spaces, first letter upcased -> "Hello world".
;; File contents (including `#lang` lines) are the program, verbatim.
;;
;; In addition to splicing examples, this hook vendors the CodeMirror 5 editor
;; tree (apps/ide/vendor/codemirror/) into dist/codemirror/. The vendor dir
;; lives outside public/ so collect-outputs doesn't ship it verbatim (it only
;; copies flat files); we hand-copy the subtree here so the page's
;; <script src="./codemirror/..."> tags resolve at runtime. Vendored, not
;; CDN-loaded, to keep dist/ self-contained (the page needs COOP/COEP for
;; SharedArrayBuffer; an external dependency would still work but breaks the
;; "ship one directory" property).
(require racket/string
         racket/path
         racket/file
         json)

(provide build-ide-js)

;; Drop a leading ordering prefix ("NN-") from a stem or filename.
(define (strip-order-prefix s)
  (regexp-replace #rx"^[0-9]+-" s ""))

;; "01-hello-world" -> "Hello world" (stem, no extension, no ordering prefix)
(define (display-name stem)
  (define spaced (string-replace (strip-order-prefix stem) "-" " "))
  (if (= 0 (string-length spaced))
      spaced
      (string-append (string-upcase (substring spaced 0 1))
                     (substring spaced 1))))

;; Sort a multi-file example's filenames with main.rkt first, else alphabetic.
(define (file-order a b)
  (cond
    [(string=? a "main.rkt") #t]
    [(string=? b "main.rkt") #f]
    [else (string<? a b)]))

(define (build-ide-js ctx)
  (define app-dir (hash-ref ctx 'app-dir))
  (define dist    (hash-ref ctx 'dist))
  (define examples-dir (build-path app-dir "examples"))
  (define src (build-path app-dir "ide.js"))
  (unless (directory-exists? examples-dir)
    (error 'build-ide-js "no examples dir at ~a" examples-dir))
  (unless (file-exists? src)
    (error 'build-ide-js "no ide.js source at ~a" src))
  ;; Sorted by entry name so the `NN-` prefixes order the dropdown.
  (define entries
    (sort (directory-list examples-dir) string<? #:key path->string))
  (define examples
    (for/list ([e (in-list entries)])
      (define e-path (build-path examples-dir e))
      (define e-name (path->string e))
      (cond
        [(directory-exists? e-path)
         (define stem (strip-order-prefix e-name))
         (define file-names
           (sort (for/list ([p (in-list (directory-list e-path))]
                            #:when (file-exists? (build-path e-path p)))
                   (path->string p))
                 file-order))
         (hasheq 'name (display-name stem)
                 'files (for/list ([fn (in-list file-names)])
                          (hasheq 'name fn
                                  'code (file->string (build-path e-path fn)))))]
        [else
         (define stem (path->string (path-replace-extension e #"")))
         (define ext (path-get-extension e))
         (define tab-name
           (string-append (strip-order-prefix stem)
                           (if ext (bytes->string/utf-8 ext) "")))
         (hasheq 'name (display-name stem)
                 'files (list (hasheq 'name tab-name
                                      'code (file->string e-path))))])))
  (define template (file->string src))
  (define n-tokens (length (regexp-match-positions* #rx"__EXAMPLES__" template)))
  (unless (= n-tokens 1)
    (error 'build-ide-js "expected exactly one __EXAMPLES__ token in ~a, found ~a" src n-tokens))
  (define out (string-replace template "__EXAMPLES__" (jsexpr->string examples)))
  (define dest (build-path dist "ide.js"))
  (call-with-output-file dest #:exists 'replace
    (lambda (o) (write-string out o)))
  ;; Vendor the CodeMirror 5 tree into dist/codemirror/. copy-directory/files
  ;; is idempotent over a rebuild: it errors if a file exists at the dest, so
  ;; wipe the dest first (a stale vendor file would otherwise survive a
  ;; downgrade).
  (define vendor-src (build-path app-dir "vendor" "codemirror"))
  (define vendor-dest (build-path dist "codemirror"))
  (unless (directory-exists? vendor-src)
    (error 'build-ide-js "no codemirror vendor tree at ~a" vendor-src))
  (when (directory-exists? vendor-dest) (delete-directory/files vendor-dest))
  (copy-directory/files vendor-src vendor-dest)
  (printf "ide.js: merged ~a example~a into ~a\n"
          (length examples) (if (= 1 (length examples)) "" "s") dest)
  (printf "codemirror: vendored ~a into ~a\n" vendor-src vendor-dest))
