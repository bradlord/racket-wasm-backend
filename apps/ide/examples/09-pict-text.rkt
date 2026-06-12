#lang racket

;; Text renders in the browser! pict's `text` lays a string out with
;; Pango/Cairo and hands back a pict you compose like any other shape. (This
;; works because the browser runtime runs Racket on a proxied pthread so the
;; font path's helper thread can spawn -- see build-wasm.md "Browser text".)

(require pict)

;; `text` takes a string, a font family ('roman, 'modern = monospace, 'swiss,
;; 'decorative), and a size. The result is just a pict.
(define title    (text "Racket → WebAssembly" 'roman 32))
(define subtitle (colorize (text "Pango text, rendered in the browser" 'roman 18)
                           "slategray"))

;; Text composes with shapes -- here a label centred on a rounded panel.
(define badge
  (cc-superimpose
   (colorize (filled-rounded-rectangle 240 56 12) "midnightblue")
   (colorize (text "racket/draw + pict" 'modern 20) "white")))

(define poster
  (vc-append 18
             title
             subtitle
             (hc-append 16
                        (colorize (disk 56) "crimson")
                        badge
                        (colorize (filled-ellipse 80 56) "goldenrod"))))

;; A bare pict result renders inline.
(frame (inset poster 24))

;; After Run, try (scale poster 1.5) -- or your own (text "hi" 'roman 40) --
;; at the REPL on the right.
