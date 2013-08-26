#lang racket/base
(require racket/contract/base
         racket/match
         racket/list
         racket/port
         (rename-in racket/tcp
                    [tcp-connect plain-tcp-connect]
                    [tcp-abandon-port plain-tcp-abandon-port])
         openssl
         "win32-ssl.rkt")

;; Lib

(define (->string bs)
  (if (bytes? bs)
    (bytes->string/utf-8 bs)
    bs))

(define (read-bytes-line/not-eof ip kind)
  (define bs (read-bytes-line ip kind))
  (when (eof-object? bs)
    (error 'http-client "Connection ended early"))
  bs)

;; Core

(struct http-conn (host to from abandon-p) #:mutable)

(define (make-http-conn)
  (http-conn #f #f #f #f))

(define (http-conn-live? hc)
  (and (http-conn-to hc)
       (http-conn-from hc)))

(define (http-conn-open! hc host-bs #:ssl? [ssl? #f] #:port [port (if ssl? 443 80)])
  (http-conn-close! hc)
  (define host (->string host-bs))
  (define ssl-version (if (boolean? ssl?) 'sslv2-or-v3 ssl?))

  (define-values (from to)
    (cond [ssl?
           (cond
             [(or ssl-available? (not win32-ssl-available?))
              (set-http-conn-abandon-p! hc ssl-abandon-port)
              (ssl-connect host port ssl-version)]
             [else
              (set-http-conn-abandon-p! hc win32-ssl-abandon-port)
              (win32-ssl-connect host port ssl-version)])]
          [else
           (set-http-conn-abandon-p! hc plain-tcp-abandon-port)
           (plain-tcp-connect host port)]))

  (set-http-conn-host! hc host)
  (set-http-conn-to! hc to)
  (set-http-conn-from! hc from))

(define (http-conn-close! hc)
  (match-define (http-conn host to from abandon) hc)
  (set-http-conn-host! hc #f)
  (when to
    (abandon to)
    (set-http-conn-to! hc #f))
  (when from
    ;; (abandon from)
    (set-http-conn-from! hc #f))
  (set-http-conn-abandon-p! hc #f))

(define (http-conn-send! hc url-bs
                         #:method [method-bss #"GET"]
                         #:headers [headers-bs empty]
                         #:data [data-bsf #f])
  (match-define (http-conn host to from _) hc)
  (fprintf to "~a ~a HTTP/1.1\r\n" method-bss url-bs)
  (fprintf to "Host: ~a\r\n" host)
  (define data
    (if (string? data-bsf)
      (string->bytes/utf-8 data-bsf)
      data-bsf))
  (when data
    (fprintf to "Content-Length: ~a\r\n" (bytes-length data)))
  (for ([h (in-list headers-bs)])
    (fprintf to "~a\r\n" h))
  (fprintf to "\r\n")
  (when data
    (display data to))
  (flush-output to))

(define (http-conn-status! hc)
  (read-bytes-line/not-eof (http-conn-from hc) 'return-linefeed))

(define (http-conn-headers! hc)
  (define top (read-bytes-line/not-eof (http-conn-from hc) 'return-linefeed))
  (if (bytes=? top #"")
    empty
    (cons top (http-conn-headers! hc))))

;; xxx read more at a time
(define (copy-bytes in out count)
  (unless (zero? count)
    (define b (read-byte in))
    (unless (eof-object? b)
      (write-byte b out)
      (copy-bytes in out (sub1 count)))))

(define (http-conn-response-port/rest! hc)
  (http-conn-response-port/length! hc +inf.0 #:close? #t))

(define (http-conn-response-port/length! hc count #:close? [close? #f])
  (define-values (in out) (make-pipe))
  (thread
   (λ ()
     (copy-bytes (http-conn-from hc) out count)
     (when close?
       (http-conn-close! hc))
     (close-output-port out)))
  in)

(define (http-conn-response-port/chunked! hc #:close? [close? #f])
  (define (http-pipe-chunk ip op)
    (define crlf-bytes (make-bytes 2))
    (let loop ([last-bytes #f])
      (define size-str (read-line ip 'return-linefeed))
      (define chunk-size (string->number size-str 16))
      (unless chunk-size
        (error 'http-conn-response/chunked "Could not parse ~S as hexadecimal number" size-str))
      (define use-last-bytes?
        (and last-bytes (<= chunk-size (bytes-length last-bytes))))
      (if (zero? chunk-size)
        (begin (flush-output op)
               (close-output-port op))
        (let* ([bs (if use-last-bytes?
                     (begin
                       (read-bytes! last-bytes ip 0 chunk-size)
                       last-bytes)
                     (read-bytes chunk-size ip))]
               [crlf (read-bytes! crlf-bytes ip 0 2)])
          (write-bytes bs op 0 chunk-size)
          (loop bs)))))

  (define-values (in out) (make-pipe))
  (thread
   (λ ()
     (http-pipe-chunk (http-conn-from hc) out)
     (when close?
       (http-conn-close! hc))
     (close-output-port out)))
  in)

;; Derived

(define (http-conn-open host-bs #:ssl? [ssl? #f] #:port [port (if ssl? 443 80)])
  (define hc (make-http-conn))
  (http-conn-open! hc host-bs #:ssl? ssl? #:port port)
  hc)

(define (http-conn-recv! hc
                         #:close? [iclose? #f])
  (define status (http-conn-status! hc))
  (define headers (http-conn-headers! hc))
  (define close?
    (or iclose?
        (member #"Connection: close" headers)))
  (define response-port
    (cond
      [(member #"Transfer-Encoding: chunked" headers)
       (http-conn-response-port/chunked! hc #:close? #t)]
      [(ormap (λ (h)
                (match (regexp-match #rx#"^Content-Length: (.+)$" h)
                  [#f #f]
                  [(list _ cl-bs)
                   (string->number
                    (bytes->string/utf-8 cl-bs))]))
              headers)
       =>
       (λ (count)
         (http-conn-response-port/length! hc count #:close? close?))]
      [else
       (http-conn-response-port/rest! hc)]))
  (values status headers response-port))

(define (http-conn-sendrecv! hc url-bs
                             #:method [method-bss #"GET"]
                             #:headers [headers-bs empty]
                             #:data [data-bsf #f]
                             #:close? [close? #f])
  (http-conn-send! hc url-bs
                   #:method method-bss
                   #:headers headers-bs
                   #:data data-bsf)
  (http-conn-recv! hc #:close? close?))

(define (http-sendrecv host-bs url-bs
                       #:ssl? [ssl? #f]
                       #:port [port (if ssl? 443 80)]
                       #:method [method-bss #"GET"]
                       #:headers [headers-bs empty]
                       #:data [data-bsf #f])
  (define hc (http-conn-open host-bs #:ssl? ssl? #:port port))
  (http-conn-sendrecv! hc url-bs
                       #:method method-bss
                       #:headers headers-bs
                       #:data data-bsf
                       #:close? #t))

(provide
 (contract-out
  [http-conn?
   (-> any/c
       boolean?)]
  [http-conn-live?
   (-> any/c
       boolean?)]
  [rename
   make-http-conn http-conn
   (-> http-conn?)]
  [http-conn-open!
   (->* (http-conn? (or/c bytes? string?))
        (#:ssl? (or/c boolean? ssl-client-context? symbol?)
                #:port (between/c 1 65535))
        void?)]
  [http-conn-close!
   (-> http-conn? void?)]
  [http-conn-send!
   (->*
    (http-conn-live? (or/c bytes? string?))
    (#:method (or/c bytes? string? symbol?)
              #:headers (listof (or/c bytes? string?))
              #:data (or/c false/c bytes? string?))
    void)]
  ;; Derived
  [http-conn-open
   (->* ((or/c bytes? string?))
        (#:ssl? (or/c boolean? ssl-client-context? symbol?)
                #:port (between/c 1 65535))
        http-conn?)]
  [http-conn-recv!
   (->* (http-conn-live?)
        (#:close? boolean?)
        (values bytes? (listof bytes?) input-port?))]
  [http-conn-sendrecv!
   (->* (http-conn-live? (or/c bytes? string?))
        (#:method (or/c bytes? string? symbol?)
                  #:headers (listof (or/c bytes? string?))
                  #:data (or/c false/c bytes? string?)
                  #:close? boolean?)
        (values bytes? (listof bytes?) input-port?))]
  [http-sendrecv
   (->* ((or/c bytes? string?) (or/c bytes? string?))
        (#:ssl? (or/c boolean? ssl-client-context? symbol?)
                #:port (between/c 1 65535)
                #:method (or/c bytes? string? symbol?)
                #:headers (listof (or/c bytes? string?))
                #:data (or/c false/c bytes? string?))
        (values bytes? (listof bytes?) input-port?))]))