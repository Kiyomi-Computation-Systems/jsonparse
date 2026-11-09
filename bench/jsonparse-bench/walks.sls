#!r6rs
;;; (jsonparse-bench walks): what bench/chez-peers.sps counts on SRFI 180's
;;; and chez-json's values (ADR-0024), as jsonparse's events lane counts the
;;; text. It imports no comparator, so make test can test it.
;;;
;;;   srfi-180-tree-counts   walks json-read's value
;;;   chez-json-tree-counts  walks json->scm's value
;;;   srfi-180-fold-counts   counts json-fold's events
;;;
;;; Each counts a fresh tally per call and raises on a value its library
;;; never builds. text-bytes is each string's and each key's decoded text
;;; as UTF-8 bytes; neither library hands over a number's text, so neither
;;; counts number-bytes.
(library (jsonparse-bench walks)
  (export srfi-180-tree-counts chez-json-tree-counts srfi-180-fold-counts)
  (import (rnrs)
          (only (jsonparse-bench) utf8-length/scalar))

  (define (add! v k n) (vector-set! v k (fx+ (vector-ref v k) n)))

  (define (string-utf8-length s)
    (let ((n (string-length s)))
      (let loop ((i 0) (len 0))
        (if (fx=? i n)
            len
            (loop (fx+ i 1)
                  (fx+ len (utf8-length/scalar (char->integer (string-ref s i)))))))))

  ;; The names SRFI 180's counts carry, in order: the events lane's but
  ;; number-bytes. Slots 0 to 8.
  (define nine '(null true false number string key object array text-bytes))

  ;; srfi-180-tree-counts : Any -> (Listof (Pair Symbol Nat))
  ;; Counts nine names on a value of SRFI 180's json-read: an object is an
  ;; alist of (symbol . value) pairs, '() for {}; an array a vector; null
  ;; the symbol null; and strings, real numbers, #t and #f. An object
  ;; counts object and each member a key and its text; an array counts
  ;; array; a string string and its text. Raises on anything else.
  (define (srfi-180-tree-counts value)
    (define who 'srfi-180-tree-counts)
    (let ((v (make-vector 9 0)))
      (let walk ((x value))
        (cond ((null? x) (add! v 6 1))
              ((pair? x)
               (add! v 6 1)
               (let members ((m x))
                 (cond ((null? m))
                       ((and (pair? m) (pair? (car m)) (symbol? (caar m)))
                        (add! v 5 1)
                        (add! v 8 (string-utf8-length (symbol->string (caar m))))
                        (walk (cdar m))
                        (members (cdr m)))
                       (else (error who "not an object's members" m)))))
              ((vector? x) (add! v 7 1) (vector-for-each walk x))
              ((string? x) (add! v 4 1) (add! v 8 (string-utf8-length x)))
              ((eq? x 'null) (add! v 0 1))
              ((eq? x #t) (add! v 1 1))
              ((eq? x #f) (add! v 2 1))
              ((real? x) (add! v 3 1))
              (else (error who "not a value of SRFI 180's tree" x))))
      (map cons nine (vector->list v))))

  ;; chez-json-tree-counts : Any -> (Listof (Pair Symbol Nat))
  ;; Counts eight names on a value of chez-json's json->scm: an object is a
  ;; hashtable with string keys; an array a list; and strings, real numbers,
  ;; #t and #f. null is '(), as [] is, so every list counts null+array,
  ;; '() included, where SRFI 180 counts null and array apart. Raises on
  ;; anything else.
  (define (chez-json-tree-counts value)
    (define who 'chez-json-tree-counts)
    (let ((v (make-vector 8 0)))
      (let walk ((x value))
        (cond ((hashtable? x)
               (add! v 6 1)
               (let-values (((keys vals) (hashtable-entries x)))
                 (vector-for-each
                  (lambda (k value)
                    (unless (string? k) (error who "not an object's key" k))
                    (add! v 5 1)
                    (add! v 7 (string-utf8-length k))
                    (walk value))
                  keys vals)))
              ((null? x) (add! v 0 1))
              ((pair? x)
               (add! v 0 1)
               (let elements ((l x))
                 (cond ((null? l))
                       ((pair? l) (walk (car l)) (elements (cdr l)))
                       (else (error who "not a proper list" x)))))
              ((string? x) (add! v 4 1) (add! v 7 (string-utf8-length x)))
              ((eq? x #t) (add! v 1 1))
              ((eq? x #f) (add! v 2 1))
              ((real? x) (add! v 3 1))
              (else (error who "not a value of chez-json's tree" x))))
      (map cons
           '(null+array true false number string key object text-bytes)
           (vector->list v))))

  ;; srfi-180-fold-counts :
  ;;   ((Any Any -> Any) (Any -> Any) (Any -> Any) (Any -> Any) (Any -> Any) Any -> Any)
  ;;   -> (Listof (Pair Symbol Nat))
  ;; Counts the nine names on json-fold's events. FOLD is json-fold with its
  ;; port given: it is called once with json-fold's five procedures and its
  ;; seed, and must return the seed it ends with.
  ;;
  ;; json-fold hands keys and string values alike to its procedure as
  ;; strings, so the seed says where the fold is: top, array, key (the next
  ;; string is a key) or value. object-start and array-start count their
  ;; structure and seed its members; at its end, json-fold goes on with the
  ;; seed from before the structure, handing its procedure what object-end
  ;; or array-end returned, here a mark that counts nothing. Raises on a
  ;; key that isn't a string, on a value no event holds, and on a seed out
  ;; of step.
  (define (srfi-180-fold-counts fold)
    (define who 'srfi-180-fold-counts)
    (define closed (list 'closed))
    (let ((v (make-vector 9 0)))
      (define (value! x)
        (cond ((eq? x closed))
              ((string? x) (add! v 4 1) (add! v 8 (string-utf8-length x)))
              ((eq? x 'null) (add! v 0 1))
              ((eq? x #t) (add! v 1 1))
              ((eq? x #f) (add! v 2 1))
              ((real? x) (add! v 3 1))
              (else (error who "not a value of SRFI 180's events" x))))
      (define (proc x seed)
        (case seed
          ((key)
           (unless (string? x) (error who "not an object's key" x))
           (add! v 5 1)
           (add! v 8 (string-utf8-length x))
           'value)
          ((value) (value! x) 'key)
          ((array top) (value! x) seed)
          (else (error who "not a seed of this fold" seed))))
      (define (array-start seed) (add! v 7 1) 'array)
      (define (array-end seed)
        (unless (eq? seed 'array) (error who "an array closed out of step" seed))
        closed)
      (define (object-start seed) (add! v 6 1) 'key)
      (define (object-end seed)
        (unless (eq? seed 'key) (error who "an object closed out of step" seed))
        closed)
      (let ((end (fold proc array-start array-end object-start object-end 'top)))
        (unless (eq? end 'top) (error who "the fold ended off the top" end)))
      (map cons nine (vector->list v)))))
