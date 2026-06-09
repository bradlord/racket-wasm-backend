#lang racket/base
;; App manifest for the node Racket REPL -- a target='node app. The runtime's
;; node surface (scheme.{js,wasm,data}) IS a Racket REPL: piping or typing into
;; `node scheme.js` evaluates forms and prints results. Build it with:
;;
;;   racket build/main.rkt app apps/node-repl \
;;     --scheme <host-chez> --racket <host-racket>
;;
;; Output lands in apps/node-repl/dist (override with --dest). Then:
;;
;;   echo '(+ 1 2)' | node apps/node-repl/dist/scheme.js     # one-shot
;;   node apps/node-repl/dist/scheme.js                      # interactive REPL
;;
;; No page surface, no dev server -- node runs scheme.js directly. Bakes the IDE
;; package set so racket/draw, pict, and datalog are available at the prompt.
(provide app)

(define app
  (hash
   ;; Same catalog packages as the IDE, available at the REPL.
   'pkgs      '(draw-lib datalog pict-lib)
   ;; The full cairo/pango stack racket/draw needs.
   'wasm-libs '(draw)
   ;; Node surface: ship scheme.{js,wasm,data} only -- no page, no browser glue.
   'target    'node))
