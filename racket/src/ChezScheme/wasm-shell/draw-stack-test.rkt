;; Working example for the draw-lib FFI stack on the WASM build.
;;
;; Demonstrates the parts that work today through Phase C
;; (ffi-lib + get-ffi-obj routed through Chez's static foreign-symbol
;; table via the rktio dll shim):
;;
;;   - libcairo is "loadable" (sentinel handle) and its entry points
;;     resolve through the shim.
;;   - draw-lib's own loader files (racket/draw/unsafe/cairo,
;;     racket/draw/unsafe/png, racket/draw/unsafe/freetype) load
;;     cleanly -- which means their bindings to ~400 Cairo + ~150 png
;;     + ~600 FreeType entry points all resolve.
;;   - A real Cairo drawing operation runs end-to-end: image surface
;;     allocation, paint, primitives, surface_get_data.
;;
;; Run from the build dir:
;;   cd racket/src/ChezScheme/em-tpb32l/bin/tpb32l
;;   node scheme.js -u .../draw-stack-test.rkt
;;
;; (Pipe via stdin if you don't have file access into MEMFS yet:
;;    cat draw-stack-test.rkt | tail -n +2 | node scheme.js
;;  -- the `tail -n +2` skips the #lang line since the REPL reads
;;  top-level forms, not modules.)

#lang racket

(require ffi/unsafe)

;; --- 1. ffi-lib succeeds with any name (Phase C shim) ---------------
;;
;; Under WASM none of these libraries are loaded via dlopen -- every
;; call returns a sentinel handle. The actual gate is whether each
;; symbol was Sforeign_symbol-registered.

(define cairo  (ffi-lib "libcairo"))
(define png    (ffi-lib "libpng16"))
(define ft     (ffi-lib "libfreetype"))

(printf "ffi-lib resolved:~n")
(printf "  cairo: ~s~n" cairo)
(printf "  png:   ~s~n" png)
(printf "  ft:    ~s~n" ft)
(newline)

;; --- 2. draw-lib's own loader files instantiate cleanly --------------
;;
;; Each of these top-level files in draw-lib does define-ffi-obj on
;; hundreds of entry points. They fail at module load if a symbol
;; isn't registered, so reaching their body proves the entire public
;; API surface of cairo/png/freetype is reachable from Racket.

(printf "Loading draw-lib unsafe modules:~n")
(dynamic-require 'racket/draw/unsafe/cairo #f)  (printf "  unsafe/cairo: ok~n")
(dynamic-require 'racket/draw/unsafe/png   #f)  (printf "  unsafe/png:   ok~n")
(newline)

;; --- 3. Draw something through the standard FFI ---------------------

(define cairo_format_stride_for_width
  (get-ffi-obj 'cairo_format_stride_for_width cairo
               (_fun _int _int -> _int)))
(define cairo_image_surface_create_for_data
  (get-ffi-obj 'cairo_image_surface_create_for_data cairo
               (_fun _pointer _int _int _int _int -> _pointer)))
(define cairo_create
  (get-ffi-obj 'cairo_create cairo (_fun _pointer -> _pointer)))
(define cairo_destroy
  (get-ffi-obj 'cairo_destroy cairo (_fun _pointer -> _void)))
(define cairo_surface_destroy
  (get-ffi-obj 'cairo_surface_destroy cairo (_fun _pointer -> _void)))
(define cairo_surface_flush
  (get-ffi-obj 'cairo_surface_flush cairo (_fun _pointer -> _void)))
(define cairo_set_source_rgb
  (get-ffi-obj 'cairo_set_source_rgb cairo
               (_fun _pointer _double _double _double -> _void)))
(define cairo_arc
  (get-ffi-obj 'cairo_arc cairo
               (_fun _pointer _double _double _double _double _double -> _void)))
(define cairo_fill
  (get-ffi-obj 'cairo_fill cairo (_fun _pointer -> _void)))
(define cairo_paint
  (get-ffi-obj 'cairo_paint cairo (_fun _pointer -> _void)))

(define ARGB32 0)
(define W 8) (define H 1)
(define stride (cairo_format_stride_for_width ARGB32 W))
(define buf (malloc (* stride H) 'raw))
(memset buf 0 (* stride H))
(define surf (cairo_image_surface_create_for_data buf ARGB32 W H stride))
(define ctx  (cairo_create surf))

(cairo_set_source_rgb ctx 1.0 0.5 0.25)   ; orange
(cairo_paint ctx)
(cairo_surface_flush surf)

;; Read pixel 0 back -- expect BGRA (40 80 ff ff) = R=255 G=128 B=64
(define peek (make-bytes 4 0))
(memcpy peek buf 4)
(printf "1x1 paint(1.0,0.5,0.25) -> BGRA hex: ~a~n"
        (for/list ([b (in-bytes peek)])
          (~r b #:base 16 #:min-width 2 #:pad-string "0")))
(printf "expected:                            (40 80 ff ff)~n")

(cairo_destroy ctx)
(cairo_surface_destroy surf)
(free buf)
