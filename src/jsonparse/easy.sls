#!r6rs
;;; (jsonparse easy): whole documents and streams of them in, values out,
;;; and back again (ADR-0010, ADR-0019, ADR-0020).
;;;
;;;   (string->json "{\"a\": [1, null]}")     ; => (("a" . #(1 null)))
;;;   (json->string '(("a" . #(1 null))))     ; => "{\"a\":[1,null]}"
;;;   (json-ref v "users" 0 "name")
;;;
;;; string->json, bytevector->json and read-json take one whole document,
;;; from a string, a bytevector, or a binary input port read to its end.
;;; Each returns what (jsonparse tree) builds, under the options given
;;; last, (make-json-options) by default.
;;; Bad input raises a &json-error:
;;;
;;;   reason   the parser's code, such as unexpected-byte or number-too-long
;;;   offset   where: in characters for a string, the characters before the
;;;            byte the parser stopped at; in bytes for a bytevector, and
;;;            for a port from where the port was
;;;
;;; Its who is the procedure called, its message reads
;;; "unexpected-byte at character 12", or "at byte 12", and its irritants
;;; are an empty list. Every raise here is non-continuable.
;;;
;;; Writing is (jsonparse writer)'s put-json, to a bytevector, a string or
;;; a binary output port. A value JSON can't express raises put-json's
;;; &json-error, its offset #f, again with the easy procedure as its who.
;;; What a caller's port raises passes through as it was raised.
;;;
;;; Streams of many values, framed as the options' stream says: lines, the
;;; default, seq or values (ADR-0014, ADR-0020):
;;;
;;;   (bytevector->json-sequence (string->utf8 "1\n[2]\n"))   ; => (1 #(2))
;;;   (fold-json-sequence cons '() port)                       ; the values, last first
;;;   (write-json-sequence port '(1 #(2)))                      ; 1, newline, [2], newline
;;;
;;; A bad record raises a &json-record-error: a &json-error whose offset
;;; counts bytes from the start of the stream, and whose record is the bad
;;; record's number, from 1. Given REPORT, a reader skips bad records
;;; instead, and calls REPORT with the &json-record-error for each, which
;;; REPORT may raise to stop. Stream seq needs REPORT, and stream values
;;; refuses it.
;;;
;;; json-ref follows a path of keys and indices:
;;;
;;;   (json-ref v "users" 0 "name")                   ; raises not-found if missing
;;;   (json-ref v "users" 0 "name" 'default "anon")   ; "anon" if missing
;;;
;;; json=? asks whether two values mean the same JSON: objects as unordered
;;; members, the last duplicate winning, and numbers by exact value.
;;; json-null? asks whether a value is the options' null.
;;;
;;; A wrong argument, such as a number where a string goes, raises an
;;; assertion violation.
;;;
;;; This library imports only (rnrs ...) and (jsonparse ...) libraries, and
;;; nothing under src/ imports it (ADR-0010).
(library (jsonparse easy)
  (export string->json bytevector->json read-json
          json->string json->bytevector write-json
          read-json-sequence bytevector->json-sequence fold-json-sequence
          write-json-sequence json-sequence->bytevector
          json-ref json=? json-null?
          &json-error json-error? json-error-reason json-error-offset
          &json-record-error json-record-error? json-error-record
          make-json-options json-options?
          make-json-number json-number? json-number-text)
  (import (rnrs)
          (jsonparse error)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse sequence)
          (jsonparse string)
          (jsonparse tree)
          (jsonparse writer))

  (define default-options (make-json-options))

  (define (check-options who options)
    (unless (json-options? options)
      (assertion-violation who "not an options record" options)))

  ;; A reader of one document refuses stream values, which holds many.
  (define (check-one-document who options)
    (check-options who options)
    (when (eq? (json-options-stream options) 'values)
      (assertion-violation who "stream values holds many values: read it with read-json-sequence")))

  ;; --- reading ----------------------------------------------------------------

  ;; Raises the &json-error for the error result R, at OFFSET counted in
  ;; UNIT.
  (define (refuse-input who r offset unit)
    (let ((reason (json-result-code r)))
      (raise (condition (make-json-error reason offset)
                        (make-who-condition who)
                        (make-message-condition
                         (string-append (symbol->string reason) " at " unit " "
                                        (number->string offset)))
                        (make-irritants-condition '())))))

  ;; Reads BV whole with a new builder. Returns the value and #f, or #f and
  ;; the error result.
  (define (build bv options)
    (let* ((b (make-json-builder options))
           (r (json-builder-feed! b bv))
           (r (if (eq? (json-result-status r) 'error) r (json-builder-finish! b))))
      (if (eq? (json-result-status r) 'finished)
          (values (json-builder-value b) #f)
          (values #f r))))

  ;; The characters of the UTF-8 BV before byte I: the bytes before it that
  ;; begin a character, which is every byte but a 10xxxxxx continuation.
  ;; On valid UTF-8 the parser's errors land on a character's first byte,
  ;; or at the end (ADR-0019).
  (define (char-offset bv i)
    (let loop ((j 0) (n 0))
      (if (fx=? j i)
          n
          (loop (fx+ j 1)
                (if (fx=? (fxand (bytevector-u8-ref bv j) #xC0) #x80) n (fx+ n 1))))))

  ;; string->json : String [json-options] -> Any
  ;; The value of the JSON document S. Raises a &json-error whose offset
  ;; counts characters if S is not one.
  (define string->json
    (case-lambda
      ((s) (string->json s default-options))
      ((s options)
       (unless (string? s)
         (assertion-violation 'string->json "not a string" s))
       (check-one-document 'string->json options)
       (let ((bv (string->utf8 s)))
         (let-values (((v r) (build bv options)))
           (if r
               (refuse-input 'string->json r (char-offset bv (json-result-offset r)) "character")
               v))))))

  ;; bytevector->json : Bytevector [json-options] -> Any
  ;; The value of the JSON document in BV, as UTF-8. Raises a &json-error
  ;; whose offset counts bytes if BV does not hold one.
  (define bytevector->json
    (case-lambda
      ((bv) (bytevector->json bv default-options))
      ((bv options)
       (unless (bytevector? bv)
         (assertion-violation 'bytevector->json "not a bytevector" bv))
       (check-one-document 'bytevector->json options)
       (let-values (((v r) (build bv options)))
         (if r
             (refuse-input 'bytevector->json r (json-result-offset r) "byte")
             v)))))

  (define chunk-size 16384)

  ;; read-json : Binary-Input-Port [json-options] -> Any
  ;; The value of the JSON document PORT holds, read to its end, 16 KiB at
  ;; a time. Raises a &json-error whose offset counts bytes from where PORT
  ;; was if it holds no document, and reads no further than the end of the
  ;; 16 KiB that hold the error.
  (define read-json
    (case-lambda
      ((port) (read-json port default-options))
      ((port options)
       (unless (and (input-port? port) (binary-port? port))
         (assertion-violation 'read-json "not a binary input port" port))
       (check-one-document 'read-json options)
       (let ((b (make-json-builder options))
             (buf (make-bytevector chunk-size)))
         (let loop ()
           (let* ((n (get-bytevector-n! port buf 0 chunk-size))
                  (r (if (eof-object? n)
                         (json-builder-finish! b)
                         (json-builder-feed! b buf 0 n))))
             (case (json-result-status r)
               ((finished) (json-builder-value b))
               ((error) (refuse-input 'read-json r (json-result-offset r) "byte"))
               (else (loop)))))))))

  ;; --- writing ----------------------------------------------------------------

  ;; THUNK's value. THUNK runs only the writer's own walk, never a port of
  ;; the caller's, so a &json-error it raises is a refusal of the writer's,
  ;; with a message and irritants. It is raised again with WHO as its who,
  ;; keeping its reason, offset, message and irritants.
  (define (as who thunk)
    (guard (e ((json-error? e)
               (raise (condition (make-json-error (json-error-reason e) (json-error-offset e))
                                 (make-who-condition who)
                                 (make-message-condition (condition-message e))
                                 (make-irritants-condition (condition-irritants e))))))
      (thunk)))

  (define (written who v options)
    (let-values (((port get) (open-bytevector-output-port)))
      (as who (lambda () (put-json port v options)))
      (get)))

  ;; json->bytevector : Any [json-options] -> Bytevector
  ;; V as JSON, in UTF-8. Raises a &json-error if JSON can't express V.
  (define json->bytevector
    (case-lambda
      ((v) (json->bytevector v default-options))
      ((v options)
       (check-options 'json->bytevector options)
       (written 'json->bytevector v options))))

  ;; json->string : Any [json-options] -> String
  ;; V as JSON. Raises a &json-error if JSON can't express V.
  (define json->string
    (case-lambda
      ((v) (json->string v default-options))
      ((v options)
       (check-options 'json->string options)
       ;; utf8->string drops a leading U+FEFF (ADR-0016), but JSON text
       ;; starts with " { [ - a digit or a letter.
       (utf8->string (written 'json->string v options)))))

  ;; write-json : Binary-Output-Port Any [json-options] -> Void
  ;; Writes V to PORT as JSON in UTF-8, as put-json does. Raises a
  ;; &json-error, before writing a byte, if JSON can't express V. What
  ;; PORT itself raises passes through as it was raised.
  (define write-json
    (case-lambda
      ((port v) (write-json port v default-options))
      ((port v options)
       (unless (and (output-port? port) (binary-port? port))
         (assertion-violation 'write-json "not a binary output port" port))
       (check-options 'write-json options)
       ;; The check alone is relabelled: PORT's write! runs caller code.
       (as 'write-json (lambda () (check-json v options)))
       (put-json port v options))))

;; --- streams of values -------------------------------------------------------

  ;; The &json-record-error for record RECORD, bad for CODE at OFFSET.
  (define (record-error who code record offset)
    (condition (make-json-record-error code offset record)
               (make-who-condition who)
               (make-message-condition
                (string-append (symbol->string code) " at byte " (number->string offset)
                               " in record " (number->string record)))
               (make-irritants-condition '())))

  (define (check-report who report options)
    (unless (or (not report) (procedure? report))
      (assertion-violation who "not a procedure or #f" report))
    (check-options who options)
    (case (json-options-stream options)
      ((seq)
       (unless report
         (assertion-violation who "stream seq skips bad records, so it needs a procedure to report them to")))
      ((values)
       (when report
         (assertion-violation who "stream values can't skip a bad value: nothing marks where the next begins"
                              report)))
      (else #f)))

  ;; Folds KONS over the values of a stream with a new reader. FEED is
  ;; called with a procedure that feeds the reader the bytes of a
  ;; bytevector from START below END, and feeds it the whole stream.
  (define (fold-stream who kons knil report options feed)
    (let* ((acc knil)
           (r (make-json-reader
               (lambda (v) (set! acc (kons v acc)))
               (and report
                    (lambda (code record offset)
                      (report (record-error who code record offset))))
               options)))
      (define (refuse-if-error res)
        (when (eq? (json-result-status res) 'error)
          (raise (record-error who (json-result-code res) (json-reader-record r)
                               (json-result-offset res)))))
      (feed (lambda (bv start end) (refuse-if-error (json-reader-feed! r bv start end))))
      (refuse-if-error (json-reader-finish! r))
      acc))

  ;; Feeds a reader PORT's bytes as they come: get-bytevector-some answers
  ;; as soon as any are ready, so a value goes on once its record has come.
  (define (port-feed port)
    (lambda (feed!)
      (let loop ()
        (let ((bv (get-bytevector-some port)))
          (unless (eof-object? bv)
            (feed! bv 0 (bytevector-length bv))
            (loop))))))

  (define (check-input-port who port)
    (unless (and (input-port? port) (binary-port? port))
      (assertion-violation who "not a binary input port" port)))

  ;; fold-json-sequence : (Any a -> a) a Binary-Input-Port [(U #f (&json-record-error -> Any))] [json-options] -> a
  ;; Folds KONS over the values of the stream PORT holds, read to its end:
  ;; (KONS value acc), from KNIL, in stream order. Each value is folded in
  ;; as soon as its record has been read.
  (define fold-json-sequence
    (case-lambda
      ((kons knil port) (fold-json-sequence kons knil port #f default-options))
      ((kons knil port x)
       (if (json-options? x)
           (fold-json-sequence kons knil port #f x)
           (fold-json-sequence kons knil port x default-options)))
      ((kons knil port report options)
       (unless (procedure? kons)
         (assertion-violation 'fold-json-sequence "not a procedure" kons))
       (check-input-port 'fold-json-sequence port)
       (check-report 'fold-json-sequence report options)
       (fold-stream 'fold-json-sequence kons knil report options (port-feed port)))))

  ;; read-json-sequence : Binary-Input-Port [(U #f (&json-record-error -> Any))] [json-options] -> (Listof Any)
  ;; The values of the stream PORT holds, read to its end.
  (define read-json-sequence
    (case-lambda
      ((port) (read-json-sequence port #f default-options))
      ((port x)
       (if (json-options? x)
           (read-json-sequence port #f x)
           (read-json-sequence port x default-options)))
      ((port report options)
       (check-input-port 'read-json-sequence port)
       (check-report 'read-json-sequence report options)
       (reverse (fold-stream 'read-json-sequence cons '() report options (port-feed port))))))

  ;; bytevector->json-sequence : Bytevector [(U #f (&json-record-error -> Any))] [json-options] -> (Listof Any)
  ;; The values of the stream in BV.
  (define bytevector->json-sequence
    (case-lambda
      ((bv) (bytevector->json-sequence bv #f default-options))
      ((bv x)
       (if (json-options? x)
           (bytevector->json-sequence bv #f x)
           (bytevector->json-sequence bv x default-options)))
      ((bv report options)
       (unless (bytevector? bv)
         (assertion-violation 'bytevector->json-sequence "not a bytevector" bv))
       (check-report 'bytevector->json-sequence report options)
       (reverse (fold-stream 'bytevector->json-sequence cons '() report options
                             (lambda (feed!) (feed! bv 0 (bytevector-length bv))))))))

  (define (check-records who vs options)
    (unless (list? vs)
      (assertion-violation who "not a list" vs))
    (check-options who options)
    (when (and (eq? (json-options-stream options) 'lines)
               (not (eqv? (json-options-indent options) 0)))
      (assertion-violation who "a lines record is written compact, so indent must be 0"
                           (json-options-indent options))))

  ;; write-json-sequence : Binary-Output-Port (Listof Any) [json-options] -> Void
  ;; Writes each of VS to PORT as one record of the options' stream, as
  ;; put-json-record does. Raises a &json-error, before writing any byte of
  ;; its record, at the first value JSON can't express: the records before
  ;; it stay written. What PORT itself raises passes through as it was
  ;; raised.
  (define write-json-sequence
    (case-lambda
      ((port vs) (write-json-sequence port vs default-options))
      ((port vs options)
       (unless (and (output-port? port) (binary-port? port))
         (assertion-violation 'write-json-sequence "not a binary output port" port))
       (check-records 'write-json-sequence vs options)
       (for-each (lambda (v)
                   ;; The check alone is relabelled: PORT's write! runs caller code.
                   (as 'write-json-sequence (lambda () (check-json v options)))
                   (put-json-record port v options))
                 vs))))

  ;; json-sequence->bytevector : (Listof Any) [json-options] -> Bytevector
  ;; VS as a stream of the options' format, in UTF-8. Raises a &json-error
  ;; if JSON can't express one of them.
  (define json-sequence->bytevector
    (case-lambda
      ((vs) (json-sequence->bytevector vs default-options))
      ((vs options)
       (check-records 'json-sequence->bytevector vs options)
       (let-values (((port get) (open-bytevector-output-port)))
         (as 'json-sequence->bytevector
             (lambda () (for-each (lambda (v) (put-json-record port v options)) vs)))
         (get)))))

  ;; --- json-ref ---------------------------------------------------------------

  ;; What a lookup gives when it finds no value.
  (define missing (list 'missing))

  (define (refuse-value reason message v)
    (raise (condition (make-json-error reason #f)
                      (make-who-condition 'json-ref)
                      (make-message-condition message)
                      (make-irritants-condition (list v)))))

  ;; The value of ALIST's last member whose key is KEY, or missing.
  (define (alist-ref alist key)
    (unless (list? alist)
      (refuse-value 'unwritable-value "a list that is not an alist: it is improper or circular" alist))
    (let loop ((ms alist) (found missing))
      (if (null? ms)
          found
          (let ((m (car ms)))
            (unless (pair? m)
              (refuse-value 'unwritable-value "a list that is not an alist: a member is not a pair" m))
            (loop (cdr ms)
                  (if (and (string? (car m)) (string=? (car m) key)) (cdr m) found))))))

  ;; The value of TABLE's key whose text is KEY, or missing.
  (define (table-ref table key)
    (let ((same? (hashtable-equivalence-function table)))
      (if (or (eq? same? string=?) (eq? same? equal?))
          (hashtable-ref table key missing)
          (let-values (((keys values) (hashtable-entries table)))
            (let loop ((i 0) (found missing))
              (if (fx=? i (vector-length keys))
                  found
                  (let ((k (vector-ref keys i)))
                    (cond ((not (and (string? k) (string=? k key))) (loop (fx+ i 1) found))
                          ((eq? found missing) (loop (fx+ i 1) (vector-ref values i)))
                          (else (refuse-value 'unwritable-key
                                              "a hashtable holds two keys with the same text"
                                              key))))))))))

  (define (step-into v step)
    (cond ((string? step)
           (cond ((hashtable? v) (table-ref v step))
                 ((or (pair? v) (null? v)) (alist-ref v step))
                 (else missing)))
          ((vector? v)
           (if (< step (vector-length v)) (vector-ref v step) missing))
          (else missing)))

  (define (step? x)
    (or (string? x) (and (integer? x) (exact? x) (>= x 0))))

  ;; ARGS split into the steps and the default: the value after a 'default
  ;; that is second to last, or missing.
  (define (steps-and-default args)
    (let ((n (length args)))
      (cond ((and (>= n 2) (eq? (list-ref args (- n 2)) 'default))
             (values (list-head args (- n 2)) (list-ref args (- n 1))))
            ((and (>= n 1) (eq? (list-ref args (- n 1)) 'default))
             (assertion-violation 'json-ref "'default needs a value after it"))
            (else (values args missing)))))

  (define (list-head xs k)
    (if (= k 0) '() (cons (car xs) (list-head (cdr xs) (- k 1)))))

  ;; json-ref : Any (U String Natural) ... ['default Any] -> Any
  ;; The value at the end of the path of STEPS from V: a string steps into
  ;; an object to its member with that key, the last if there are several;
  ;; an exact nonnegative integer steps into an array. If a step finds no
  ;; value, gives the value after 'default when the call ends with one, and
  ;; otherwise raises a &json-error whose reason is not-found and whose
  ;; irritant is the steps taken. Members with other keys, strings or not,
  ;; are passed over. Every step is checked before the walk starts.
  (define (json-ref v . args)
    (let-values (((steps default) (steps-and-default args)))
      (for-each (lambda (step)
                  (unless (step? step)
                    (assertion-violation 'json-ref
                                         "a step is neither a string nor an exact nonnegative integer"
                                         step)))
                steps)
      (let loop ((v v) (steps steps) (taken '()))
        (if (null? steps)
            v
            (let ((x (step-into v (car steps)))
                  (taken (cons (car steps) taken)))
              (cond ((not (eq? x missing)) (loop x (cdr steps) taken))
                    ((not (eq? default missing)) default)
                    (else
                     (raise (condition (make-json-error 'not-found #f)
                                       (make-who-condition 'json-ref)
                                       (make-message-condition "no value at the end of this path")
                                       (make-irritants-condition (list (reverse taken))))))))))))

  ;; --- json=? -----------------------------------------------------------------

  ;; A number's exact value as (SIGN DIGITS EXPONENT), worth SIGN DIGITS x
  ;; 10^EXPONENT, DIGITS a string with no leading or trailing 0 and
  ;; EXPONENT in exponent form; or zero. Two numbers are equal exactly when
  ;; these are equal?. EXPONENT-OF gives the exponent from the number of
  ;; trailing zeros taken off the digits.
  (define (normal sign digits exponent-of)
    (let* ((n (string-length digits))
           (start (skip-zeros digits 0 n))
           (end (let loop ((i n))
                  (if (and (> i start) (char=? (string-ref digits (- i 1)) #\0)) (loop (- i 1)) i))))
      (if (= start end)
          'zero
          (list sign (substring digits start end) (exponent-of (- n end))))))

  ;; The first index from I below END of TEXT that is not a 0.
  (define (skip-zeros text i end)
    (if (and (< i end) (char=? (string-ref text i) #\0)) (skip-zeros text (+ i 1) end) i))

  ;; --- exponents of any length ---

  ;; An exponent is the string of its decimal digits, after a - when
  ;; negative, as number->string writes it: one form for each value. A
  ;; json-number's exponent may have any number of digits, and
  ;; string->number takes time quadratic in them, so a long one is never
  ;; converted.
  (define (exponent-form e) (number->string e))

  ;; The low digits of a long exponent, converted and added to on their
  ;; own: more than any fixnum shift, so one carry or borrow is enough.
  (define low-digits 19)
  (define low-unit (expt 10 low-digits))

  (define (zero-padded n)
    (let ((text (number->string n)))
      (string-append (make-string (- low-digits (string-length text)) #\0) text)))

  ;; DIGITS, a positive number in decimal, plus 1 or minus 1.
  (define (decimal-add1 digits)
    (let loop ((i (- (string-length digits) 1)))
      (cond ((< i 0) (string-append "1" (make-string (string-length digits) #\0)))
            ((char=? (string-ref digits i) #\9) (loop (- i 1)))
            (else (string-append (substring digits 0 i)
                                 (string (integer->char (+ (char->integer (string-ref digits i)) 1)))
                                 (make-string (- (string-length digits) i 1) #\0))))))
  (define (decimal-sub1 digits)
    (let loop ((i (- (string-length digits) 1)))
      (if (char=? (string-ref digits i) #\0)
          (loop (- i 1))
          (string-append (substring digits 0 i)
                         (string (integer->char (- (char->integer (string-ref digits i)) 1)))
                         (make-string (- (string-length digits) i 1) #\9)))))

  ;; The exponent TEXT holds from START to END, an optional sign and
  ;; digits, plus SHIFT, a fixnum, in exponent form.
  (define (exponent-plus text start end shift)
    (let* ((signed? (and (< start end) (memv (string-ref text start) '(#\+ #\-))))
           (negative? (and signed? (char=? (string-ref text start) #\-)))
           (first (skip-zeros text (if signed? (+ start 1) start) end)))
      (if (<= (- end first) low-digits)
          (let ((m (if (= first end) 0 (string->number (substring text first end) 10))))
            (exponent-form (+ (if negative? (- m) m) shift)))
          ;; Digits past the 19 low ones: worked on as text.
          (let* ((split (- end low-digits))
                 (head (substring text first split))
                 (low (+ (string->number (substring text split end) 10)
                         (if negative? (- shift) shift)))
                 (digits (cond ((>= low low-unit)
                                (string-append (decimal-add1 head) (zero-padded (- low low-unit))))
                               ((< low 0)
                                (string-append (decimal-sub1 head) (zero-padded (+ low low-unit))))
                               (else (string-append head (zero-padded low))))))
            (string-append (if negative? "-" "")
                           (substring digits (skip-zeros digits 0 (string-length digits))
                                      (string-length digits)))))))

  (define (digits-end text i)
    (if (and (< i (string-length text)) (char<=? #\0 (string-ref text i) #\9))
        (digits-end text (+ i 1))
        i))

  ;; A json-number's text, which matches JSON's grammar.
  (define (text-decimal text)
    (let* ((n (string-length text))
           (negative? (char=? (string-ref text 0) #\-))
           (int-start (if negative? 1 0))
           (int-end (digits-end text int-start))
           (frac-start (if (and (< int-end n) (char=? (string-ref text int-end) #\.))
                           (+ int-end 1)
                           int-end))
           (frac-end (digits-end text frac-start))
           (exponent-start (if (< frac-end n) (+ frac-end 1) n)))
      (normal (if negative? '- '+)
              (string-append (substring text int-start int-end)
                             (substring text frac-start frac-end))
              (lambda (zeros)
                (exponent-plus text exponent-start n (- zeros (- frac-end frac-start)))))))

  ;; How many times FACTOR divides N, a positive exact integer.
  (define (power-of n factor)
    (let loop ((n n) (k 0))
      (let-values (((q r) (div-and-mod n factor)))
        (if (= r 0) (loop q (+ k 1)) k))))

  ;; An exact rational whose denominator has no prime factor but 2 and 5.
  (define (rational-decimal r)
    (if (= r 0)
        'zero
        (let* ((d (denominator r))
               (k (max (power-of d 2) (power-of d 5))))
          (normal (if (< r 0) '- '+)
                  (number->string (* (abs r) (expt 10 k)))
                  (lambda (zeros) (exponent-form (- zeros k)))))))

  (define (decimal x)
    (if (json-number? x)
        (text-decimal (json-number-text x))
        (rational-decimal (exact x))))

  (define (object? x) (or (hashtable? x) (pair? x) (null? x)))

  ;; X's members in a table keyed by string=?, the last duplicate winning:
  ;; X itself if it is one.
  (define (members x)
    (if (and (hashtable? x) (eq? (hashtable-equivalence-function x) string=?))
        x
        (let ((t (make-hashtable string-hash string=?)))
          (if (hashtable? x)
              (let-values (((keys values) (hashtable-entries x)))
                (vector-for-each (lambda (k v) (hashtable-set! t k v)) keys values))
              (for-each (lambda (m) (hashtable-set! t (car m) (cdr m))) x))
          t)))

  (define (same-members? a b)
    (let ((ta (members a)) (tb (members b)))
      (and (= (hashtable-size ta) (hashtable-size tb))
           (let-values (((keys values) (hashtable-entries ta)))
             (let loop ((i 0))
               (or (fx=? i (vector-length keys))
                   (let ((y (hashtable-ref tb (vector-ref keys i) missing)))
                     (and (not (eq? y missing))
                          (same? (vector-ref values i) y)
                          (loop (fx+ i 1))))))))))

  (define (same-elements? a b)
    (and (fx=? (vector-length a) (vector-length b))
         (let loop ((i 0))
           (or (fx=? i (vector-length a))
               (and (same? (vector-ref a i) (vector-ref b i))
                    (loop (fx+ i 1)))))))

  ;; A and B have passed check-json, so every number is a finite rational
  ;; with a finite decimal, or a json-number, and no value contains itself.
  (define (same? a b)
    (cond ((string? a) (and (string? b) (string=? a b)))
          ((vector? a) (and (vector? b) (same-elements? a b)))
          ((object? a) (and (object? b) (same-members? a b)))
          ((and (number? a) (number? b)) (= a b))
          ((or (number? a) (json-number? a))
           (and (or (number? b) (json-number? b))
                (equal? (decimal a) (decimal b))))
          (else (eqv? a b))))

  ;; json=? : Any Any [json-options] -> Boolean
  ;; Whether A and B mean the same JSON: objects with the same keys and
  ;; json=? values, member order aside and the last duplicate winning;
  ;; arrays with json=? elements in order; equal strings; numbers of the
  ;; same exact value; and anything else by eqv?. Raises the &json-error
  ;; put-json would if JSON can't express A or B under OPTIONS.
  (define json=?
    (case-lambda
      ((a b) (json=? a b default-options))
      ((a b options)
       (check-options 'json=? options)
       (as 'json=? (lambda () (check-json a options) (check-json b options)))
       (same? a b))))

  ;; json-null? : Any [json-options] -> Boolean
  ;; Whether V is OPTIONS' null, the symbol null by default.
  (define json-null?
    (case-lambda
      ((v) (json-null? v default-options))
      ((v options)
       (check-options 'json-null? options)
       (eq? v (json-options-null options))))))
