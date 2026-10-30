#!r6rs
;;; (jsonparse-testing yajl): yajl's parsing cases as jsonparse's events
;;; (ADR-0012), the committed script that translates each .gold.
;;;
;;; yajl's test/parsing/cases hold 58 inputs, each with a .gold file: what
;;; yajl_test printed while parsing it. This library reads a gold file and a
;;; (jsonparse-testing machine) trace into the same logical events. An Event
;;; is one of:
;;;
;;;   (map-open) (map-close) (array-open) (array-close)
;;;   (key BYTES) (string BYTES)   the value as UTF-8 bytes, a bytevector
;;;   (integer TEXT)               the number's decimal text, a string
;;;   (double NUMBER)              a flonum
;;;   (bool #t) (bool #f) (null)
;;;   (rejected)                   any error, whatever its text
;;;
;;;   gold-events     a gold file's bytes as events
;;;   trace-events    a trace as events
;;;   same-double?    two flonums alike as yajl prints them, with %g
;;;   same-events?    two event lists alike, doubles by same-double?
;;;   events-prefix?  one event list the start of another, likewise
;;;
;;; Test-only: it lives in tests/, on make test's library path.
(library (jsonparse-testing yajl)
  (export gold-events trace-events same-double? same-events? events-prefix?)
  (import (rnrs) (jsonparse-testing machine))

  ;; --- bytes ------------------------------------------------------------------

  (define (starts-with? bv i prefix)
    (let ((n (bytevector-length prefix)))
      (and (<= (+ i n) (bytevector-length bv))
           (let loop ((k 0))
             (or (= k n)
                 (and (= (bytevector-u8-ref bv (+ i k)) (bytevector-u8-ref prefix k))
                      (loop (+ k 1))))))))

  ;; The first position at or after FROM where BV holds the bytes of NEEDLE,
  ;; or #f.
  (define (search bv needle from)
    (let ((last (- (bytevector-length bv) (bytevector-length needle))))
      (let loop ((i from))
        (cond ((> i last) #f)
              ((starts-with? bv i needle) i)
              (else (loop (+ i 1)))))))

  (define (sub bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  (define (concat bvs)
    (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
      (fold-left (lambda (at bv)
                   (bytevector-copy! bv 0 out at (bytevector-length bv))
                   (+ at (bytevector-length bv)))
                 0 bvs)
      out))

  ;; --- the gold ---------------------------------------------------------------
  ;;
  ;; yajl_test (yajl 5e3a785, test/parsing/yajl_test.c) prints one line per
  ;; callback, its error line from yajl_get_error, unverbose, if the parse
  ;; failed, and then `memory leaks:`:
  ;;
  ;;   map open '{'   map close '}'   array open '['   array close ']'
  ;;   null   bool: true   bool: false
  ;;   integer: %lld   double: %g
  ;;   string: '...'   key: '%s'      the value's bytes, raw
  ;;   lexical error: ...   parse error: ...
  ;;   memory leaks:\t%u
  ;;
  ;; A key goes through %s, so a key holding NUL prints cut short at it;
  ;; tests/test-yajl.sps checks that no case has one.
  ;;
  ;; Splitting lines. The gold is read as bytes, never decoded, since a value
  ;; is raw UTF-8 and may hold NUL, a newline or a quote. Every line but a
  ;; value line is ASCII text up to its newline. A value line runs from its
  ;; opening quote to a quote followed by a newline, and the value may hold
  ;; that pair itself, so the reader tries each such pair in turn and takes
  ;; the first after which the rest of the gold reads. A gold that reads more
  ;; than one way is ambiguous in yajl's format itself: the shortest value
  ;; wins.

  (define (utf8 s) (string->utf8 s))

  (define fixed-lines
    (map (lambda (l) (cons (utf8 (car l)) (cdr l)))
         '(("map open '{'\n" . (map-open))
           ("map close '}'\n" . (map-close))
           ("array open '['\n" . (array-open))
           ("array close ']'\n" . (array-close))
           ("null\n" . (null))
           ("bool: true\n" . (bool #t))
           ("bool: false\n" . (bool #f)))))

  ;; Each prefix, and how the line's text after it reads: an event, none for
  ;; a line that gives no event, or #f for a text that does not read.
  (define text-lines
    (map (lambda (l) (cons (utf8 (car l)) (cdr l)))
         (list (cons "integer: " (lambda (text) (list 'integer text)))
               (cons "double: " (lambda (text)
                                  (let ((x (string->number text)))
                                    (and x (list 'double (inexact x))))))
               (cons "lexical error: " (lambda (text) '(rejected)))
               (cons "parse error: " (lambda (text) '(rejected)))
               (cons "memory leaks:\t" (lambda (text) 'none)))))

  (define value-lines
    (list (cons (utf8 "string: '") 'string)
          (cons (utf8 "key: '") 'key)))

  (define newline-byte (utf8 "\n"))
  (define quote-newline (utf8 "'\n"))

  ;; EVENT, none or #f, before REST, a list of events or #f: #f when either
  ;; is.
  (define (then event rest)
    (cond ((not (and event rest)) #f)
          ((eq? event 'none) rest)
          (else (cons event rest))))

  (define (prefixed lines bv i)
    (find (lambda (l) (starts-with? bv i (car l))) lines))

  ;; The events of BV from I, or #f if it does not read from there.
  (define (read-gold bv i)
    (if (= i (bytevector-length bv))
        '()
        (cond
         ((prefixed fixed-lines bv i)
          => (lambda (l)
               (then (cdr l) (read-gold bv (+ i (bytevector-length (car l)))))))
         ((prefixed text-lines bv i)
          => (lambda (l)
               (let* ((from (+ i (bytevector-length (car l))))
                      (end (search bv newline-byte from)))
                 (and end
                      (then ((cdr l) (utf8->string (sub bv from end)))
                            (read-gold bv (+ end 1)))))))
         ((prefixed value-lines bv i)
          => (lambda (l)
               (let ((from (+ i (bytevector-length (car l)))))
                 (let try ((at from))
                   (let ((end (search bv quote-newline at)))
                     (and end
                          (or (then (list (cdr l) (sub bv from end))
                                    (read-gold bv (+ end 2)))
                              (try (+ end 1)))))))))
         (else #f))))

  ;; gold-events : Bytevector -> (Listof Event)
  ;; The events of a gold file's bytes BV. Raises if a line is none of
  ;; yajl_test's.
  (define (gold-events bv)
    (or (read-gold bv 0)
        (assertion-violation 'gold-events "not a yajl gold file" bv)))

  ;; --- the trace --------------------------------------------------------------
  ;;
  ;; A key or string is printed when it closes, a number when it ends, so one
  ;; an error cuts short is left out: only a closing event emits the text
  ;; gathered since its start.

  (define simple-events
    '((object-start map-open) (object-end map-close)
      (array-start array-open) (array-end array-close)
      (true bool #t) (false bool #f) (null null)))

  (define (code-point-bytes cp)
    (string->utf8 (string (integer->char cp))))

  (define (high-surrogate? cp) (<= #xD800 cp #xDBFF))

  (define (pair-code-point high low)
    (+ #x10000 (* (- high #xD800) #x400) (- low #xDC00)))

  ;; A number with no fraction and no exponent is an integer, as yajl
  ;; classifies it.
  (define (number-event bv)
    (let ((text (utf8->string bv)))
      (if (exists (lambda (c) (memv c '(#\. #\e #\E))) (string->list text))
          (list 'double (inexact (string->number text)))
          (list 'integer text))))

  (define (outcome-events outcome)
    (case (car outcome)
      ((accepted) '())
      ((rejected) '((rejected)))
      (else (list outcome))))

  (define (ignored? x)
    (and (pair? x) (memq (car x) '(context feed finish))))

  ;; trace-events : Trace -> (Listof Event)
  ;; The events of TRACE, a run-machine trace, as yajl_test would print
  ;; them: a chars fragment or an escape is part of its key or string, an
  ;; escape a UTF-16 code unit, so a high surrogate waits for its low half;
  ;; a number is an integer or a double by its text; a key, string or number
  ;; an error cuts short is left out; and a rejected outcome ends the list
  ;; with (rejected). An outcome neither accepted nor rejected ends it as
  ;; itself, (other STATUS), which no gold holds. Raises on an entry that is
  ;; none of run-machine's.
  (define (trace-events trace)
    (let loop ((xs trace) (out '()) (text '()) (high #f))
      (if (null? xs)
          (reverse (append (outcome-events (trace-outcome trace)) out))
          (let ((x (car xs)) (next (cdr xs)))
            (define (emit event) (loop next (cons event out) '() #f))
            (define (gather bv high) (loop next out (cons bv text) high))
            (cond
             ((assq x simple-events) => (lambda (e) (emit (cdr e))))
             ((memq x '(key-start string-start)) (loop next out '() #f))
             ((eq? x 'key-end) (emit (list 'key (concat (reverse text)))))
             ((eq? x 'string-end) (emit (list 'string (concat (reverse text)))))
             ((eq? x 'number-end) (emit (number-event (concat (reverse text)))))
             ((and (pair? x) (memq (car x) '(chars number))) (gather (cadr x) high))
             ((and (pair? x) (eq? (car x) 'escape))
              (let ((cp (cadr x)))
                (cond (high (gather (code-point-bytes (pair-code-point high cp)) #f))
                      ((high-surrogate? cp) (loop next out text cp))
                      (else (gather (code-point-bytes cp) #f)))))
             ((ignored? x) (loop next out text high))
             (else (assertion-violation 'trace-events "not a trace entry" x)))))))

  ;; --- comparing --------------------------------------------------------------

  ;; The exact decimal exponent of a positive exact rational Q: the E with
  ;; 10^E <= Q < 10^(E+1).
  (define (decimal-exponent q)
    (let loop ((e (exact (floor (/ (log (inexact q)) (log 10))))))
      (cond ((< q (expt 10 e)) (loop (- e 1)))
            ((>= q (expt 10 (+ e 1))) (loop (+ e 1)))
            (else e))))

  ;; What %g prints of X, as data: its sign, its six significant digits and
  ;; its exponent. glibc rounds X's exact binary value to nearest, ties to
  ;; even, as `round` does an exact rational. A zero, an infinity or a NaN
  ;; stands for itself: %g prints 0 and -0 apart.
  (define (g-form x)
    (if (or (zero? x) (infinite? x) (nan? x))
        x
        (let* ((q (abs (exact x)))
               (e (decimal-exponent q))
               (m (round (/ q (expt 10 (- e 5))))))
          (if (= m 1000000)
              (list (negative? x) 100000 (+ e 1))
              (list (negative? x) m e)))))

  ;; same-double? : Real Real -> Boolean
  ;; Whether %g prints A and B alike, at six significant digits: 3.141569
  ;; and 3.14157 are alike, 3.1416 and 3.14157 are not.
  (define (same-double? a b)
    (equal? (g-form a) (g-form b)))

  (define (same-event? a b)
    (if (and (eq? (car a) 'double) (eq? (car b) 'double))
        (same-double? (cadr a) (cadr b))
        (equal? a b)))

  ;; same-events? : (Listof Event) (Listof Event) -> Boolean
  ;; Whether A and B hold alike events in order: doubles by same-double?,
  ;; every other event by equal?.
  (define (same-events? a b)
    (and (= (length a) (length b))
         (for-all same-event? a b)))

  ;; events-prefix? : (Listof Event) (Listof Event) -> Boolean
  ;; Whether A is alike, as by same-events?, to the first (length A) events
  ;; of B.
  (define (events-prefix? a b)
    (and (<= (length a) (length b))
         (let loop ((a a) (b b))
           (or (null? a)
               (and (same-event? (car a) (car b))
                    (loop (cdr a) (cdr b))))))))
