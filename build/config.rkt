#lang racket/base
;; Central configuration for the racket-wasm build orchestrator: the pinned
;; upstream commit (read from ../upstream.lock), default package / native-dep
;; selection, and the on-disk layout under .work/.
(require racket/runtime-path
         racket/path)

(provide (all-defined-out))

;; --- repo layout --------------------------------------------------------

;; build/ lives one level under the repo root.
(define-runtime-path build-dir ".")
(define repo-root (simplify-path (build-path build-dir 'up)))

(define (at-root . parts) (apply build-path repo-root parts))

(define patches-dir   (at-root "patches"))
;; overlay/ is regenerated from the fork by extract-from-fork.rkt; overlay-local/
;; is repo-authored additive content NOT derived from the fork (e.g. the web-repl
;; package). Both are copied into the clone by `apply`; the extractor only
;; manages overlay/.
(define overlay-dir       (at-root "overlay"))
(define overlay-local-dir (at-root "overlay-local"))
;; Repo-side, NOT copied into the clone: runtime glue. Holds (a) host-side glue
;; (browser worker bootstrap + dev server), copied into an app's dist/ (default
;; apps/ide/dist/) by the orchestrator's collect-outputs so a surface can be
;; swapped without touching the (expensive) link; and (b) the built-in emcc
;; link-JS glue
;; (`link-glue-names`), passed to cs/c/build.zuo's `wasm` link via the
;; RUNTIME_GLUE_DIR make var. See build-wasm.md and the project roadmap.
(define runtime-glue-dir  (at-root "runtime-glue"))
;; The link-input subset of runtime-glue/: baked into racket.* / racket-web.* by
;; the emcc link, so they are part of the build key (cache.rkt folds exactly
;; these into the delta-hash -- NOT the whole dir, so editing the host-side glue
;; like shell-worker.js doesn't force a relink).
(define link-glue-names
  '("wasmfs-stdin.js" "wasmfs-console.js"
    "node-tty.js" "node-locate-file.js" "node-load-share.js"))
;; Repo-side wasm-deps recipe sources (build-deps.sh + per-dep recipes), passed
;; to cs/c/build.zuo's `wasm-deps` target via the WASM_DEPS_SRC_DIR make var.
;; Also folded into the delta-hash (the recipes determine the linked dep libs).
(define wasm-deps-src-dir (at-root "wasm-deps"))
;; Repo-side source patches applied to CATALOG packages during the clone-free
;; consume (build/consume.rkt `discover-pkg-patches`): `package-patches/<pkg>/
;; *.patch`. Folded into the delta-hash so editing one yields a fresh SDK/catalog
;; (its tpb32l .zo depend on the patch). See build-wasm.md "Text / Pango".
(define package-patches-dir (at-root "package-patches"))

;; The repo's canonical app: the DrRacket-like IDE / web-repl, built like any
;; other app via `app apps/ide` (there is no bespoke `build` subcommand -- it
;; is the dogfood of the generic make-wasm-racket path), landing in
;; apps/ide/dist/ by default. The binary-catalog rebuild reads its package/dep
;; set. Its config lives in apps/ide/app.rkt; its page surface in apps/ide/public.
(define ide-app-dir (at-root "apps" "ide"))
(define work-dir      (at-root ".work"))
;; The cloned upstream tree.
(define clone-dir     (build-path work-dir "racket"))
;; Where the wasm link target emits its output inside the clone.
(define (clone-wasm-out)
  (build-path clone-dir "racket" "src" "build" "cs" "c" "wasm"))

;; --- licenses -----------------------------------------------------------
;;
;; The build collects every applicable license text into a `licenses/` tree in
;; dist/ and the SDK (see build/licenses.rkt). The texts come from three places,
;; all clone-side except this project's own licenses:
;;   * this repo's LICENSE-MIT.txt and LICENSE-APACHE.txt (dual MIT/Apache 2.0);
;;   * upstream Racket's license set, under <clone>/racket/src;
;;   * each built native dep's license file(s), under the dep's extracted source
;;     dir (<clone>/racket/src/build-<name>-em/src).
(define repo-license-mit-file    (at-root "LICENSE-MIT.txt"))
(define repo-license-apache-file (at-root "LICENSE-APACHE.txt"))

;; The umbrella notice written to licenses/README.txt. Names this project's
;; dual MIT/Apache license and points at the bundled component licenses.
(define license-readme-text #<<EOF
racket-wasm license notice
==========================

This project (racket-wasm) is licensed under the MIT License and the Apache
License, Version 2.0, at your option. The full texts are in this directory:

  * racket-wasm-MIT.txt    -- MIT License
  * racket-wasm-APACHE.txt -- Apache License, Version 2.0

The distributed runtime bundles other software, each under its own license. The
full texts are included here:

  * racket/  -- upstream Racket and the Chez Scheme runtime it embeds
                (Apache 2.0, MIT, LGPL, GPL, and the libscheme license).
  * deps/    -- the native C libraries linked into the WebAssembly runtime
                (always libffi; the cairo/pango drawing stack and others when
                the build selects them). One subdirectory per bundled library.

Your use of the distributed runtime is subject to all of the above licenses.
EOF
)

;; --- pinned upstream ----------------------------------------------------

(define upstream-lock-path (at-root "upstream.lock"))

(define upstream-lock
  (call-with-input-file upstream-lock-path read))

(define (lock-ref key)
  (hash-ref upstream-lock key
            (lambda () (error 'config "upstream.lock missing key: ~a" key))))

(define upstream-url  (lock-ref 'url))
(define upstream-sha  (lock-ref 'sha))

;; --- build defaults -----------------------------------------------------
;;
;; The IDE app's package / native-dep / surface config lives in its manifest
;; (apps/ide/app.rkt), read via build/app.rkt `read-app-manifest` -- not here.
;; This keeps a single source of truth for what the default build ships.

;; Host toolchains: overridable on the CLI. #f means "resolve/build".
(define default-host-scheme #f)   ; native *threaded* Chez (cross-compiler host)
(define default-host-racket #f)   ; same-version host Racket (raco cross-server)

;; The target Chez machine type for the WASM build.
(define target-machine "tpb32l")

;; What the emcc link + pack-share-data emit into the clone's wasm out dir -- the
;; runtime proper (the link products + the separate package payload), split by
;; surface. The single `wasm` make target builds BOTH surfaces, so a build always
;; produces (and the cache always stores) the union; an app's `target` then
;; selects which subset collect-outputs copies into dist/.
;;   node    -- racket.{js,wasm,data} + the separate package payload
;;              share.data/share.data.js (loaded at runtime by node-load-share.js).
;;   browser -- racket-web.{js,wasm,data} + the separate package payload
;;              share.data/share.data.js (packed by build/pack.rkt, not the link).
;; Glue/surface are repo-side and copied separately, so they are NOT in this set.
(define node-runtime-names
  '("racket.js" "racket.wasm" "racket.data"))
(define web-runtime-names
  '("racket-web.js" "racket-web.wasm" "racket-web.data"
    "share.data" "share.data.js"))
;; The full set a build emits and the cache snapshots (both surfaces).
(define runtime-output-names (append node-runtime-names web-runtime-names))

;; The package-agnostic runtime BINARIES (everything the emcc link emits) vs the
;; separable package PAYLOAD (share.data*, packed emsdk-free from the package
;; tree). The runtime is built once with PKGS= and cached under a
;; package-agnostic key; the payload is sourced from a cross-SDK cross-root and
;; cached under the package key. See build/stages.rkt `build-runtime` and
;; build-wasm.md "Package-agnostic runtime + packages via the cross-SDK".
(define pkg-payload-names '("share.data" "share.data.js"))
(define base-runtime-names
  (filter (lambda (n) (not (member n pkg-payload-names))) runtime-output-names))

;; An app's `target` field: which surface it runs on. Default is browser.
;; `web` is accepted as an alias for `browser`.
(define (normalize-target t)
  (define s (if (string? t) (string->symbol t) t))
  (case s
    [(browser web) 'browser]
    [(node) 'node]
    [else (error 'app "target must be 'browser or 'node, got: ~s" t)]))

;; The runtime files a given target ships in dist/. Both surfaces ship the
;; separate package payload (share.data*): the browser loads it via importScripts,
;; node via node-load-share.js's indirect-eval. node-runtime-names is the binaries
;; only, so append the payload here.
(define (runtime-names-for-target target)
  (case (normalize-target target)
    [(node) (append node-runtime-names pkg-payload-names)]
    [(browser) web-runtime-names]))

;; --- cross-compiler SDK -------------------------------------------------
;;
;; A standalone artifact, distributed SEPARATELY from the runtime binary
;; package (build/stages.rkt `build-cross-sdk`): the cross-compiler retarget
;; files + a cross-root of `tpb32l` dependency bytecode (sources + .zo), enough
;; for a host Racket of the same version to cross-compile NEW raco packages for
;; `tpb32l` with no clone and no emsdk. The cross-compiler and the `tpb32l` .zo
;; are emscripten-INDEPENDENT (pure target bytecode); only the C runtime is
;; emscripten. See build-wasm.md "Cross-compiler SDK".

;; The clone dir that holds the cross-compiler retarget files; doubles as the
;; `--cross-compiler tpb32l <dir>` plugin dir.
(define (clone-cross-plugin-dir)
  (build-path clone-dir "racket" "src" "build" "cs" "c"))

;; The three retarget files (host-arch + Racket-version locked, target-machine
;; tagged): the cross-compile server + the compile/library xpatches.
(define cross-sdk-retarget-names
  (list "cross-serve.so"
        (format "compile-xpatch.~a" target-machine)
        (format "library-xpatch.~a" target-machine)))

;; The SDK's on-disk layout: a list of (dest-relative-path . clone-source-path).
;; A source that is a directory is copied as a tree; a file is copied as a file.
;; Single source of truth for the collector (build/stages.rkt) and the consume
;; side (build/consume.rkt). The cross-root carries BOTH sources and the in-place
;; `tpb32l` `.zo`: sources let the consumer's racket regenerate host shadows on
;; demand (so `build/zo` is deliberately NOT shipped), the `.zo` are the target
;; dependency bytecode a new package links against.
(define (cross-sdk-layout)
  (define plugin (clone-cross-plugin-dir))
  (append
   (for/list ([n (in-list cross-sdk-retarget-names)])
     (cons (build-path "cross-compiler" n) (build-path plugin n)))
   (list
    (cons (build-path "cross-root" "collects")
          (build-path clone-dir "racket" "collects"))
    (cons (build-path "cross-root" "share" "pkgs")
          (build-path clone-dir "racket" "share" "pkgs"))
    (cons (build-path "cross-root" "share" "links.rktd")
          (build-path clone-dir "racket" "share" "links.rktd"))
    ;; The in-tree bootstrap packages (racket-lib, base, net-lib, ...) the
    ;; cross-root's links reference as `(up up #"pkgs" X)`. Resolved relative to
    ;; <cross-root>/share, that is `<sdk>/pkgs` -- a SIBLING of cross-root. The
    ;; consume (build/consume.rkt) points the install's `links-file` at the
    ;; cross-root, so these dirs MUST be present for the base packages to register
    ;; as installed (else `raco pkg install` re-fetches the whole base closure).
    ;; Mirrors `pack.rkt` `links-pkgs-roots`, which packs the same dirs.
    (cons (build-path "pkgs")
          (build-path clone-dir "pkgs"))
    ;; `lib/system.rktd` carries `target-machine tpb32l`; the consumer's running
    ;; racket reads it (via the cross config's `find-lib-dir`) to know it must
    ;; cross-compile for tpb32l rather than the host machine. Without it the
    ;; cross-compile silently emits HOST bytecode -- see build/consume.rkt and
    ;; build-wasm.md "Consuming the cross-compiler SDK".
    (cons (build-path "cross-root" "lib" "system.rktd")
          (build-path clone-dir "racket" "lib" "system.rktd"))
    ;; `-G` config the cross `raco setup` uses, and the SELF_ROOT build config.
    (cons (build-path "cross-root" "etc")
          (build-path clone-dir "racket" "etc"))
    (cons (build-path "cross-root" "config")
          (build-path clone-dir "build" "config")))))
