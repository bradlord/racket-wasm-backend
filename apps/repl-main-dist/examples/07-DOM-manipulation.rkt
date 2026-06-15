#lang racket

;; dom-eval (from the preloaded web-repl collection) is a synchronous
;; JS-on-page primitive: it ships a JS source string to the page,
;; which runs eval() on its next animation frame and returns the
;; result as a string. v0 is arbitrary JS; a typed protocol is the
;; future direction (see build-wasm.md).

(require web-repl/dom)

(displayln "DOM RPC round-trips through page eval:")
(printf "  document.title before: ~s~n" (dom-eval "document.title"))
(dom-eval "document.title = 'hello from Racket'")
(printf "  document.title after:  ~s~n" (dom-eval "document.title"))

(printf "  navigator.userAgent (truncated): ~s~n"
        (substring (dom-eval "navigator.userAgent") 0 50))

(define count
  (dom-eval "document.querySelectorAll('button').length"))
(printf "  buttons on this page: ~a~n" count)

;; Drop a note right under the page's <h1> heading.
(dom-eval (string-append
           "var n = document.createElement('div');"
           "n.textContent = 'racket touched me (' + new Date().toLocaleTimeString() + ')';"
           "n.style.cssText = 'margin: 8px 0 0; color: #f59e0b; font-family: monospace;';"
           "document.querySelector('h1').insertAdjacentElement('afterend', n);"
           "'div appended'"))

;; After Run, try (dom-eval "document.title") at the REPL on the right.
