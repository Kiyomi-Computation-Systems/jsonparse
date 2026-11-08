#!r6rs
;;; (jsonparse sequence): reads a stream of many JSON values, fed in
;;; chunks (ADR-0014, ADR-0020).
;;;
;;;   (define r (make-json-reader (lambda (v) (write v))))
;;;   (json-reader-feed! r (string->utf8 "{\"a\": 1}\n[2]\n"))   ; shows (("a" . 1)) and #(2)
;;;   (json-reader-finish! r)                                  ; a result whose status is finished
;;;
;;; The options' stream says how the values are framed:
;;;
;;;   lines   the default: one value a line (JSON Lines, NDJSON). A line
;;;           ends at a newline, and the last line's is optional.
;;;           Whitespace around the value is allowed, so a \r before the
;;;           newline is too. A blank or whitespace-only line is a bad
;;;           record, blank-line, unless the options' blank-lines is skip
;;;   seq     RFC 7464: each value after an RS byte (#x1E), repeated RSs
;;;           ignored. Bytes before the first RS are a bad record,
;;;           unexpected-byte at their first. A record holding a top-level
;;;           number or literal with no whitespace after it may have been
;;;           cut short: it is a bad record, truncated, at its end
;;;   values  values one after another, as (jsonparse parser) reads them
;;;           under stream values. Nothing marks where a value would
;;;           begin after a bad one, so a bad value ends the stream
;;;
;;; Each value goes to ON-VALUE once its record ends. One builder, reused,
;;; reads every record under the options, so the depth and digit limits
;;; apply to each record, and no record is copied whole.
;;;
;;; A bad record:
;;;
;;;   - with no ON-SKIP, ends the stream: feed or finish answers an error,
;;;     whose code says why and whose offset says where, in bytes from the
;;;     start of the stream. json-reader-record gives the record's number;
;;;   - given ON-SKIP, is skipped: ON-SKIP gets its code, its number and
;;;     its offset, and the reader goes on at the next record. A record
;;;     found bad partway is dropped up to its separator. seq needs ON-SKIP,
;;;     since RFC 7464 asks a reader to skip, and values refuses it.
;;;
;;; Records are numbered from 1 in the order they start: lines by line,
;;; blank ones included; seq by RS, repeated RSs making none; values by
;;; value.
;;;
;;; The results are (jsonparse parser)'s: need-input after a feed,
;;; finished once finish has read every record, and error for a bad record
;;; that ends the stream. finished and error stick until a reset.
;;;
;;; The procedures' return values are ignored. If one raises, or escapes
;;; through a continuation, the exception or escape passes out of the feed
;;; or finish, and feeding or finishing the reader then raises until it is
;;; reset. Feeding, finishing or resetting a reader from inside its own
;;; procedures raises.
(library (jsonparse sequence)
  (export make-json-reader json-reader?
          json-reader-feed! json-reader-finish! json-reader-reset!
          json-reader-record)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse tree))

  (define line-feed 10)
  (define record-separator #x1E)

  (define (whitespace? b)
    (or (fx=? b 32) (fx=? b 10) (fx=? b 13) (fx=? b 9)))

  ;; The first index from I below J whose byte is SEPARATOR, or J.
  (define (scan bv i j separator)
    (let loop ((k i))
      (cond ((fx=? k j) j)
            ((fx=? (bytevector-u8-ref bv k) separator) k)
            (else (loop (fx+ k 1))))))

  ;; The first byte from I below J that isn't whitespace, or #f.
  (define (first-content bv i j)
    (let loop ((k i))
      (cond ((fx=? k j) #f)
            ((whitespace? (bytevector-u8-ref bv k)) (loop (fx+ k 1)))
            (else (bytevector-u8-ref bv k)))))

  ;; Whether B starts a number or a literal, the values only whitespace
  ;; can end: - 0-9 t f n.
  (define (scalar-start? b)
    (or (fx<=? 48 b 57) (fx=? b 45) (fx=? b 116) (fx=? b 102) (fx=? b 110)))

  ;; --- the reader ---------------------------------------------------------------

  ;; json-reader? : Any -> Boolean
  ;; ENTER and LEAVE mark the reader busy while one of its procedures runs,
  ;; and poisoned if one leaves without returning. OPEN? says whether the
  ;; record being read has a byte yet, START is the stream offset of its
  ;; first, FIRST its first byte that isn't whitespace, or #f, and LAST its
  ;; last byte. BAD? says the record is being dropped, and FRAMED? that an
  ;; RS has been read.
  (define-record-type (json-reader new-json-reader json-reader?)
    (fields (immutable stream reader-stream)
            (immutable skip-blank? reader-skip-blank?)
            (immutable on-value reader-on-value)
            (immutable on-skip reader-on-skip)
            (mutable builder reader-builder reader-builder-set!)
            (immutable enter reader-enter)
            (immutable leave reader-leave)
            (mutable lifecycle reader-lifecycle reader-lifecycle-set!)
            (mutable result reader-result reader-result-set!)
            (mutable offset reader-offset reader-offset-set!)
            (mutable record reader-record reader-record-set!)
            (mutable open? reader-open? reader-open?-set!)
            (mutable start reader-start reader-start-set!)
            (mutable first reader-first reader-first-set!)
            (mutable last reader-last reader-last-set!)
            (mutable bad? reader-bad? reader-bad?-set!)
            (mutable framed? reader-framed? reader-framed?-set!))
    (protocol
     (lambda (new)
       (lambda (stream skip-blank? on-value on-skip)
         (letrec ((r (new stream skip-blank? on-value on-skip #f
                          (lambda () (reader-lifecycle-set! r 'busy))
                          (lambda ()
                            (when (eq? (reader-lifecycle r) 'busy)
                              (reader-lifecycle-set! r 'poisoned)))
                          'ready #f 0 1 #f 0 #f 0 #f #f)))
           r))))
    (sealed #t)
    (opaque #t))

  ;; Runs one of R's procedures, marking R busy while it runs.
  (define (hand-value! r v)
    (dynamic-wind (reader-enter r)
                  (lambda () ((reader-on-value r) v) (reader-lifecycle-set! r 'ready))
                  (reader-leave r)))

  (define (hand-skip! r code record offset)
    (dynamic-wind (reader-enter r)
                  (lambda () ((reader-on-skip r) code record offset) (reader-lifecycle-set! r 'ready))
                  (reader-leave r)))

  (define default-options (make-json-options))

  ;; make-json-reader : (Any -> Any) [(U #f (Symbol Positive-Integer Nonnegative-Integer -> Any))] [json-options] -> json-reader
  ;; A reader that hands each value to ON-VALUE, under OPTIONS (default
  ;; (make-json-options), so lines). Given ON-SKIP, it skips bad records,
  ;; calling (ON-SKIP code record offset) for each. Stream seq needs
  ;; ON-SKIP, and stream values refuses it.
  (define make-json-reader
    (case-lambda
      ((on-value) (make-json-reader on-value #f default-options))
      ((on-value x)
       (if (json-options? x)
           (make-json-reader on-value #f x)
           (make-json-reader on-value x default-options)))
      ((on-value on-skip options)
       (unless (procedure? on-value)
         (assertion-violation 'make-json-reader "not a procedure" on-value))
       (unless (or (not on-skip) (procedure? on-skip))
         (assertion-violation 'make-json-reader "not a procedure or #f" on-skip))
       (unless (json-options? options)
         (assertion-violation 'make-json-reader "not an options record" options))
       (let ((stream (json-options-stream options)))
         (when (and (eq? stream 'seq) (not on-skip))
           (assertion-violation 'make-json-reader
                                "stream seq skips bad records, so it needs a procedure to report them to"))
         (when (and (eq? stream 'values) on-skip)
           (assertion-violation 'make-json-reader
                                "stream values can't skip a bad value: nothing marks where the next begins"
                                on-skip))
         (let ((r (new-json-reader stream
                                   (and (eq? stream 'lines)
                                        (eq? (json-options-blank-lines options) 'skip))
                                   on-value on-skip)))
           (reader-builder-set!
            r
            (if (eq? stream 'values)
                (make-json-builder options
                                   (lambda (v)
                                     (hand-value! r v)
                                     (reader-record-set! r (+ (reader-record r) 1))))
                (make-json-builder options)))
           r)))))

  ;; --- records ------------------------------------------------------------------

  (define (need-input r) (make-json-result 'need-input #f (reader-offset r)))

  (define (stick! r res)
    (reader-result-set! r res)
    res)

  ;; The record being read is bad: CODE at stream offset AT. Skips the
  ;; rest of it, telling ON-SKIP, and answers #f; or, with no ON-SKIP, ends
  ;; the stream and answers its error.
  (define (bad! r code at)
    (if (reader-on-skip r)
        (begin (reader-bad?-set! r #t)
               (hand-skip! r code (reader-record r) at)
               #f)
        (stick! r (make-json-result 'error code at))))

  ;; The record's first bytes, at stream offset AT.
  (define (open! r at)
    (unless (reader-open? r)
      (reader-open?-set! r #t)
      (reader-start-set! r at)))

  ;; Feeds the bytes of BV from I below J to the record's builder. Answers
  ;; as bad! does if the record turns out bad, and #f otherwise.
  (define (part! r bv i j)
    (unless (reader-first r)
      (reader-first-set! r (first-content bv i j)))
    (let ((res (json-builder-feed! (reader-builder r) bv i j)))
      (if (eq? (json-result-status res) 'error)
          (bad! r (json-result-code res) (+ (reader-start r) (json-result-offset res)))
          #f)))

  ;; Finishes the record, which ends at stream offset AT, and hands its
  ;; value on. Answers as bad! does.
  (define (take! r at)
    (let* ((b (reader-builder r))
           (res (json-builder-finish! b)))
      (cond
       ((eq? (json-result-status res) 'error)
        (bad! r (json-result-code res) (+ (reader-start r) (json-result-offset res))))
       ((and (eq? (reader-stream r) 'seq)
             (scalar-start? (reader-first r))
             (not (whitespace? (reader-last r))))
        (bad! r 'truncated at))
       (else
        (hand-value! r (json-builder-value b))
        #f))))

  (define (next-record! r)
    (json-builder-reset! (reader-builder r))
    (reader-record-set! r (+ (reader-record r) 1))
    (reader-open?-set! r #f)
    (reader-first-set! r #f)
    (reader-bad?-set! r #f))

  ;; --- lines --------------------------------------------------------------------

  ;; The line being read ends at stream offset AT.
  (define (end-line! r at)
    (or (cond ((reader-bad? r) #f)
              ((reader-first r) (take! r at))
              ((reader-skip-blank? r) #f)
              (else (bad! r 'blank-line at)))
        (begin (next-record! r) #f)))

  (define (feed-lines! r bv s e)
    (let ((base (reader-offset r)))
      (define (at k) (+ base (fx- k s)))
      (let loop ((i s))
        (let ((j (scan bv i e line-feed)))
          (or (and (fx<? i j)
                   (begin (open! r (at i))
                          (and (not (reader-bad? r)) (part! r bv i j))))
              (if (fx=? j e)
                  (begin (reader-offset-set! r (at e)) (need-input r))
                  (or (end-line! r (at j))
                      (loop (fx+ j 1)))))))))

  (define (finish-lines! r)
    (or (and (reader-open? r) (end-line! r (reader-offset r)))
        (stick! r (make-json-result 'finished #f (reader-offset r)))))

  ;; --- seq ----------------------------------------------------------------------

  ;; The record being read ends at stream offset AT, at an RS or the end.
  (define (end-seq-record! r at)
    (and (reader-open? r)
         (or (and (not (reader-bad? r)) (take! r at))
             (begin (next-record! r) #f))))

  (define (feed-seq! r bv s e)
    (let ((base (reader-offset r)))
      (define (at k) (+ base (fx- k s)))
      (let loop ((i s))
        (let ((j (scan bv i e record-separator)))
          (or (and (fx<? i j)
                   (begin
                     (reader-last-set! r (bytevector-u8-ref bv (fx- j 1)))
                     (cond
                      ((reader-framed? r)
                       (open! r (at i))
                       (and (not (reader-bad? r)) (part! r bv i j)))
                      ((reader-open? r) #f)
                      (else
                       (open! r (at i))
                       (bad! r 'unexpected-byte (at i))))))
              (if (fx=? j e)
                  (begin (reader-offset-set! r (at e)) (need-input r))
                  (or (end-seq-record! r (at j))
                      (begin (reader-framed?-set! r #t)
                             (loop (fx+ j 1))))))))))

  (define (finish-seq! r)
    (or (end-seq-record! r (reader-offset r))
        (stick! r (make-json-result 'finished #f (reader-offset r)))))

  ;; --- values -------------------------------------------------------------------

  ;; The builder reads the whole stream, so its offsets are the stream's.
  (define (feed-values! r bv s e)
    (let ((res (json-builder-feed! (reader-builder r) bv s e)))
      (reader-offset-set! r (+ (reader-offset r) (fx- e s)))
      (if (eq? (json-result-status res) 'error)
          (stick! r res)
          (need-input r))))

  (define (finish-values! r)
    (stick! r (json-builder-finish! (reader-builder r))))

  ;; --- feeding ------------------------------------------------------------------

  (define (check-reader who r)
    (unless (json-reader? r)
      (assertion-violation who "not a reader" r)))

  (define (check-usable who r)
    (case (reader-lifecycle r)
      ((busy)
       (assertion-violation who "called from inside one of the reader's own procedures"))
      ((poisoned)
       (assertion-violation who "one of the reader's procedures raised or escaped: reset the reader before using it again"))
      (else #f)))

  ;; json-reader-feed! : json-reader Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result
  ;; Reads the bytes of BV from START up to END, or all of BV, handing on
  ;; each value whose record they end. Raises unless
  ;; 0 <= START <= END <= (bytevector-length BV).
  (define json-reader-feed!
    (case-lambda
      ((r bv)
       (check-reader 'json-reader-feed! r)
       (unless (bytevector? bv)
         (assertion-violation 'json-reader-feed! "not a bytevector" bv))
       (json-reader-feed! r bv 0 (bytevector-length bv)))
      ((r bv start end)
       (check-reader 'json-reader-feed! r)
       (unless (bytevector? bv)
         (assertion-violation 'json-reader-feed! "not a bytevector" bv))
       (unless (and (fixnum? start) (fixnum? end)
                    (fx<=? 0 start end (bytevector-length bv)))
         (assertion-violation 'json-reader-feed! "the range is not within the bytevector"
                              start end (bytevector-length bv)))
       (check-usable 'json-reader-feed! r)
       (or (reader-result r)
           (case (reader-stream r)
             ((lines) (feed-lines! r bv start end))
             ((seq) (feed-seq! r bv start end))
             (else (feed-values! r bv start end)))))))

  ;; json-reader-finish! : json-reader -> json-result
  ;; Tells R the stream has ended: reads its last record.
  (define (json-reader-finish! r)
    (check-reader 'json-reader-finish! r)
    (check-usable 'json-reader-finish! r)
    (or (reader-result r)
        (case (reader-stream r)
          ((lines) (finish-lines! r))
          ((seq) (finish-seq! r))
          (else (finish-values! r)))))

  ;; json-reader-reset! : json-reader -> Void
  ;; Makes R as good as new, for the next stream.
  (define (json-reader-reset! r)
    (check-reader 'json-reader-reset! r)
    (when (eq? (reader-lifecycle r) 'busy)
      (assertion-violation 'json-reader-reset! "called from inside one of the reader's own procedures"))
    (json-builder-reset! (reader-builder r))
    (reader-lifecycle-set! r 'ready)
    (reader-result-set! r #f)
    (reader-offset-set! r 0)
    (reader-record-set! r 1)
    (reader-open?-set! r #f)
    (reader-first-set! r #f)
    (reader-bad?-set! r #f)
    (reader-framed?-set! r #f))

  ;; json-reader-record : json-reader -> Positive-Integer
  ;; The number of the record R is reading, counting from 1: inside its
  ;; procedures, the record handed over; after an error, the bad record;
  ;; after finished, one past the last.
  (define (json-reader-record r)
    (check-reader 'json-reader-record r)
    (reader-record r)))
