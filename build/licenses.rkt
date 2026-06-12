#lang racket/base
;; Collect every applicable license text into a `licenses/` tree.
;;
;; The distributed runtime bundles this project (MIT), upstream Racket + Chez
;; (Apache/MIT/LGPL/GPL/libscheme), and a set of native C deps from wasm-deps/
;; (always libffi; the cairo/pango `draw` stack and others when selected). This
;; module assembles all of their license texts so dist/ and the SDK ship a
;; license-compliant bundle.
;;
;; It is CLONE-DRIVEN: the texts live in the disposable clone (.work/racket) and
;; the extracted dep source dirs, which are present only on a build *miss*. So
;; `assemble-licenses!` is called from `ensure-base-runtime!` (into the wasm-deps
;; -keyed base cache) and `package-cross-sdk` (into the SDK) -- both points have a
;; warm clone. dist/ and packages then copy the cached tree, never regenerate it.
;;
;; Deps are discovered by scanning <clone>/racket/src for `build-<name>-em` dirs:
;; that is exactly the set of wasm-deps recipes that ran (libffi always, plus the
;; selected ones), so this needs no knowledge of the WASM_DEPS string or the bash
;; `draw` alias expansion. rktio is in-tree (no build-*-em dir) and covered by
;; Racket's own license, so it is correctly excluded.
(require racket/file
         racket/path
         racket/string
         racket/list
         "config.rkt"
         "util.rkt")

(provide assemble-licenses!)

;; Filename patterns (case-insensitive, glob-ish) treated as license texts when
;; found at a dep's source root. Covers the common spellings plus FreeType's FTL.
(define license-name-patterns
  '("license" "licence" "copying" "copyright" "notice" "ftl" "gpl"))

;; Per-dep overrides for deps whose texts aren't all discoverable by the root
;; glob (e.g. files in subdirs, or a whole SPDX directory). A present entry
;; REPLACES the glob: list every wanted path, relative to the dep's source root.
;; A path that names a FILE is copied flattened to <dep>/<basename>; a path that
;; names a DIRECTORY is copied as a tree to <dep>/<dirname>/ (structure kept).
;; Confirmed at-root deps (libffi, cairo, pango, harfbuzz, ...) need no entry.
(define dep-license-overrides
  (hash
   ;; FreeType ships the dual-license notice at the root and the actual FTL +
   ;; GPLv2 texts under docs/.
   "freetype" '("LICENSE.TXT" "docs/FTL.TXT" "docs/GPLv2.TXT")
   ;; glib carries the umbrella COPYING plus an SPDX LICENSES/ dir of the
   ;; per-identifier texts (Apache/MIT/LGPL/GPL/MPL/...); keep the whole dir.
   "glib" '("COPYING" "LICENSES")))

;; Does `name` (a filename string) look like a license text per the patterns?
(define (license-name? name)
  (define lower (string-downcase name))
  (for/or ([pat (in-list license-name-patterns)])
    (regexp-match? (regexp-quote pat) lower)))

;; Copy `src` (a file) to `dst`, overwriting, preserving permission bits.
;; Mirrors util.rkt copy-tree's leaf idiom.
(define (copy-file* src dst)
  (make-directory* (path-only dst))
  (when (or (file-exists? dst) (link-exists? dst)) (delete-file dst))
  (copy-file src dst)
  (file-or-directory-permissions dst (file-or-directory-permissions src 'bits)))

;; License files at the root of `dir` (a dep source dir), by the glob.
(define (glob-license-files dir)
  (for/list ([p (in-list (directory-list dir))]
             #:when (file-exists? (build-path dir p))
             #:when (license-name? (path->string p)))
    p))

;; Write the full `licenses/` tree into <dest-dir>/licenses, overwriting.
;; `clone` is the upstream clone root (config's clone-dir by default).
(define (assemble-licenses! dest-dir #:clone [clone clone-dir])
  (define lic (build-path dest-dir "licenses"))
  (define racket-out (build-path lic "racket"))
  (define deps-out (build-path lic "deps"))
  (make-directory* racket-out)
  (make-directory* deps-out)

  ;; 1. Umbrella notice.
  (call-with-output-file (build-path lic "README.txt")
    (lambda (o) (write-string license-readme-text o))
    #:exists 'truncate)

  ;; 2. This project's own MIT license.
  (if (file-exists? repo-license-file)
      (copy-file* repo-license-file (build-path lic "racket-wasm-MIT.txt"))
      (warn "repo license file missing: ~a" repo-license-file))

  ;; 3. Upstream Racket's license set: <clone>/racket/src/LICEN*.txt.
  (define racket-src (build-path clone "racket" "src"))
  (define racket-licenses
    (if (directory-exists? racket-src)
        (for/list ([p (in-list (directory-list racket-src))]
                   #:when (file-exists? (build-path racket-src p))
                   #:when (regexp-match? #rx"(?i:^licen[sc]e).*[.]txt$"
                                         (path->string p)))
          p)
        '()))
  (cond
    [(null? racket-licenses)
     (warn "no Racket license files found under ~a" racket-src)]
    [else
     (for ([p (in-list racket-licenses)])
       (copy-file* (build-path racket-src p) (build-path racket-out p)))])

  ;; 4. Native deps: one subdir per `build-<name>-em` dir in racket/src.
  (when (directory-exists? racket-src)
    (for ([p (in-list (directory-list racket-src))])
      (define m (regexp-match #rx"^build-(.+)-em$" (path->string p)))
      (when m
        (collect-dep-licenses (cadr m)
                              (build-path racket-src p "src")
                              deps-out))))

  ;; 5. A browsable index: the umbrella notice + relative links to every file
  ;;    collected above. Written last so it links the final tree.
  (write-license-index! lic license-index-name)

  (info-msg "licenses collected into ~a" lic))

;; --- HTML index ---------------------------------------------------------

(define license-index-name "licenses.html")

;; Minimal HTML escaping for text/attribute content.
(define (html-escape s)
  (regexp-replace*
   #rx">" (regexp-replace*
           #rx"<" (regexp-replace* #rx"&" s "\\&amp;") "\\&lt;")
   "\\&gt;"))

;; All file paths under `root`, as "/"-joined relative strings, recursively,
;; sorted. Directories are descended; only files are listed.
(define (all-files-rel root)
  (sort
   (let loop ([dir root] [prefix ""])
     (append*
      (for/list ([p (in-list (directory-list dir))])
        (define full (build-path dir p))
        (define rel (if (string=? prefix "")
                        (path->string p)
                        (string-append prefix "/" (path->string p))))
        (if (directory-exists? full) (loop full rel) (list rel)))))
   string<?))

;; Write `licenses/<index-name>`: the umbrella notice in a <pre>, then relative
;; links to every collected file, grouped by origin (this project / Racket /
;; each dependency). README.txt (its text is inlined) and the index itself are
;; omitted from the link list.
(define (write-license-index! lic index-name)
  (define rels
    (filter (lambda (r) (not (member r (list index-name "README.txt"))))
            (all-files-rel lic)))
  (define top    (filter (lambda (r) (not (string-contains? r "/"))) rels))
  (define racket (filter (lambda (r) (string-prefix? r "racket/")) rels))
  (define deps   (filter (lambda (r) (string-prefix? r "deps/")) rels))
  (define (items rs o)
    (fprintf o "<ul>\n")
    (for ([r (in-list rs)])
      (fprintf o "  <li><a href=\"~a\">~a</a></li>\n" (html-escape r) (html-escape r)))
    (fprintf o "</ul>\n"))
  (call-with-output-file (build-path lic index-name)
    #:exists 'truncate
    (lambda (o)
      (fprintf o "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
      (fprintf o "<title>racket-wasm licenses</title>\n")
      (fprintf o (string-append
                  "<style>body{font-family:system-ui,sans-serif;max-width:48rem;"
                  "margin:2rem auto;padding:0 1rem;line-height:1.5}"
                  "pre{white-space:pre-wrap}h2{margin-top:2rem}"
                  "h3{margin:1rem 0 .25rem}ul{margin:.25rem 0}</style>\n"))
      (fprintf o "</head>\n<body>\n")
      (fprintf o "<pre>~a</pre>\n" (html-escape license-readme-text))
      (unless (null? top)
        (fprintf o "<h2>This project</h2>\n") (items top o))
      (unless (null? racket)
        (fprintf o "<h2>Racket</h2>\n") (items racket o))
      (unless (null? deps)
        (fprintf o "<h2>Dependencies</h2>\n")
        ;; Sub-group by dep name (the segment after "deps/"); rels are sorted, so
        ;; group-by yields them in alphabetical dep order.
        (for ([grp (in-list (group-by (lambda (r) (cadr (string-split r "/"))) deps))])
          (fprintf o "<h3>~a</h3>\n" (html-escape (cadr (string-split (car grp) "/"))))
          (items grp o)))
      (fprintf o "</body>\n</html>\n"))))

;; Copy `name`'s license file(s) from its source dir `dep-src` into
;; <deps-out>/<name>/. Uses the override list when present, else the root glob.
(define (collect-dep-licenses name dep-src deps-out)
  ;; A built dep with no extracted src (e.g. a source-less recipe) has nothing to
  ;; collect, and nothing to warn about -- just skip it.
  (when (directory-exists? dep-src)
    (define rels
      (cond
        [(hash-ref dep-license-overrides name #f) => values]
        [else (map path->string (glob-license-files dep-src))]))
    (define dst-dir (build-path deps-out name))
    (define copied
      (for/fold ([n 0]) ([rel (in-list rels)])
        (define src (build-path dep-src rel))
        (cond
          [(directory-exists? src)
           ;; A whole license dir (e.g. glib's SPDX LICENSES/): keep its name +
           ;; structure under the dep dir.
           (copy-tree src (build-path dst-dir (file-name-from-path rel)))
           (add1 n)]
          [(file-exists? src)
           ;; Flatten subdir paths (docs/FTL.TXT -> FTL.TXT) so each dep dir is flat.
           (copy-file* src (build-path dst-dir (file-name-from-path rel)))
           (add1 n)]
          [else n])))
    (when (zero? copied)
      (warn "no license file found for dep ~a (looked in ~a)" name dep-src))))

(define (warn fmt . args)
  (eprintf "license collection warning: ~a\n" (apply format fmt args)))
