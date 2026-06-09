#! /usr/bin/env racket
#lang racket/base

;; Static file server that sets the headers SharedArrayBuffer requires.
;;
;; The Racket WASM browser surfaces link with shared memory + pthreads, so
;; the page must be "cross-origin isolated": that needs
;;
;;     Cross-Origin-Opener-Policy: same-origin
;;     Cross-Origin-Embedder-Policy: require-corp
;;
;; A plain static server (`python3 -m http.server`, `raco static-files`, ...)
;; does not send these, so SharedArrayBuffer is unavailable and the runtime
;; never starts. Run this from the directory that holds index.html and the
;; generated scheme-web.* assets:
;;
;;     racket serve.rkt [port]      # default port 8123
;;
;; then open http://127.0.0.1:<port>/

(require racket/cmdline
         racket/tcp
         racket/port
         racket/string
         racket/path
         net/uri-codec)

;; Content types by (lowercased) extension, including the leading dot.
(define content-types
  (hash ".html" "text/html; charset=utf-8"
        ".htm"  "text/html; charset=utf-8"
        ".js"   "text/javascript; charset=utf-8"
        ".mjs"  "text/javascript; charset=utf-8"
        ".css"  "text/css; charset=utf-8"
        ".json" "application/json"
        ".map"  "application/json"
        ".wasm" "application/wasm"
        ".data" "application/octet-stream"
        ".png"  "image/png"
        ".svg"  "image/svg+xml"
        ".ico"  "image/x-icon"
        ".txt"  "text/plain; charset=utf-8"))

(define (guess-type path)
  (define ext (path-get-extension path))
  (or (and ext
           (hash-ref content-types
                     (string-downcase (bytes->string/utf-8 ext))
                     #f))
      "application/octet-stream"))

;; Headers sent on every response: the cross-origin-isolation pair plus a
;; no-store policy to keep development reloads honest.
(define (write-status out code reason extra-headers)
  (fprintf out "HTTP/1.1 ~a ~a\r\n" code reason)
  (fprintf out "Cross-Origin-Opener-Policy: same-origin\r\n")
  (fprintf out "Cross-Origin-Embedder-Policy: require-corp\r\n")
  (fprintf out "Cache-Control: no-store\r\n")
  (fprintf out "Connection: close\r\n")
  (for ([h (in-list extra-headers)])
    (fprintf out "~a: ~a\r\n" (car h) (cdr h)))
  (fprintf out "\r\n"))

(define (send-text out code reason body #:head? [head? #f])
  (define bytes (string->bytes/utf-8 body))
  (write-status out code reason
                (list (cons "Content-Type" "text/html; charset=utf-8")
                      (cons "Content-Length" (bytes-length bytes))))
  (unless head? (write-bytes bytes out)))

;; Resolve a request target to a file under the serving root, or #f if it
;; escapes the root (a `..` traversal) or does not exist as a file.
(define (resolve-path root target)
  (define no-query (car (string-split target "?" #:trim? #f)))
  (define decoded (uri-decode no-query))
  (define rel (string-trim decoded "/" #:right? #f))
  (cond
    [(string=? rel "") (simplify-path (build-path root "index.html"))]
    [else
     (define p (simplify-path (build-path root rel) #f))
     (define root* (simplify-path (path->complete-path root) #f))
     (cond
       [(not (string-prefix? (path->string (path->complete-path p))
                             (path->string root*)))
        #f]
       [(file-exists? p) p]
       [else #f])]))

(define (handle-connection root in out)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (define line (read-line in 'return-linefeed))
    (when (string? line)
      (define parts (string-split line))
      (define method (if (pair? parts) (car parts) "GET"))
      (define target (if (>= (length parts) 2) (cadr parts) "/"))
      ;; Drain the remaining request headers.
      (let loop ()
        (define h (read-line in 'return-linefeed))
        (unless (or (eof-object? h) (string=? h "")) (loop)))
      (define head? (string-ci=? method "HEAD"))
      (cond
        [(not (or head? (string-ci=? method "GET")))
         (send-text out 405 "Method Not Allowed" "405 Method Not Allowed"
                    #:head? head?)]
        [else
         (define resolved (resolve-path root target))
         (cond
           [(path? resolved)
            (write-status out 200 "OK"
                          (list (cons "Content-Type" (guess-type resolved))
                                (cons "Content-Length" (file-size resolved))))
            (unless head?
              (call-with-input-file resolved
                (lambda (fin) (copy-port fin out))))]
           [else
            (send-text out 404 "Not Found" "404 Not Found" #:head? head?)])])
      (flush-output out))))

(define (serve port)
  (define root (current-directory))
  (define listener (tcp-listen port 512 #t "127.0.0.1"))
  (printf "Serving cross-origin-isolated on http://127.0.0.1:~a/\n" port)
  (flush-output)
  (let loop ()
    (define-values (in out) (tcp-accept listener))
    ;; One thread per connection; each response sets Connection: close.
    (thread (lambda ()
              (dynamic-wind
               void
               (lambda () (handle-connection root in out))
               (lambda ()
                 (close-input-port in)
                 (close-output-port out)))))
    (loop)))

(module+ main
  (define port
    (command-line
     #:program "serve.rkt"
     #:args ([port "8123"])
     (string->number port)))
  (unless (and (exact-integer? port) (<= 1 port 65535))
    (error 'serve.rkt "invalid port: ~a" port))
  (with-handlers ([exn:break? (lambda (_) (void))])
    (serve port)))
