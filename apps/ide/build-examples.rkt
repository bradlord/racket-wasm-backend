#lang racket/base
;; Post-build hook for the IDE app (wired in via `app.rkt`'s `hooks` field).
;;
;; The IDE's example programs live one-per-file under `examples/`, and the page
;; driver source lives at `ide.js` (next to this module, *outside* `public/` so
;; collect-outputs doesn't copy it verbatim). This hook runs once dist/ is
;; assembled: it reads every example file, builds the `EXAMPLES` array the page
;; expects (`[{name, code}, ...]`), splices it into `ide.js` in place of the
;; `__EXAMPLES__` token, and writes the result to `dist/ide.js`.
;;
;; A filename like `01-hello-world.rkt` orders the example (sorted by filename)
;; and gives its dropdown name: the leading `NN-` and the extension are dropped,
;; dashes become spaces, and the first letter is upcased -> "Hello world". The
;; file's full text (including its `#lang` line) is the program, verbatim.
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

;; "01-hello-world.rkt" -> "Hello world"
(define (display-name file-name)
  (define stem (path->string (path-replace-extension file-name #"")))
  ;; Drop a leading ordering prefix: one-or-more digits then a dash.
  (define unprefixed (regexp-replace #rx"^[0-9]+-" stem ""))
  (define spaced (string-replace unprefixed "-" " "))
  (if (= 0 (string-length spaced))
      spaced
      (string-append (string-upcase (substring spaced 0 1))
                     (substring spaced 1))))

(define (build-ide-js ctx)
  (define app-dir (hash-ref ctx 'app-dir))
  (define dist    (hash-ref ctx 'dist))
  (define examples-dir (build-path app-dir "examples"))
  (define src (build-path app-dir "ide.js"))
  (unless (directory-exists? examples-dir)
    (error 'build-ide-js "no examples dir at ~a" examples-dir))
  (unless (file-exists? src)
    (error 'build-ide-js "no ide.js source at ~a" src))
  ;; Sorted by filename so the `NN-` prefixes order the dropdown.
  (define files
    (sort (for/list ([p (in-list (directory-list examples-dir))]
                     #:when (file-exists? (build-path examples-dir p)))
            p)
          string<? #:key path->string))
  (define examples
    (for/list ([f (in-list files)])
      (hasheq 'name (display-name f)
              'code (file->string (build-path examples-dir f)))))
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
