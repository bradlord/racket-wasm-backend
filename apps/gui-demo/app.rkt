#lang racket/base
;; App manifest for the wasm racket/gui demo -- the first browser surface that
;; exercises the wx/wasm/ mred backend (gui-backend/wx-wasm, applied to gui-lib
;; via package-patches/gui-lib). It bundles gui-lib + the racket/draw stack and
;; ships a single-canvas page (public/gui-demo.js) that:
;;   - boots the runtime with argv ["-e" "(putenv PLT_WASM_GUI 1)" "-t" main],
;;     so the env var that selects the wasm mred backend (wx/platform.rkt's unix
;;     branch) is set BEFORE racket/gui is required and there is no stdin REPL;
;;   - mirrors each { type:"canvas" } blit from the runtime onto one persistent
;;     <canvas> (the frame's surface), instead of the IDE's append-a-bitmap;
;;   - feeds DOM mouse/key events into the GUI input ring (wasm_gui_events.c),
;;     which the backend's event pump (wx/wasm/queue.rkt) drains.
;;
;; The demo program blocks in (yield (make-semaphore)) -- a Racket-level park,
;; not a stdin read -- so the eventspace dispatch loop keeps running the pump.
(provide app)

(define app
  (hash
   ;; gui-lib brings racket/gui; draw-lib + the cairo/pango wasm-libs render it.
   'pkgs       '(draw-lib gui-lib)
   'wasm-libs  '(draw)
   'public     "public"))
