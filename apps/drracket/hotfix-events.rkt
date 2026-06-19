#lang racket/base
;; Surgical hotfix: recompile queue.rkt for tpb32l and inject the new .zo
;; into the DrRacket dist's share.data -- without a full rebuild.
;;
;; Run from the repo root:
;;   racket apps/drracket/hotfix-events.rkt \
;;     [--racket ~/oss/minimal-racket/bin/racket]
;;
;; Assumes SDK key 7426f39274cef6ab is still in .work/sdk-cache.
;; If it has been evicted, do a full rebuild instead.
(require racket/file racket/path racket/string racket/cmdline
         racket/hash file/sha1 json)

(define (->path p) (if (path? p) p (string->path p)))
(define (->str  p) (if (string? p) p (path->string p)))
(define (real   p) (simplify-path (path->complete-path (->path p))))

(define REPO    (real "."))
(define WORK    (build-path REPO ".work"))
(define SDK-KEY "7426f39274cef6ab")
(define APP-KEY "7a11e04309878dad")
(define TARGET  "tpb32l")

(define dist    (build-path REPO "apps" "drracket" "dist"))
(define sdk-dir (build-path WORK "sdk-cache" SDK-KEY))
(define cat-dir (build-path WORK "pkg-catalog" SDK-KEY))
(define cc-dir  (build-path sdk-dir "cross-compiler"))
(define install (build-path cat-dir "install"))
(define hostzo  (build-path cat-dir "hostzo"))
(define xtgt    (build-path cat-dir "xtgt"))
(define xcfg    (build-path cat-dir "xcfg" "etc"))

(define guilib-wasm
  (build-path install "9.2.0.5" "pkgs" "gui-lib" "mred" "private" "wx" "wasm"))
(define guilib-src (build-path guilib-wasm "queue.rkt"))
(define guilib-zo  (build-path guilib-wasm "compiled" "queue_rkt.zo"))

;; xtgt mirrors absolute paths: strip the leading "/" component.
(define xtgt-zo
  (build-path xtgt (apply build-path (cdr (explode-path (simplify-path guilib-zo))))))

(define racket-opt (make-parameter #f))
(command-line
 #:once-each
 ["--racket" path "Host Racket (must match SDK's Racket version)" (racket-opt path)])

(define racket
  (or (racket-opt)
      (let ([p (find-executable-path "racket")]) (and p (path->string p)))
      (error 'hotfix "pass --racket <path>")))

;; ---- validate required paths -----------------------------------------------
(for ([p (list sdk-dir cc-dir cat-dir install xcfg guilib-src)])
  (unless (or (directory-exists? p) (file-exists? p))
    (error 'hotfix "path missing (SDK ~a may have been evicted): ~a" SDK-KEY p)))

;; ---- 1. Ensure the fix is in the catalog staging source -------------------
(define src-text (file->string guilib-src))
(unless (regexp-match? #rx"or \\(hash-ref windows id" src-text)
  (printf "hotfix: applying fix to catalog staging queue.rkt...\n")
  (define fixed
    (regexp-replace
     #rx"\\(hash-ref windows id #f\\)\\)"
     src-text
     "(or (hash-ref windows id #f) top))"))
  (unless (regexp-match? #rx"or \\(hash-ref windows id" fixed)
    (error 'hotfix "could not auto-patch queue.rkt; pattern not found in source"))
  (call-with-output-file guilib-src #:exists 'replace
    (lambda (o) (write-string fixed o))))
(printf "hotfix: catalog staging queue.rkt has the fix\n")

;; Touch queue.rkt so raco setup sees it as stale vs. the existing .zo.
(file-or-directory-modify-seconds guilib-src (current-seconds))

;; ---- 2. raco setup --pkgs gui-lib with the cross-compiler ----------------
(printf "hotfix: running raco setup --pkgs gui-lib for ~a...\n" TARGET)
(flush-output)

(define lib-dir (simplify-path (build-path (path-only (->path racket)) 'up "lib")))
(define lib-var (if (eq? (system-type 'os) 'macosx) "DYLD_LIBRARY_PATH" "LD_LIBRARY_PATH"))
(define lib-val
  (let ([ex (or (getenv lib-var) "")])
    (string-append (->str lib-dir) (if (string=? ex "") "" ":") ex)))

(define log-path (build-path cat-dir "hotfix-setup.log"))
(define exit-code
  (parameterize ([current-environment-variables
                  (let ([env (environment-variables-copy (current-environment-variables))])
                    (environment-variables-set! env #"PLTADDONDIR"
                                               (string->bytes/utf-8 (->str install)))
                    (environment-variables-set! env (string->bytes/utf-8 lib-var)
                                               (string->bytes/utf-8 lib-val))
                    env)])
    (call-with-output-file log-path #:exists 'replace
      (lambda (log-port)
        (define-values (sp _out i _err)
          (subprocess log-port #f 'stdout
                      (->path racket)
                      "-G"   (->str xcfg)
                      "-MCR" (format "~a:~a" (->str hostzo) (->str xtgt))
                      "--cross-compiler" TARGET (->str cc-dir)
                      "-l-"  "raco" "setup"
                      "--no-docs" "--no-launcher" "--no-foreign-libs" "--no-pkg-deps"
                      "--pkgs" "gui-lib"))
        (close-output-port i)
        (subprocess-wait sp)
        (subprocess-status sp)))))

(display (file->string log-path))
(define log-text (file->string log-path))
(cond
  [(zero? exit-code) (printf "\nhotfix: raco setup succeeded\n")]
  [(regexp-match? #rx"packages installed, although setup reported errors" log-text)
   (printf "\nhotfix: raco setup: non-fatal launcher errors; ok\n")]
  [else (error 'hotfix "raco setup failed (exit ~a) -- see ~a" exit-code log-path)])

;; ---- 3. Harvest the new .zo from xtgt ------------------------------------
(unless (file-exists? xtgt-zo)
  (error 'hotfix "new .zo not found at:\n  ~a" xtgt-zo))
(make-directory* (path-only guilib-zo))
(copy-file xtgt-zo guilib-zo #t)
(printf "hotfix: harvested new queue_rkt.zo (~a bytes)\n" (file-size guilib-zo))

;; ---- 4. Inject the new .zo into share.data --------------------------------
;; We append the new .zo bytes to share.data and patch the manifest in
;; share.data.js in-place (update just the one entry + size + uuid), without
;; regenerating the whole loader JS.

(define VPATH "/share/pkgs/gui-lib/mred/private/wx/wasm/compiled/queue_rkt.zo")

(define (patch-share-data! data-path data-js-path)
  (cond
    [(not (and (file-exists? data-path) (file-exists? data-js-path)))
     (printf "hotfix: skipping ~a (not found)\n" data-path)]
    [else
     ;; Parse manifest.
     (define js-text (file->string data-js-path))
     (define m (regexp-match #px"loadPackage\\((\\{.*\\})\\);\\s*\\}\\)\\(\\);" js-text))
     (unless m (error 'hotfix "cannot parse manifest from ~a" data-js-path))
     (define manifest (string->jsexpr (cadr m)))
     (define old-files (hash-ref manifest 'files))

     ;; Drop the existing VPATH entry; its old bytes become dead space (harmless).
     (define kept
       (filter (lambda (e) (not (equal? (hash-ref e 'filename) VPATH))) old-files))

     ;; Append the new .zo bytes to share.data.
     (define new-zo-bytes (file->bytes guilib-zo))
     (define new-start    (file-size data-path))
     (define new-end      (+ new-start (bytes-length new-zo-bytes)))
     (call-with-output-file data-path #:exists 'append
       (lambda (o) (write-bytes new-zo-bytes o)))

     (define new-files
       (append kept (list (hasheq 'filename VPATH 'start new-start 'end new-end))))
     (define new-size (file-size data-path))
     (define new-uuid (string-append "sha1-" (call-with-input-file data-path sha1)))

     ;; Patch manifest inline: replace the one loadPackage({...}); call.
     (define new-manifest
       (jsexpr->string
        (hash-set* manifest
                   'files new-files
                   'remote_package_size new-size
                   'package_uuid new-uuid)))
     (define new-js
       (regexp-replace
        #px"loadPackage\\(\\{.*\\}\\);"
        js-text
        (string-append "loadPackage(" new-manifest ");")))
     (call-with-output-file data-js-path #:exists 'replace
       (lambda (o) (write-string new-js o)))

     (printf "hotfix: patched ~a (+1 file, ~a total entries, ~a bytes)\n"
             (file-name-from-path data-path) (length new-files) new-size)]))

(for ([tdir (in-list (list dist (build-path WORK "app-payload-cache" APP-KEY)))])
  (patch-share-data! (build-path tdir "share.data")
                     (build-path tdir "share.data.js")))

(printf "\nhotfix: done. Serve apps/drracket/dist/ and test clicking and typing.\n")
