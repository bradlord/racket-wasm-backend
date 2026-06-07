#lang racket/base
;; web-repl/text -- browser-native text rendering.
;;
;; racket/draw's own text path (Pango -> fontconfig -> GLib) deadlocks in
;; the browser worker: the font path makes GLib spawn a helper thread and
;; g_cond_wait()s for it, but the shell runs Racket synchronously in a
;; Worker that never returns to its event loop to finish creating that
;; thread (see build-wasm.md, "text hangs in the browser"). This sidesteps
;; the whole stack: it asks the *page* to lay out and rasterize the text
;; with Canvas 2D, then brings the result back as a PNG and decodes it into
;; a racket/draw bitmap%. No fonts in the image, no Pango/GLib on the path.
;;
;; Browser shell only -- dom-eval needs the page (it hangs under node).
;;
;;   (require web-repl/text)
;;   (display-text "Hello!" #:font "bold 28px serif" #:color "crimson")
;;   (define bm (text->bitmap "label" #:font "20px sans-serif"))
;;   (define-values (w h) (measure-text "label" #:font "20px sans-serif"))
;;   ;; composes with pict:
;;   (require pict) (vc-append (text-pict "caption") (disk 40))
;;
;; `font` is a CSS font string (the page's own fonts + shaping are used).
;; `color`/`background` are CSS colors (`background` #f = transparent).
;; The PNG comes back over the 64 KiB DOM-RPC reply channel, so keep each
;; string to roughly a line; longer/larger renders can overflow it.

(require racket/port
         racket/string
         "dom.rkt"
         "display-bm.rkt")

(provide measure-text text->bitmap display-text text-pict)

;; draw-lib / net-lib are *packages*; web-repl is a core collection that is
;; compiled before packages exist in a clean source bootstrap. Resolve at
;; instantiation (which only happens in the assembled image, where both are
;; present) rather than as compile-time requires.
(define read-bitmap*   (dynamic-require 'racket/draw 'read-bitmap))
(define base64-decode* (dynamic-require 'net/base64 'base64-decode))

;; Render a Racket string as a JS string literal (so arbitrary text can be
;; embedded in the dom-eval source safely).
(define (js-quote s)
  (define o (open-output-string))
  (write-char #\" o)
  (for ([c (in-string s)])
    (cond
      [(eqv? c #\\)       (write-string "\\\\" o)]
      [(eqv? c #\")       (write-string "\\\"" o)]
      [(eqv? c #\newline) (write-string "\\n" o)]
      [(eqv? c #\return)  (write-string "\\r" o)]
      [(eqv? c #\tab)     (write-string "\\t" o)]
      [(char<? c #\u20)
       (write-string "\\u" o)
       (define hx (number->string (char->integer c) 16))
       (write-string (make-string (- 4 (string-length hx)) #\0) o)
       (write-string hx o)]
      [else (write-char c o)]))
  (write-char #\" o)
  (get-output-string o))

;; JS that sets up a measuring 2d context for `font` over `str`. Leaves the
;; canvas `c`, context `x`, metrics `m`, font px size `s`, and ceil'd
;; ascent `a` / descent `d` / width `w` / height `h` in scope.
(define (measure-prelude str font)
  (string-append
   "var c=document.createElement('canvas');var x=c.getContext('2d');"
   "x.font=" (js-quote font) ";var m=x.measureText(" (js-quote str) ");"
   "var s=(/([0-9.]+)px/.exec(x.font)||[0,16])[1]*1;"
   "var a=Math.ceil(m.actualBoundingBoxAscent||s*0.8);"
   "var d=Math.ceil(m.actualBoundingBoxDescent||s*0.2);"
   "var w=Math.max(1,Math.ceil(m.width));var h=Math.max(1,a+d);"))

;; measure-text : string [#:font css] -> (values width height)
(define (measure-text str #:font [font "16px sans-serif"])
  (define res (dom-eval (string-append "(function(){" (measure-prelude str font)
                                       "return w+','+h;})()")))
  (define ps (and (string? res) (map string->number (string-split res ","))))
  (if (and ps (= 2 (length ps)) (andmap number? ps))
      (values (car ps) (cadr ps))
      (error 'measure-text "unexpected reply (not running in the browser shell?): ~e" res)))

;; text->bitmap : string [#:font #:color #:background] -> bitmap%
(define (text->bitmap str
                      #:font       [font  "16px sans-serif"]
                      #:color      [color "black"]
                      #:background [bg    #f])
  (define js
    (string-append
     "(function(){" (measure-prelude str font)
     "c.width=w;c.height=h;x=c.getContext('2d');"
     "x.font=" (js-quote font) ";x.textBaseline='alphabetic';"
     (if bg (string-append "x.fillStyle=" (js-quote bg) ";x.fillRect(0,0,w,h);") "")
     "x.fillStyle=" (js-quote color) ";x.fillText(" (js-quote str) ",0,a);"
     "return c.toDataURL('image/png');})()"))
  (define url (dom-eval js))
  (define prefix "data:image/png;base64,")
  (unless (and (string? url) (string-prefix? url prefix))
    (error 'text->bitmap
           "unexpected reply (truncated, too large, or not in the browser?): ~e"
           (and (string? url) (substring url 0 (min 80 (string-length url))))))
  (define png (base64-decode* (string->bytes/utf-8 (substring url (string-length prefix)))))
  ;; 'png/alpha keeps the transparent background so text composites onto
  ;; the page (and other picts) instead of a white box.
  (read-bitmap* (open-input-bytes png) 'png/alpha))

;; display-text : string [#:font #:color #:background] -> void
;; Render `str` and blit it into the Interactions transcript.
(define (display-text str
                      #:font       [font  "16px sans-serif"]
                      #:color      [color "black"]
                      #:background [bg    #f])
  (display-bm (text->bitmap str #:font font #:color color #:background bg)))

;; text-pict : string [#:font #:color #:background] -> pict
;; A bitmap-backed pict, so browser-rendered text composes with the rest of
;; pict (hc-append, frame, ...). pict is a package -> lazy require.
;;
;; CAVEAT: drawing/rendering the result (e.g. the IDE's pict printer, which
;; calls pict->bitmap) needs (send dc draw-bitmap ...), and that currently
;; traps in this build on a separate latent draw-lib FFI bug
;; (cairo_pattern_reference is mis-bound, returning void instead of the
;; pattern, so wasm's typed call_indirect rejects it -- same class as
;; cairo_font_options_copy on the wasm-text-fonts-wip branch). So this
;; produces a valid pict but it will not render until that is fixed; the
;; direct helpers above (display-text/text->bitmap) work today.
(define (text-pict str
                   #:font       [font  "16px sans-serif"]
                   #:color      [color "black"]
                   #:background [bg    #f])
  ((dynamic-require 'pict 'bitmap)
   (text->bitmap str #:font font #:color color #:background bg)))
