#lang racket/base
;; Consuming the cross-compiler SDK: cross-compile a NEW raco package for the
;; `tpb32l` target using the SDK's retarget files -- a normal host Racket, NO
;; emsdk and NO upstream clone -- then fold its `tpb32l` `.zo` into an existing
;; runtime's `share.data` package payload. See build-wasm.md "Consuming the
;; cross-compiler SDK" and the memory note [[cross-sdk-consume]].
;;
;; The mechanism (proven host-safe):
;;   <host-racket> -G <xcfg/etc> -MCR <hostzo>:<xtgt> \
;;     --cross-compiler tpb32l <sdk>/cross-compiler -l- raco make <pkg>/<m>.rkt
;; `-MCR` engages cross-multi mode (-C cross-installation, -M machine-independent,
;; two compiled roots). With BOTH roots explicit (no in-place `:` root) the host
;; form lands in <hostzo> and the tpb32l form in <xtgt> -- nothing is written in
;; place, so the host racket's OWN collects are never overwritten (the hazard
;; that bricked the host racket once already; see the memory note). `system.rktd`
;; (shipped at <sdk>/cross-root/lib) tells the running racket the target is
;; tpb32l; without it the cross-compile silently emits HOST bytecode.
(require racket/file
         racket/path
         racket/string
         racket/list
         racket/port
         setup/getinfo
         "config.rkt"
         "util.rkt"
         "toolchain.rkt"
         "metadata.rkt"
         "pack.rkt")

(provide cross-install)

(define (->path p) (if (path? p) p (string->path p)))
(define (real p) (simplify-path (path->complete-path (->path p))))

;; The collection link entry for a staged package. A single-collection package
;; (info.rkt `(define collection "name")`) gets a named link; anything else is a
;; collection-root link. Mirrors how `links.rktd` already lists the bundled pkgs
;; (e.g. `("datalog" (#"pkgs" #"datalog"))` vs `(root (#"pkgs" #"draw-lib"))`).
(define (pkg-link-entry pkg-src pkgname)
  (define info (get-info/full (real pkg-src)))
  (define coll (and info (info 'collection (lambda () #f))))
  (define target (list #"pkgs" (string->bytes/utf-8 pkgname)))
  (if (string? coll) (list coll target) (list 'root target)))

;; The .rkt modules of a staged package worth cross-compiling: everything under
;; the package tree EXCEPT docs/tests (scribblings need `scribble` on the host
;; and aren't needed at runtime) and `info.rkt` (declarative, no runtime use).
(define (compilable-modules stage-pkg-dir)
  (for/list ([p (in-directory stage-pkg-dir)]
             #:when (and (file-exists? p)
                         (regexp-match? #rx"\\.rkt$" (path->string p))
                         (not (regexp-match? #rx"(^|/)info\\.rkt$" (path->string p)))
                         (not (regexp-match? #rx"/(scribblings|tests|doc)/" (path->string p)))))
    (path->string p)))

;; Harvest the tpb32l `.zo`/`.dep` the cross-make wrote into `xtgt` (which mirrors
;; absolute source paths) back to their real locations -- but ONLY those under
;; `scope` (the staging tree). This is load-bearing: `xtgt` also holds the target
;; form of any HOST-collects dependency the build recompiled; copying those back
;; would overwrite the host racket's bytecode with tpb32l. Returns the count.
(define (harvest! xtgt scope)
  (define scope-str (string-append (path->string scope) "/"))
  (for/sum ([p (in-directory xtgt)]
            #:when (and (file-exists? p)
                        (regexp-match? #rx"\\.(zo|dep)$" (path->string p))))
    (define dest (build-path "/" (find-relative-path (real xtgt) (real p))))
    (cond
      [(string-prefix? (path->string dest) scope-str)
       (make-directory* (path-only dest))
       (copy-file p dest #t)
       1]
      [else 0])))

;; Cross-compile each package in `pkg-srcs` for tpb32l using the SDK at `sdk-dir`,
;; then extend the runtime `share.data` at `existing-data` with the new packages'
;; bytecode + sources + an updated `/share/links.rktd`, writing the new
;; `share.data`/`share.data.js` pair into `dest`. `racket` is an explicit host
;; Racket path (else resolved); it MUST match the SDK's recorded racket-version.
(define (cross-install #:sdk sdk-dir
                       #:share-data existing-data
                       #:pkgs pkg-srcs
                       #:dest dest
                       #:racket [racket-opt #f]
                       #:work [work-opt #f])
  (define sdk (real sdk-dir))
  (define data (real existing-data))
  (define data-js (->path (string-append (path->string data) ".js")))
  (unless (file-exists? data) (error 'cross-install "no share.data at ~a" data))
  (unless (file-exists? data-js) (error 'cross-install "no share.data.js at ~a" data-js))
  ;; --- validate the SDK + host racket compatibility -----------------------
  (define meta (read-build-metadata sdk))
  (unless (and meta (eq? (hash-ref meta 'kind #f) 'cross-sdk))
    (error 'cross-install "~a is not a cross-compiler SDK (no `kind: cross-sdk` metadata)" sdk))
  (define cc-dir (build-path sdk "cross-compiler"))
  (define sys-rktd (build-path sdk "cross-root" "lib" "system.rktd"))
  (for ([f (in-list (list cc-dir sys-rktd))])
    (unless (or (directory-exists? f) (file-exists? f))
      (error 'cross-install "SDK at ~a is missing ~a" sdk f)))
  (define racket (resolve-host-racket racket-opt))
  (let ([gate (racket-version-gate-report (hash-ref meta 'racket-version #f)
                                          (host-racket-version racket))])
    (when gate
      (error 'cross-install "host racket is incompatible with this SDK:\n~a" gate)))
  ;; --- scratch layout -----------------------------------------------------
  (define work (if work-opt (real work-opt) (make-temporary-file "rktwasm-consume-~a" 'directory)))
  (define stage  (build-path work "stage"))           ; stage/share/pkgs/<pkg>/...
  (define hostzo (build-path work "hostzo"))           ; host-form shadow (reusable)
  (define xtgt   (build-path work "xtgt"))             ; tpb32l target root
  (define xcfg   (build-path work "xcfg"))             ; minimal cross config
  (for ([d (list stage hostzo xtgt (build-path xcfg "etc") (build-path xcfg "lib"))])
    (make-directory* d))
  (copy-file sys-rktd (build-path xcfg "lib" "system.rktd") #t)
  ;; --- stage each package + collect its link entry ------------------------
  (define links-additions '())
  (define staged '())  ; (pkgname . stage-pkg-dir)
  (for ([src (in-list pkg-srcs)])
    (define src* (real src))
    (unless (directory-exists? src*) (error 'cross-install "package source not a dir: ~a" src*))
    (define-values (_ name __) (split-path src*))
    (define pkgname (path->string name))
    (define stage-pkg (build-path stage "share" "pkgs" pkgname))
    (make-directory* (path-only stage-pkg))
    (copy-directory/files src* stage-pkg)
    (set! staged (cons (cons pkgname stage-pkg) staged))
    (set! links-additions (cons (pkg-link-entry src* pkgname) links-additions)))
  ;; A links file naming ONLY the new package(s), so a package that requires its
  ;; OWN collection resolves during the cross-make -- without activating the
  ;; cross-root's tpb32l links (which would crash the host on load).
  (define stage-links (build-path xcfg "links.rktd"))
  (call-with-output-file stage-links #:exists 'replace
    (lambda (o) (writeln links-additions o)))
  (call-with-output-file (build-path xcfg "etc" "config.rktd") #:exists 'replace
    (lambda (o)
      (write (hash 'lib-dir (path->string (build-path xcfg "lib"))
                   'lib-search-dirs (list (path->string (build-path xcfg "lib")))
                   'links-search-files (list (path->string stage-links)))
             o)))
  ;; --- cross-compile (host-safe: target -> xtgt, host -> hostzo) ----------
  (define modules (append-map (lambda (sp) (compilable-modules (cdr sp))) staged))
  (when (null? modules) (error 'cross-install "no compilable .rkt modules found in the package(s)"))
  (info-msg "cross-compiling ~a module(s) for ~a (host racket ~a, no emsdk)"
            (length modules) target-machine racket)
  (run racket
       #:args (append (list "-G" (path->string (build-path xcfg "etc"))
                            "-MCR" (format "~a:~a" (path->string hostzo) (path->string xtgt))
                            "--cross-compiler" target-machine (path->string cc-dir)
                            "-l-" "raco" "make")
                      modules))
  (define harvested (harvest! xtgt stage))
  (info-msg "harvested ~a tpb32l artifact(s) into the staging tree" harvested)
  ;; --- merge collection links + extend share.data -------------------------
  (define old-links
    (let ([b (data-package-file-bytes #:data data #:js data-js "/share/links.rktd")])
      (if b (with-input-from-bytes b read) '())))
  (define merged-links
    (append links-additions
            (filter (lambda (e) (not (member e links-additions))) old-links)))
  (define links-tmp (build-path work "links.rktd"))
  (call-with-output-file links-tmp #:exists 'replace (lambda (o) (writeln merged-links o)))
  (define add-files
    (cons
     (cons "/share/links.rktd" links-tmp)
     (for*/list ([sp (in-list staged)]
                 [p (in-directory (cdr sp))]
                 #:when (file-exists? p))
       (define rel (find-relative-path (real stage) (real p)))
       (cons (string-append "/" (string-join (map path->string (explode-path rel)) "/")) p))))
  (make-directory* (->path dest))
  (extend-data-package! #:data data #:js data-js #:add add-files
                        #:dest (->path dest) #:name "share.data")
  (info-msg "cross-installed ~a package(s) -> ~a/share.data{,.js}"
            (length staged) dest)
  (unless work-opt (delete-directory/files work)))
