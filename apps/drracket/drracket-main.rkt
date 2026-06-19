#lang racket/base
;; Boot DrRacket in the WASM mred backend.
;; PLT_WASM_GUI is set by argv BEFORE this is required, so racket/gui/base
;; (loaded transitively) picks wx/wasm. We just trigger the normal startup
;; sequence: splash -> tool-lib (loads framework+drracket units) -> frame.
;; DrRacket's own event loop (default eventspace) keeps the pump alive.
(dynamic-require 'drracket/private/drracket-normal #f)
