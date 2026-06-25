#lang racket/base
;; Consuming the cross-compiler SDK: fetch + cross-compile NEW raco packages for
;; the `tpb32l` target using the SDK's retarget files -- a normal host Racket, NO
;; emsdk and NO upstream clone -- then fold their `tpb32l` `.zo` into an existing
;; runtime's `share.data` package payload. Packages come from a catalog (by name)
;; and/or from local source dirs; their dependency closure already present in the
;; SDK's base cross-root is recognized as installed and NOT re-fetched, so only the
;; delta installs. See build-wasm.md "Consuming the cross-compiler SDK" and the
;; memory note [[cross-sdk-consume]].
;;
;; The mechanism (proven host-safe):
;;   PLTADDONDIR=<addon> <host-racket> -G <xcfg/etc> -MCR <hostzo>:<xtgt> \
;;     --cross-compiler tpb32l <sdk>/cross-compiler \
;;     -l- raco pkg install --scope user --deps search-auto <names...>
;; `-MCR` engages cross-multi mode (-C cross-installation, -M machine-independent,
;; two compiled roots). With BOTH roots explicit (no in-place `:` root) the host
;; form lands in <hostzo> and the tpb32l form in <xtgt> -- nothing is written in
;; place, so the host racket's OWN collects are never overwritten (the hazard that
;; bricked the host racket once already; see the memory note). `--scope user` +
;; `PLTADDONDIR` confines the new packages to a throwaway addon dir, never the
;; host scopes.
;;
;; The custom `-G` config is the crux: it points `pkgs-dir`/`links-file`/`lib-dir`
;; at the SDK cross-root (so the base package set is seen as ALREADY INSTALLED --
;; only the app's delta is fetched + compiled) while leaving `collects` on the host
;; racket (host-form expansion). `lib-dir`'s `system.rktd` carries `target-machine
;; tpb32l`; without it the cross-compile silently emits HOST bytecode.
(require racket/file
         racket/path
         racket/string
         racket/list
         racket/port
         racket/runtime-path
         setup/getinfo
         "config.rkt"
         "util.rkt"
         "toolchain.rkt"
         "metadata.rkt"
         "pack.rkt")

(provide cross-install)

;; The subprocess strip helper (run under the host racket + cross flags so
;; `binary-lib`'s `fixup-zo` can read tpb32l `.zo`). See build/strip-catalog.rkt.
(define-runtime-path strip-catalog-helper "strip-catalog.rkt")

;; Strip mode for the built-package catalog (pkg/strip's `generate-stripped-
;; directory`). `'binary-lib` is the lean ship: drops source/docs (`.zo`-only) and
;; prunes `build-deps`. `'built` keeps source + `.zo` (same payload size) and never
;; reads a `.zo` -- a host-safe way to validate the pipeline. Either way the strip
;; runs in the cross subprocess (build/strip-catalog.rkt), so `binary-lib`'s
;; `fixup-zo`/`info` `.zo` reads decode tpb32l via the cross xpatch. See
;; build-wasm.md "Binary-only packages via the catalog".
(define STRIP-MODE 'binary-lib)

(define (->path p) (if (path? p) p (string->path p)))
(define (real p) (simplify-path (path->complete-path (->path p))))

;; Repo-side package source patches. `package-patches/<pkg>/*.patch` carries
;; small fixes applied to a CATALOG package's source during the staging compile
;; (e.g. draw-lib's cairo_font_options_copy mis-binding, a genuine upstream bug
;; that wasm's typed call_indirect surfaces -- see build-wasm.md "Text / Pango").
;; The patch internal paths are package-rooted (`<pkg>/...`), applied with `-p1`
;; from the addon pkgs dir. Their content feeds the build key (build/cache.rkt
;; delta-hash), so editing one yields a fresh SDK/catalog and a clean re-stage.
;; `package-patches-dir` is defined in config.rkt (folded into the delta-hash).

;; assoc list (pkg-name . (listof absolute-patch-path)), sorted, for the staged
;; packages that have a `package-patches/<name>/` dir. `present` is the set of
;; package names actually staged (so we don't try to patch an absent dir).
(define (discover-pkg-patches present)
  (cond
    [(not (directory-exists? package-patches-dir)) '()]
    [else
     (for*/list ([d (in-list (directory-list package-patches-dir))]
                 [name (in-value (path->string d))]
                 #:when (and (directory-exists? (build-path package-patches-dir d))
                             (member name present))
                 [patches (in-value
                           (sort (for/list ([p (in-list (directory-list
                                                         (build-path package-patches-dir d)))]
                                            #:when (regexp-match? #rx"\\.patch$" (path->string p)))
                                   (real (build-path package-patches-dir d p)))
                                 string<? #:key path->string))]
                 #:when (pair? patches))
       (cons name patches))]))

;; Run `patch` capturing merged stdout+stderr; returns (values exit-code output).
;; `patch` (unlike `git apply`) is NOT git-repo-aware -- it applies relative to
;; `dir` with `-p1`. This matters because the staged tree lives UNDER the
;; racket-wasm repo, where `git apply` resolves paths against the repo toplevel
;; and silently no-ops on the (gitignored) staging dir.
(define (run-patch dir args)
  (define o (open-output-string))
  (parameterize ([current-directory dir])
    (define-values (sp out in err)
      (apply subprocess #f #f 'stdout (find-executable-path "patch") args))
    (close-output-port in)
    (define pump (thread (lambda () (copy-port out o))))
    (subprocess-wait sp)
    (thread-wait pump)
    (values (subprocess-status sp) (get-output-string o))))

;; Apply each package's patches to its staged source under `ap` (the addon pkgs
;; dir), idempotently. The reliable probe is a FORWARD dry-run: exit 0 => the
;; patch isn't yet in place, so apply it; nonzero => `patch` either detected a
;; "previously applied" patch (skip) or a real conflict (error -- the patch has
;; drifted from this package version). (BSD `patch -R --dry-run` succeeds on BOTH
;; patched and unpatched, so it can't be used to detect already-applied.) Returns
;; the names that had at least one patch NEWLY applied (caller recompiles those).
(define (apply-pkg-patches! ap pkg-patches)
  (filter
   values
   (for/list ([entry (in-list pkg-patches)]
              #:when (let ([pkgdir (build-path ap (car entry))])
                       (or (directory-exists? pkgdir)
                           (begin (info-msg "pkg-patch: ~a not staged; skipping" (car entry)) #f))))
     (define name (car entry))
     (define changed?
       (for/fold ([changed? #f]) ([patch (in-list (cdr entry))])
         (define pstr (path->string patch))
         (define base (list "--batch" "-p1" "--forward" "-i" pstr))
         (define-values (dry-code dry-out) (run-patch ap (cons "--dry-run" base)))
         (cond
           [(zero? dry-code)
            (info-msg "pkg-patch: applying ~a to ~a" (file-name-from-path patch) name)
            (define-values (code _out) (run-patch ap base))
            (unless (zero? code)
              (error 'apply-pkg-patches! "patch ~a failed to apply to ~a (exit ~a)" pstr name code))
            #t]
           [(regexp-match? #rx"(?i:previously applied|reversed)" dry-out)
            (info-msg "pkg-patch: ~a already applied to ~a; skipping" (file-name-from-path patch) name)
            changed?]
           [else
            (error 'apply-pkg-patches!
                   "patch ~a does not apply to ~a (drifted from the package version?):\n~a"
                   pstr name dry-out)])))
     (and changed? name))))

;; Compile the named packages' collections to tpb32l, reusing the host-safe cross
;; discipline (`-MCR hostzo:xtgt`, `-G` cross config, PLTADDONDIR addon). Called
;; with ALL staged package names so a single setup compiles the whole closure in
;; dependency order against the (already patched) source -- dependents thus see
;; the patched code, which a per-package `--pkgs <patched-only>` setup would miss.
;; `--pkgs <names>` keeps setup scoped to the addon packages (never the base/host
;; collects). The compilation manager only (re)builds files whose source is newer
;; than their `.zo`, so warm runs are no-ops. Post-install packaging phases that
;; need host launcher templates absent from the cross lib-dir (--no-launcher) or
;; doc/foreign-lib steps are skipped so setup exits cleanly while emitting `.zo`.
(define (setup-pkgs! #:racket racket #:cc-dir cc-dir #:config-etc config-etc
                     #:hostzo hostzo #:xtgt xtgt #:addon addon #:names names)
  (info-msg "compiling package(s) for ~a: ~a" target-machine (string-join names ", "))
  (define-values (lib-var lib-val) (racket-native-lib-path racket))
  (run (if (path? racket) (path->string racket) racket)
       #:env (list (cons "PLTADDONDIR" (path->string addon))
                   (cons lib-var lib-val))
       #:args (append
               (list "-G" (path->string config-etc)
                     "-MCR" (format "~a:~a" (path->string hostzo) (path->string xtgt))
                     "--cross-compiler" target-machine (path->string cc-dir)
                     "-l-" "raco" "setup"
                     "--no-docs" "--no-launcher" "--no-foreign-libs" "--no-pkg-deps" "--no-install" "--no-post-install"
                     "--pkgs")
               names)))

;; The collection link entry for an installed package dir. A single-collection
;; package (info.rkt `(define collection "name")`) gets a named link; anything
;; else is a collection-root link. Mirrors how `links.rktd` already lists the
;; bundled pkgs (e.g. `("datalog" (#"pkgs" #"datalog"))` vs `(root (#"pkgs"
;; #"draw-lib"))`).
(define (pkg-link-entry pkg-dir pkgname)
  (define info (get-info/full (real pkg-dir)))
  (define coll (and info (info 'collection (lambda () #f))))
  (define target (list #"pkgs" (string->bytes/utf-8 pkgname)))
  (if (string? coll) (list coll target) (list 'root target)))

;; Harvest the tpb32l `.zo`/`.dep` the cross-install wrote into `xtgt` (which
;; mirrors absolute source paths) back to their real locations -- but ONLY those
;; under `scope` (the addon package tree). This is load-bearing: `xtgt` also holds
;; the target form of any HOST-collects module the build recompiled (the new
;; package's dependency closure); copying those back would overwrite the host
;; racket's bytecode with tpb32l. Returns the count.
;;
;; `info_rkt.zo`/`.dep` are deliberately SKIPPED: `get-info/full` (called by
;; `pkg-link-entry`, the strip, and `create-dirs-catalog`) would LOAD an in-place
;; `compiled/info_rkt.zo`, and a tpb32l (or wrong-version) one traps the host
;; orchestrator (`fasl-read: incompatible ... machine-type 'tpb32l`). With it
;; absent, `get-info` falls back to the always-present SOURCE `info.rkt` --
;; host-safe under any orchestrator version. `info.rkt` is setup/pkg metadata, not
;; loaded at program runtime, so the payload doesn't need its `.zo` (the final
;; cross `raco setup` regenerates it for tpb32l if anything wants it).
(define (harvest! xtgt scope)
  (define scope-str (string-append (path->string scope) "/"))
  (for/sum ([p (in-directory xtgt)]
            #:when (and (file-exists? p)
                        (regexp-match? #rx"\\.(zo|dep)$" (path->string p))
                        (not (regexp-match? #rx"/info_rkt\\.(zo|dep)$" (path->string p)))))
    (define dest (build-path "/" (find-relative-path (real xtgt) (real p))))
    (cond
      [(string-prefix? (path->string dest) scope-str)
       (make-directory* (path-only dest))
       (copy-file p dest #t)
       1]
      [else 0])))

;; The `<addon>/<version>/pkgs` dir the install populated (the version segment is
;; raco's installation name; resolve it instead of hard-coding the racket version).
(define (addon-pkgs-dir addon)
  (define cands
    (for/list ([d (in-list (if (directory-exists? addon) (directory-list addon) '()))]
               #:when (directory-exists? (build-path addon d "pkgs")))
      (build-path addon d "pkgs")))
  (cond
    [(null? cands) #f]
    [else (car cands)]))

;; Write the base-as-installed cross config into `etc-dir`/config.rktd: the SDK
;; cross-root is seen as ALREADY INSTALLED (pkgs-dir/links-file) and the cross
;; target is tpb32l (lib-dir's system.rktd), while `collects` stays on the host
;; racket (host-form expansion). `catalogs` chooses where NEW packages are fetched
;; from: `(list #f)` is the default network catalog (the staging pass); `(list
;; <local> #f)` prefers a local built-package catalog then the network (the final
;; consume pass).
(define (write-xconfig! etc-dir #:pkgs-dir pkgs-dir #:links links #:lib lib #:catalogs catalogs)
  (make-directory* etc-dir)
  (call-with-output-file (build-path etc-dir "config.rktd") #:exists 'replace
    (lambda (o)
      (write (hash 'pkgs-dir   (path->string pkgs-dir)
                   'links-file (path->string links)
                   'lib-dir    (path->string lib)
                   'catalogs   catalogs)
             o))))

;; Prepend the host racket's `lib/` directory to DYLD_LIBRARY_PATH (macOS) /
;; LD_LIBRARY_PATH (Linux) so that `dlopen("libpng16.16.dylib")` (and friends)
;; succeeds when draw-lib/cairo-lib.rkt is compiled in a cross-setup subprocess.
;; These libs live next to the racket binary (../lib relative to bin/racket) and
;; are NOT in the dyld default search path, so without this `ffi-lib` fails on a
;; cold catalog build where --skip-installed doesn't bypass compilation.
(define (racket-native-lib-path racket)
  (define lib-dir (simplify-path (build-path (path-only (->path racket)) 'up "lib")))
  (define var (if (eq? (system-type 'os) 'macosx) "DYLD_LIBRARY_PATH" "LD_LIBRARY_PATH"))
  (define existing (or (getenv var) ""))
  (define sep (if (string=? existing "") "" ":"))
  (values var (string-append (path->string lib-dir) sep existing)))

;; Run `raco pkg install` host-safely (`-MCR hostzo:xtgt` -> target form to
;; `xtgt`, host form to `hostzo`, nothing in place; new pkgs confined to the
;; `addon` user scope via PLTADDONDIR), capturing merged output to a logfile under
;; `work` and teeing it. `raco setup`'s launcher step needs host launcher
;; templates (`starter-sh`) absent from the cross `lib-dir`, so it exits non-zero
;; with a benign "packages installed, although setup reported errors" AFTER the
;; packages are fetched + compiled -- tolerate ONLY that signature; any other
;; failure raises. Shared by the staging install and the final consume.
(define (run-install #:racket racket #:cc-dir cc-dir #:config-etc config-etc
                     #:hostzo hostzo #:xtgt xtgt #:addon addon #:work work
                     #:src-args src-args #:what what #:no-setup? [no-setup? #f])
  (info-msg "cross-installing ~a for ~a (host racket ~a, no emsdk)" what target-machine racket)
  (define args
    (append (list "-G" (path->string config-etc)
                  "-MCR" (format "~a:~a" (path->string hostzo) (path->string xtgt))
                  "--cross-compiler" target-machine (path->string cc-dir)
                  "-l-" "raco" "pkg" "install"
                  ;; `--force` waives "conflicts with existing installed item":
                  ;; for a user-scope install raco scans ALL available scopes for
                  ;; additional-installs (man pages, launchers, foreign libs), so a
                  ;; FULL host distribution shadows the cross-installed closure (e.g.
                  ;; its gui-lib already owns gracket.1). We install into a disposable
                  ;; addon and only harvest .zo, so those collisions are irrelevant.
                  ;; `--force` ignores conflicts ONLY; `--deps search-auto` still
                  ;; resolves the closure (that's the separate `--deps` knob).
                  "--scope" "user" "--batch" "--no-docs" "--force" "--deps" "search-auto")
            ;; `--no-setup` fetches + registers (resolving the dep closure) but
            ;; skips compilation, so a caller can patch the staged source BEFORE
            ;; anything is compiled (see refresh-pkg-catalog!). The benign-error
            ;; tolerance below keys on the `raco setup` launcher message, which
            ;; doesn't run under --no-setup, so the install just exits 0.
            (if no-setup? '("--no-setup") '())
            src-args))
  (define logf (build-path work "install.log"))
  (define-values (lib-var lib-val) (racket-native-lib-path racket))
  (define code
    (parameterize ([current-environment-variables
                    (let ([e (environment-variables-copy (current-environment-variables))])
                      (environment-variables-set! e #"PLTADDONDIR"
                                                  (string->bytes/utf-8 (path->string addon)))
                      (environment-variables-set! e (string->bytes/utf-8 lib-var)
                                                  (string->bytes/utf-8 lib-val))
                      e)])
      (call-with-output-file logf #:exists 'replace
        (lambda (port)
          (define-values (sp _o in _e)
            (apply subprocess port #f 'stdout (->path racket) args))
          (close-output-port in)
          (subprocess-wait sp)
          (subprocess-status sp)))))
  (define out (file->string logf))
  (display out)
  (cond
    [(zero? code) (void)]
    [(regexp-match? #rx"packages installed, although setup reported errors" out)
     (info-msg "note: raco setup reported non-fatal errors (host launcher templates absent in the cross lib-dir); packages installed + cross-compiled")]
    [else
     (error 'cross-install "raco pkg install failed (exit ~a) for ~a -- see output above" code what)]))

;; Strip each staged (in-place tpb32l-compiled) package under `staged` into
;; `cat-pkgs` and (re)build the dirs-catalog index at `cat-index`, by running the
;; strip helper as a host-racket subprocess WITH the cross flags (so `binary-lib`'s
;; `fixup-zo` can read tpb32l `.zo` -- see build/strip-catalog.rkt). A package is
;; stripped once and reused; a STRIP-MODE change (recorded in `.strip-mode`)
;; rebuilds the catalog package dirs + index.
(define (strip-into-catalog! #:racket racket #:cc-dir cc-dir #:config-etc config-etc
                             #:hostzo hostzo #:xtgt xtgt
                             #:staged staged #:cat-pkgs cat-pkgs #:cat-index cat-index)
  (define build-catalog (path-only cat-pkgs))
  (define mode-file (build-path build-catalog ".strip-mode"))
  (define mode-str (symbol->string STRIP-MODE))
  (define prev (and (file-exists? mode-file) (string-trim (file->string mode-file))))
  (when (and prev (not (equal? prev mode-str)))
    (info-msg "strip mode changed ~a -> ~a; rebuilding catalog package dirs" prev mode-str)
    (when (directory-exists? cat-pkgs) (delete-directory/files cat-pkgs))
    (when (directory-exists? cat-index) (delete-directory/files cat-index)))
  (make-directory* cat-pkgs)
  (make-directory* cat-index)
  (run (if (path? racket) (path->string racket) racket)
       #:args (list "-G" (path->string config-etc)
                    "-MCR" (format "~a:~a" (path->string hostzo) (path->string xtgt))
                    "--cross-compiler" target-machine (path->string cc-dir)
                    (path->string strip-catalog-helper)
                    (path->string staged) (path->string cat-pkgs)
                    mode-str (path->string cat-index)))
  (call-with-output-file mode-file #:exists 'replace (lambda (o) (display mode-str o))))

;; (Steps 1-4) Build/refresh the persistent, SDK-keyed built-package catalog at
;; `catalog-dir` for the catalog packages `pkg-names`: stage-install them (+ their
;; non-base dependency closure) for tpb32l from the network, harvest the `.zo` in
;; place, strip each into `build-catalog/pkgs`, and (re)build the dirs-catalog
;; index. The staging tree + compile shadows persist across runs (`--skip-installed`
;; -> incremental) so the catalog ACCUMULATES. Returns a `file://` catalog URL, or
;; #f when there are no catalog packages. `cross-*` are the SDK cross-root dirs.
(define (refresh-pkg-catalog! #:catalog-dir catalog-dir #:racket racket #:cc-dir cc-dir
                              #:cross-pkgs cross-pkgs #:cross-links cross-links
                              #:cross-lib cross-lib #:pkg-names pkg-names)
  (cond
    [(null? pkg-names) #f]
    [else
     (define install-root (build-path catalog-dir "install"))  ; PLTADDONDIR (user scope)
     (define hostzo (build-path catalog-dir "hostzo"))
     (define xtgt   (build-path catalog-dir "xtgt"))
     (define xcfg   (build-path catalog-dir "xcfg" "etc"))
     (define build-catalog (build-path catalog-dir "build-catalog"))
     (define cat-pkgs  (build-path build-catalog "pkgs"))
     (define cat-index (build-path build-catalog "catalog"))
     (for ([d (list install-root hostzo xtgt cat-pkgs cat-index)]) (make-directory* d))
     (write-xconfig! xcfg #:pkgs-dir cross-pkgs #:links cross-links #:lib cross-lib
                     #:catalogs (list #f))
     ;; Fetch the requested packages + their closure for tpb32l WITHOUT compiling
     ;; (`--no-setup`), so repo-side source patches land BEFORE anything is built.
     ;; `--skip-installed` keeps it incremental (only new packages fetched).
     (run-install #:racket racket #:cc-dir cc-dir #:config-etc xcfg
                  #:hostzo hostzo #:xtgt xtgt #:addon install-root #:work catalog-dir
                  #:src-args (cons "--skip-installed" pkg-names) #:no-setup? #t
                  #:what (format "~a catalog package(s) [fetch]" (length pkg-names)))
     (define ap (addon-pkgs-dir install-root))
     (unless ap (error 'refresh-pkg-catalog! "no packages staged under ~a" install-root))
     ;; Apply any repo-side source patches to the staged source, then compile the
     ;; WHOLE staged closure in one dependency-ordered setup -- so the catalog
     ;; archives PATCHED tpb32l `.zo` and every dependent is built against the
     ;; patched source (not just the patched packages themselves). Must happen
     ;; before the harvest/strip (which captures the compiled tree). See
     ;; `discover-pkg-patches` / build-wasm.md "Text / Pango".
     (define staged (for/list ([p (in-list (directory-list ap))]
                               #:when (directory-exists? (build-path ap p)))
                      (path->string p)))
     (apply-pkg-patches! ap (discover-pkg-patches staged))
     (setup-pkgs! #:racket racket #:cc-dir cc-dir #:config-etc xcfg
                  #:hostzo hostzo #:xtgt xtgt #:addon install-root #:names staged)
     (define harvested (harvest! xtgt ap))
     (info-msg "staged ~a tpb32l artifact(s); stripping into the catalog (~a)" harvested STRIP-MODE)
     (strip-into-catalog! #:racket racket #:cc-dir cc-dir #:config-etc xcfg
                          #:hostzo hostzo #:xtgt xtgt
                          #:staged ap #:cat-pkgs cat-pkgs #:cat-index cat-index)
     (string-append "file://" (path->string (real cat-index)))]))

;; Fetch + cross-compile the app's packages for tpb32l and fold their tpb32l `.zo`
;; into the runtime `share.data`, emsdk-free. Two passes: (1) `refresh-pkg-catalog!`
;; builds/extends the SDK-keyed built-package catalog at `catalog-dir` for the
;; catalog packages `pkg-names`; (2) a final consume installs `pkg-names` FROM that
;; catalog (selecting just this app's closure) plus the local package dirs
;; `local-pkgs` by `--copy` (locals stay source), harvests the tpb32l delta, and
;; extends `existing-data`'s bytecode + `/share/links.rktd` into `dest`/
;; share.data{,.js}. `racket` is an explicit host Racket (else resolved) and MUST
;; match the SDK's recorded racket-version. `work` is the final-pass scratch (kept
;; if supplied, to reuse the hostzo/xtgt compile shadows). `catalog-dir` is the
;; persistent catalog (defaults under `work`). See build/stages.rkt.
(define (cross-install #:sdk sdk-dir
                       #:share-data existing-data
                       #:dest dest
                       #:pkgs [pkg-names '()]
                       #:local-pkgs [local-pkgs '()]
                       #:racket [racket-opt #f]
                       #:work [work-opt #f]
                       #:catalog-dir [catalog-dir-opt #f])
  (when (and (null? pkg-names) (null? local-pkgs))
    (error 'cross-install "nothing to install (need #:pkgs and/or #:local-pkgs)"))
  (define sdk (real sdk-dir))
  (define data (real existing-data))
  (define data-js (->path (string-append (path->string data) ".js")))
  (unless (file-exists? data) (error 'cross-install "no share.data at ~a" data))
  (unless (file-exists? data-js) (error 'cross-install "no share.data.js at ~a" data-js))
  ;; --- validate the SDK + host racket compatibility -----------------------
  (define meta (read-build-metadata sdk))
  (unless (and meta (eq? (hash-ref meta 'kind #f) 'cross-sdk))
    (error 'cross-install "~a is not a cross-compiler SDK (no `kind: cross-sdk` metadata)" sdk))
  (define cc-dir     (build-path sdk "cross-compiler"))
  (define cross-root (build-path sdk "cross-root"))
  (define cross-pkgs (build-path cross-root "share" "pkgs"))
  (define cross-links (build-path cross-root "share" "links.rktd"))
  (define cross-lib  (build-path cross-root "lib"))
  (define sys-rktd   (build-path cross-lib "system.rktd"))
  ;; The base in-tree pkgs the cross-root's links reference as `(up up #"pkgs" X)`
  ;; -- resolved relative to <cross-root>/share, i.e. at <sdk>/pkgs (shipped by
  ;; cross-sdk-layout). Required so the base packages register as installed.
  (define intree-pkgs (build-path sdk "pkgs"))
  (for ([f (in-list (list cc-dir cross-pkgs cross-links sys-rktd intree-pkgs))])
    (unless (or (directory-exists? f) (file-exists? f))
      (error 'cross-install "SDK at ~a is missing ~a" sdk f)))
  (define racket (resolve-host-racket racket-opt))
  (let ([gate (racket-version-gate-report (hash-ref meta 'racket-version #f)
                                          (host-racket-version racket))])
    (when gate
      (error 'cross-install "host racket is incompatible with this SDK:\n~a" gate)))
  ;; --- scratch layout (final consume pass) --------------------------------
  (define work (if work-opt (real work-opt) (make-temporary-file "rktwasm-consume-~a" 'directory)))
  (define catalog-dir (real (let ([d (or catalog-dir-opt (build-path work "pkg-catalog"))])
                              (make-directory* d) d)))
  (define addon  (build-path work "final-addon"))      ; user scope (this app's pkgs)
  (define hostzo (build-path work "final-hostzo"))     ; host-form shadow (reusable)
  (define xtgt   (build-path work "final-xtgt"))       ; tpb32l target root (reusable)
  (define xcfg   (build-path work "final-xcfg" "etc")) ; cross config (catalog-as-source)
  ;; --- pass 1: build/refresh the SDK-keyed built-package catalog ----------
  (define cat-url
    (refresh-pkg-catalog! #:catalog-dir catalog-dir #:racket racket #:cc-dir cc-dir
                          #:cross-pkgs cross-pkgs #:cross-links cross-links
                          #:cross-lib cross-lib #:pkg-names pkg-names))
  ;; --- pass 2: final consume into share.data ------------------------------
  ;; The addon is the delta we harvest, so it must be FRESH (a reused `work` keeps
  ;; only the hostzo/xtgt compile shadows, for speed). hostzo/xtgt persist.
  (when (directory-exists? addon) (delete-directory/files addon))
  (for ([d (list addon hostzo xtgt)]) (make-directory* d))
  ;; Prefer the local built-package catalog, then the network (a local app pkg's
  ;; dep absent from the catalog/base falls back to a source fetch).
  (write-xconfig! xcfg #:pkgs-dir cross-pkgs #:links cross-links #:lib cross-lib
                  #:catalogs (if cat-url (list cat-url #f) (list #f)))
  ;; Catalog names from the local built catalog (`--skip-installed` -> a no-op for
  ;; any name already in the base scope, i.e. already in `share.data`).
  (unless (null? pkg-names)
    (run-install #:racket racket #:cc-dir cc-dir #:config-etc xcfg
                 #:hostzo hostzo #:xtgt xtgt #:addon addon #:work work
                 #:src-args (cons "--skip-installed" pkg-names)
                 #:what (format "~a catalog package(s)" (length pkg-names))))
  ;; Local packages install with `--copy` (a `--link` would record an absolute
  ;; host path absent from the runtime FS); one call each. They resolve their own
  ;; deps from the base + catalog (+ network fallback).
  (for ([d (in-list local-pkgs)])
    (define d* (real d))
    (unless (directory-exists? d*) (error 'cross-install "local package source not a dir: ~a" d*))
    (run-install #:racket racket #:cc-dir cc-dir #:config-etc xcfg
                 #:hostzo hostzo #:xtgt xtgt #:addon addon #:work work
                 #:src-args (list "--copy" (path->string d*))
                 #:what (format "local package ~a" d*)))
  ;; --- harvest the tpb32l delta -------------------------------------------
  (define ap (addon-pkgs-dir addon))
  (unless ap (error 'cross-install "no packages landed in the addon scope under ~a" addon))
  (define harvested (harvest! xtgt ap))
  (info-msg "harvested ~a tpb32l artifact(s) into the addon package tree" harvested)
  ;; The new packages are the directories the install dropped under the addon's
  ;; pkgs/ (pkgs.rktd, the addon's pkg db, is a file -- skipped; the runtime
  ;; resolves `require` via links.rktd, not the pkg db).
  (define new-pkgs
    (for/list ([p (in-list (directory-list ap))]
               #:when (directory-exists? (build-path ap p)))
      (cons (path->string p) (build-path ap p))))
  (when (null? new-pkgs) (error 'cross-install "the install added no packages"))
  ;; Verify each REQUESTED package actually compiled (has a tpb32l `.zo` after the
  ;; harvest) -- a genuine compile failure can ALSO end with the tolerated
  ;; "packages installed, although setup reported errors" message, so confirm the
  ;; bytecode is really there rather than ship a half-built payload.
  (define new-names (map car new-pkgs))
  (for ([r (in-list (append pkg-names
                            (map (lambda (d) (path->string (file-name-from-path (real d))))
                                 local-pkgs)))])
    (unless (member r new-names)
      (error 'cross-install
             "requested package ~a did not install -- see output above" r))
    (define pkg-dir (build-path ap r))
    (define has-zo?
      (for/or ([p (in-directory pkg-dir)])
        (and (file-exists? p) (regexp-match? #rx"\\.zo$" (path->string p)))))
    ;; A meta/distribution package (e.g. rhombus-main-distribution) ships only an
    ;; info.rkt -- there's no target source to compile, so it correctly yields no
    ;; tpb32l .zo (info.rkt compiles to the host shadow, read by host setup, not
    ;; the addon tree). Only flag a package that HAS compilable source yet produced
    ;; no bytecode -- that's the genuine half-built-payload failure.
    (define has-src?
      (for/or ([p (in-directory pkg-dir)])
        (and (file-exists? p)
             (regexp-match? #rx"\\.(rkt|ss)$" (path->string p))
             (not (equal? "info.rkt" (path->string (file-name-from-path p)))))))
    (when (and has-src? (not has-zo?))
      (error 'cross-install
             "requested package ~a did not cross-compile (no tpb32l .zo) -- see output above" r)))
  ;; --- merge collection links + extend share.data -------------------------
  (define links-additions
    (for/list ([np (in-list new-pkgs)]) (pkg-link-entry (cdr np) (car np))))
  (define old-links
    (let ([b (data-package-file-bytes #:data data #:js data-js "/share/links.rktd")])
      (if b (with-input-from-bytes b read) '())))
  (define merged-links
    (append links-additions
            (filter (lambda (e) (not (member e links-additions))) old-links)))
  (define links-tmp (build-path work "links.rktd"))
  (call-with-output-file links-tmp #:exists 'replace (lambda (o) (writeln merged-links o)))
  ;; Each new package's files map to `/share/pkgs/<name>/...` (the wholesale
  ;; preload vpath the base tree already uses); plus the merged links file.
  (define add-files
    (cons
     (cons "/share/links.rktd" links-tmp)
     (for*/list ([np (in-list new-pkgs)]
                 [p (in-directory (cdr np))]
                 #:when (file-exists? p))
       (define rel (find-relative-path (real (cdr np)) (real p)))
       (cons (string-append "/share/pkgs/" (car np) "/"
                            (string-join (map path->string (explode-path rel)) "/"))
             p))))
  (make-directory* (->path dest))
  (extend-data-package! #:data data #:js data-js #:add add-files
                        #:dest (->path dest) #:name "share.data")
  (info-msg "cross-installed ~a package(s) -> ~a/share.data{,.js}"
            (length new-pkgs) dest)
  (unless work-opt (delete-directory/files work)))
