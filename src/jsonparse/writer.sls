#!r6rs
;;; (jsonparse writer): writes a value as JSON, in UTF-8, to a binary port
;;; (ADR-0007, ADR-0010, ADR-0011, ADR-0018, ADR-0019).
;;;
;;;   (put-json port '(("a" . #(1 null))))            ; {"a":[1,null]}
;;;   (put-json port v (make-json-options 'indent 2))  ; laid out, 2 spaces
;;;
;;; It writes the values (jsonparse tree) builds, under any options:
;;;
;;;   object        an alist of (key . value) pairs, every duplicate
;;;                 written in order; or a hashtable, its members in the
;;;                 order of their keys, no two with the same text. '() is
;;;                 {}. A key is a string
;;;   array         a vector
;;;   string        a string, with ", \ and the control characters escaped,
;;;                 and every other character as itself, in UTF-8
;;;   number        an exact integer in decimal, a fixnum's digits
;;;                 written directly; a finite flonum as
;;;                 number->string writes it, less any |width suffix; an
;;;                 exact non-integer as a decimal, which needs its
;;;                 denominator to have no prime factor but 2 and 5; a
;;;                 json-number as its text
;;;   true, false   #t, #f
;;;   null          the options' null, recognised by eq?
;;;
;;; It refuses anything else, raising a &json-error whose offset is #f, with
;;; a who, a message and one irritant, the part refused: the number, the
;;; key, the member that is not a pair, the list, the value, or the
;;; container that went too deep. The reason is one of:
;;;
;;;   unwritable-number  NaN, an infinity, a complex number, or an exact
;;;                      fraction with no finite decimal, such as 1/3
;;;   unwritable-key     an object member whose key is not a string, or a
;;;                      hashtable holding two keys with the same text
;;;   unwritable-value   anything else: a symbol other than the null in
;;;                      force, a list that is not an alist (improper,
;;;                      circular, or with a member that is not a pair), a
;;;                      character, a bytevector, a procedure, a record that
;;;                      is neither a json-number nor the null
;;;   nesting-too-deep   more arrays and objects open at once than the
;;;                      options' depth-limit, as the reader would refuse;
;;;                      a value that contains itself ends here too
;;;
;;; A value is checked whole before a byte is written, so a refusal leaves
;;; the port as it was. The check walks the value as the writing does, with
;;; the same code, and costs a second walk. check-json runs the check
;;; alone (ADR-0019).
;;;
;;; The options' indent lays the value out (ADR-0018). The writer reads
;;; null, depth-limit and indent, and ignores the reader's options.
(library (jsonparse writer)
  (export put-json check-json)
  (import (rnrs)
          (jsonparse error)
          (jsonparse options)
          (jsonparse string))

  ;; --- numbers ----------------------------------------------------------------

  ;; The flonum's text, less the |width suffix Chez gives subnormals.
  (define (flonum-text x)
    (let* ((s (number->string x))
           (n (string-length s)))
      (let loop ((i 0))
        (cond ((fx=? i n) s)
              ((char=? (string-ref s i) #\|) (substring s 0 i))
              (else (loop (fx+ i 1)))))))

  ;; What is left of N, positive, once every factor K is taken out, and how
  ;; many there were.
  (define (strip n k)
    (let loop ((n n) (count 0))
      (let-values (((q r) (div-and-mod n k)))
        (if (zero? r)
            (loop q (+ count 1))
            (values n count)))))

  ;; The places after the point an exact non-integer X needs, or #f if its
  ;; decimal never ends.
  (define (decimal-places x)
    (let-values (((rest twos) (strip (denominator x) 2)))
      (let-values (((rest fives) (strip rest 5)))
        (and (= rest 1) (max twos fives)))))

  ;; X, exact, not an integer, with a finite decimal of K places.
  (define (decimal-text x k)
    (let* ((digits (number->string (abs (* x (expt 10 k)))))
           (padded (if (> (string-length digits) k)
                       digits
                       (string-append (make-string (- (+ k 1) (string-length digits)) #\0)
                                      digits)))
           (point (- (string-length padded) k)))
      (string-append (if (negative? x) "-" "")
                     (substring padded 0 point)
                     "."
                     (substring padded point (string-length padded)))))

  ;; The text of X, or #f if JSON can't express it.
  (define (number-text x)
    (cond ((not (real? x)) #f)
          ((exact? x)
           (if (integer? x)
               (number->string x)
               (let ((k (decimal-places x)))
                 (and k (decimal-text x k)))))
          ((or (nan? x) (infinite? x)) #f)
          (else (flonum-text x))))

  ;; Whether JSON can express X: number-text, without building the text.
  (define (writable-number? x)
    (and (real? x)
         (if (exact? x)
             (or (integer? x) (and (decimal-places x) #t))
             (not (or (nan? x) (infinite? x))))))

  ;; How many digits the greatest fixnum has: R6RS sets only a least width
  ;; for fixnums.
  (define fixnum-digits (string-length (number->string (greatest-fixnum))))

  ;; Writes the fixnum N in decimal, its digits laid out from the end of
  ;; DIGITS, a bytevector of fixnum-digits bytes: as number->string would,
  ;; without making a string. The least fixnum has no positive twin, so it
  ;; goes through number->string.
  (define (put-fixnum port n digits)
    (if (fx=? n (least-fixnum))
        (put-bytevector port (string->utf8 (number->string n)))
        (begin
          (when (fx<? n 0) (put-u8 port 45))
          (let ((width (bytevector-length digits)))
            (let loop ((m (if (fx<? n 0) (fx- 0 n) n)) (i width))
              (let ((i (fx- i 1)))
                (bytevector-u8-set! digits i (fx+ 48 (fxmod m 10)))
                (let ((q (fxdiv m 10)))
                  (if (fx=? q 0)
                      (put-bytevector port digits i (fx- width i))
                      (loop q i)))))))))

  ;; --- strings ----------------------------------------------------------------

  (define (escape-byte c)
    (case c
      ((#\") 34) ((#\\) 92) ((#\backspace) 98) ((#\page) 102)
      ((#\newline) 110) ((#\return) 114) ((#\tab) 116)
      (else #f)))

  (define (needs-escape? c)
    (or (char<? c #\space) (char=? c #\") (char=? c #\\)))

  (define hex (string->utf8 "0123456789abcdef"))

  (define (put-escape port c)
    (put-u8 port 92)
    (let ((b (escape-byte c)))
      (if b
          (put-u8 port b)
          (let ((n (char->integer c)))
            (put-bytevector port (string->utf8 "u00"))
            (put-u8 port (bytevector-u8-ref hex (fxarithmetic-shift-right n 4)))
            (put-u8 port (bytevector-u8-ref hex (fxand n 15)))))))

  (define (put-json-string port s)
    (let ((n (string-length s)))
      (put-u8 port 34)
      (let loop ((i 0) (from 0))
        (cond ((fx=? i n)
               (put-bytevector port (string->utf8 (if (fx=? from 0) s (substring s from n)))))
              ((needs-escape? (string-ref s i))
               (unless (fx=? from i)
                 (put-bytevector port (string->utf8 (substring s from i))))
               (put-escape port (string-ref s i))
               (loop (fx+ i 1) (fx+ i 1)))
              (else (loop (fx+ i 1) from))))
      (put-u8 port 34)))

  ;; --- the walk ---------------------------------------------------------------

  (define (refuse who reason message v)
    (raise (condition (make-json-error reason #f)
                      (make-who-condition who)
                      (make-message-condition message)
                      (make-irritants-condition (list v)))))

  (define literal-true (string->utf8 "true"))
  (define literal-false (string->utf8 "false"))
  (define literal-null (string->utf8 "null"))

  ;; A hashtable's members as (key . value) pairs, in the order of their
  ;; keys. Refuses a key that is not a string, the first in the
  ;; hashtable's own order. Refuses two keys with the same text, which a
  ;; table not keyed by string=? can hold: they have no order but the
  ;; table's own.
  (define (sorted-members who h)
    (let-values (((keys values) (hashtable-entries h)))
      (vector-for-each
       (lambda (k)
         (unless (string? k)
           (refuse who 'unwritable-key "an object's key is not a string" k)))
       keys)
      (let ((members (list-sort (lambda (a b) (string<? (car a) (car b)))
                                (map cons (vector->list keys) (vector->list values)))))
        (let loop ((ms members))
          (when (and (pair? ms) (pair? (cdr ms)))
            (when (string=? (caar ms) (caadr ms))
              (refuse who 'unwritable-key "a hashtable holds two keys with the same text" (caar ms)))
            (loop (cdr ms))))
        members)))

  ;; An alist's members, refused unless they make a proper list of pairs
  ;; whose keys are strings.
  (define (alist-members who v)
    (unless (list? v)
      (refuse who 'unwritable-value "a list that is not an alist: it is improper or circular" v))
    (for-each
     (lambda (m)
       (unless (pair? m)
         (refuse who 'unwritable-value "a list that is not an alist: a member is not a pair" m))
       (unless (string? (car m))
         (refuse who 'unwritable-key "an object's key is not a string" (car m))))
     v)
    v)

  ;; walk : Symbol (U Binary-Output-Port #f) Boolean Any json-options -> Void
  ;; Writes V to PORT when EMIT? is true; otherwise only checks it, and
  ;; touches no port. Either way raises for what JSON can't express, with
  ;; WHO as the who.
  (define (walk who port emit? v options)
    (define null (json-options-null options))
    (define limit (json-options-depth-limit options))
    (define indent (json-options-indent options))

    ;; put-fixnum's scratch, one per call, so no two writes share it.
    (define digits (and emit? (make-bytevector fixnum-digits)))

    (define (put-byte b) (when emit? (put-u8 port b)))
    (define (put-bytes bv) (when emit? (put-bytevector port bv)))

    ;; A new line, indented for DEPTH, when laid out.
    (define (break depth)
      (when (and emit? (fx>? indent 0))
        (put-u8 port 10)
        (do ((i (* indent depth) (- i 1))) ((= i 0))
          (put-u8 port 32))))

    ;; Opens the container X, which puts DEPTH containers open, with the
    ;; byte OPEN.
    (define (open x open depth)
      (when (fx>? depth limit)
        (refuse who 'nesting-too-deep "more arrays and objects open at once than depth-limit" x))
      (put-byte open))

    ;; Before a member at DEPTH: a comma unless it is the first, and a new
    ;; line when laid out.
    (define (next first? depth)
      (unless first? (put-byte 44))
      (break depth))

    ;; Closes a container at DEPTH with the byte CLOSE, on its own line when
    ;; it had members and is laid out.
    (define (close close depth empty?)
      (unless empty? (break (fx- depth 1)))
      (put-byte close))

    (define (array x depth)
      (let ((n (vector-length x)))
        (open x 91 depth)
        (do ((i 0 (fx+ i 1))) ((fx=? i n))
          (next (fx=? i 0) depth)
          (value (vector-ref x i) depth))
        (close 93 depth (fx=? n 0))))

    ;; MEMBERS is a list of (key . value) pairs, keys strings.
    (define (object x members depth)
      (open x 123 depth)
      (let loop ((ms members) (first? #t))
        (unless (null? ms)
          (next first? depth)
          (when emit? (put-json-string port (caar ms)))
          (put-byte 58)
          (when (fx>? indent 0) (put-byte 32))
          (value (cdar ms) depth)
          (loop (cdr ms) #f)))
      (close 125 depth (null? members)))

    (define (value x depth)
      (cond ((string? x) (when emit? (put-json-string port x)))
            ((eq? x null) (put-bytes literal-null))
            ((eq? x #t) (put-bytes literal-true))
            ((eq? x #f) (put-bytes literal-false))
            ((vector? x) (array x (fx+ depth 1)))
            ((or (pair? x) (null? x)) (object x (alist-members who x) (fx+ depth 1)))
            ((and emit? (fixnum? x)) (put-fixnum port x digits))
            ((number? x)
             (if emit?
                 (put-bytes (string->utf8 (number-text x)))
                 (unless (writable-number? x)
                   (refuse who 'unwritable-number "a number JSON can't express" x))))
            ((hashtable? x) (object x (sorted-members who x) (fx+ depth 1)))
            ((json-number? x) (when emit? (put-bytes (string->utf8 (json-number-text x)))))
            (else (refuse who 'unwritable-value "a value JSON can't express" x))))

    (value v 0))

  (define default-options (make-json-options))

  ;; put-json : Binary-Output-Port Any [json-options] -> Void
  ;; Writes V to PORT as JSON in UTF-8, under OPTIONS (default
  ;; (make-json-options)). Raises a &json-error, before writing a byte, if
  ;; JSON can't express V. Raises an assertion violation if PORT is not a
  ;; binary output port or OPTIONS not an options record.
  (define put-json
    (case-lambda
      ((port v) (put-json port v default-options))
      ((port v options)
       (unless (and (output-port? port) (binary-port? port))
         (assertion-violation 'put-json "not a binary output port" port))
       (unless (json-options? options)
         (assertion-violation 'put-json "not an options record" options))
       (walk 'put-json port #f v options)
       (walk 'put-json port #t v options))))

  ;; check-json : Any [json-options] -> Void
  ;; Raises the &json-error put-json would raise for V under OPTIONS
  ;; (default (make-json-options)), with check-json as its who, and writes
  ;; nothing (ADR-0019). Raises an assertion violation if OPTIONS is not an
  ;; options record.
  (define check-json
    (case-lambda
      ((v) (check-json v default-options))
      ((v options)
       (unless (json-options? options)
         (assertion-violation 'check-json "not an options record" options))
       (walk 'check-json #f #f v options)))))
