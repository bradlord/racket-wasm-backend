#lang racket/base
;; dom-eval -- synchronous DOM RPC. Ships a UTF-8 JS source string to
;; the page, which evals it on its next animation frame and returns the
;; stringified result (racket/src/cs/c/wasm_dom.c). Worker-only: under
;; node there is no page to service the command and the call hangs.
;;
;;   (dom-eval "document.title")
;;   (dom-eval "document.title = 'hi from Racket'")
;;
;; v0: literally evals arbitrary JS in the page scope -- prototyping
;; only, not safe for untrusted code. See build-wasm.md, "DOM
;; interaction", for the typed-protocol migration path.

(require ffi/unsafe/vm)

(provide dom-eval)

(define wasm-dom-eval-raw
  (vm-eval '(foreign-procedure "wasm_dom_eval" (u8* int u8* int) int)))

;; #:capacity bounds the reply buffer; the page truncates to it. The
;; DOM_REPLY_CAP on the C side is 64 KiB, so larger is pointless.
(define (dom-eval js #:capacity [cap 65536])
  (define src (string->bytes/utf-8 js))
  (define out (make-bytes cap))
  (define n (wasm-dom-eval-raw src (bytes-length src) out (bytes-length out)))
  (bytes->string/utf-8 out #\? 0 n))
