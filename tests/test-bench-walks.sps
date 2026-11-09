#!r6rs
;;; tests/test-bench-walks.sps: (jsonparse-bench walks), the counting that
;;; bench/chez-peers.sps does on SRFI 180's and chez-json's values (ADR-0024).
;;; No comparator is loaded: every value is built by hand, in the shape each
;;; library builds, and json-fold is played by fold-over, which follows
;;; SRFI 180's %json-fold over a list of json-generator's events.
;;;
;;;   1. srfi-180-tree-counts walks json-read's value: an alist with symbol
;;;      keys ('() for {}), a vector, the symbol null;
;;;   2. chez-json-tree-counts walks json->scm's value: an equal? hashtable
;;;      with string keys, a list, and '() for both null and [];
;;;   3. srfi-180-fold-counts counts json-fold's events, keys apart from
;;;      strings.
;;;
;;; Each document counts each name a different number of times, so a count
;;; under the wrong name changes the whole output.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-bench walks))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; raise-who : (-> Any) -> (U 'no-raise 'no-who Symbol)
;; What THUNK's raise names as its who, 'no-who for a raise naming none,
;; or 'no-raise.
(define (raise-who thunk)
  (guard (e ((who-condition? e) (condition-who e))
            (#t 'no-who))
    (thunk)
    'no-raise))

(define (key s) (string->symbol s))

;; The texts, as UTF-8: each key and string straddles a boundary of
;; UTF-8's lengths, and the last string holds what a surrogate pair
;; decodes to.
;;
;;   keys     "\xE9;" 2, "\x1F600;" 4, "k" 1, "\x43A;\x43B;\x44E;\x447;" 8,
;;            "" 0, "\x7F;\x80;" 3                                  = 18
;;   strings  "x" 1, "\x7FF;\x800;" 5, "\xD7FF;\xE000;" 6,
;;            "\xFFFD;\xFFFF;" 6, "\x10000;\x10FFFF;" 8            = 26
(define k-e "\xE9;")
(define k-smile "\x1F600;")
(define k-cyrillic "\x43A;\x43B;\x44E;\x447;")
(define k-edge "\x7F;\x80;")
(define edge-strings
  (list "\x7FF;\x800;" "\xD7FF;\xE000;" "\xFFFD;\xFFFF;" "\x10000;\x10FFFF;"))

;; One document, as JSON:
;;
;;   {"é": [null, true, true, false, false, false, 1, 2.5, -3, 1e20],
;;    "😀": [], "k": {}, "ключ": [{}, {}, {}, {}, {}, [], []], "": "x",
;;    "\x7F\x80": [the four edge strings, [[]]]}
;;
;; null 1, true 2, false 3, number 4, string 5, key 6, object 7, array 8,
;; and 44 bytes of text: 18 in characters.
(define doc-counts
  '((null . 1) (true . 2) (false . 3) (number . 4) (string . 5) (key . 6)
    (object . 7) (array . 8) (text-bytes . 44)))

(define (srfi-180-doc)
  (list (cons (key k-e) (vector 'null #t #t #f #f #f 1 2.5 -3 100000000000000000000))
        (cons (key k-smile) (vector))
        (cons (key "k") '())
        (cons (key k-cyrillic) (vector '() '() '() '() '() (vector) (vector)))
        (cons (key "") "x")
        (cons (key k-edge) (list->vector (append edge-strings (list (vector (vector))))))))

(define (all-zero names) (map (lambda (n) (cons n 0)) names))

(define nine '(null true false number string key object array text-bytes))

(define (with counts names)
  (map (lambda (n) (cons n (cond ((assq n counts) => cdr) (else 0)))) names))

(test-begin "bench-walks")

;; --- 1. SRFI 180's tree --------------------------------------------------------

(test-equal "srfi-180 tree: the document, every name its own count"
  doc-counts
  (srfi-180-tree-counts (srfi-180-doc)))

(test-equal "srfi-180 tree: a second walk counts afresh"
  doc-counts
  (begin (srfi-180-tree-counts (srfi-180-doc)) (srfi-180-tree-counts (srfi-180-doc))))

(test-equal "srfi-180 tree: '() alone is the empty object"
  (with '((object . 1)) nine)
  (srfi-180-tree-counts '()))

(test-equal "srfi-180 tree: an object holding only empty objects"
  (with '((object . 3) (key . 2) (text-bytes . 2)) nine)
  (srfi-180-tree-counts (list (cons 'a '()) (cons 'b '()))))

(test-equal "srfi-180 tree: nested empty arrays"
  (with '((array . 3)) nine)
  (srfi-180-tree-counts (vector (vector) (vector))))

(test-equal "srfi-180 tree: the symbol null alone"
  (with '((null . 1)) nine)
  (srfi-180-tree-counts 'null))

(test-equal "srfi-180 tree: a string past the BMP alone, 4 bytes"
  (with '((string . 1) (text-bytes . 4)) nine)
  (srfi-180-tree-counts k-smile))

(test-equal "srfi-180 tree: a key named null is a key"
  (with '((object . 1) (key . 1) (string . 1) (text-bytes . 8)) nine)
  (srfi-180-tree-counts (list (cons 'null "null"))))

(test-equal "srfi-180 tree: another symbol raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (vector 'nil)))))

(test-equal "srfi-180 tree: a string key raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (list (cons "a" 1))))))

(test-equal "srfi-180 tree: an improper member list raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (cons (cons 'a 1) 2)))))

(test-equal "srfi-180 tree: a list of values raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (list 1 2)))))

(test-equal "srfi-180 tree: a hashtable raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (make-hashtable equal-hash equal?)))))

(test-equal "srfi-180 tree: a character raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (vector #\a)))))

(test-equal "srfi-180 tree: a complex number raises"
  'srfi-180-tree-counts
  (raise-who (lambda () (srfi-180-tree-counts (make-rectangular 1 2)))))

;; --- 2. chez-json's tree -------------------------------------------------------

(define eight '(null+array true false number string key object text-bytes))

(define (table . members)
  (let ((h (make-hashtable equal-hash equal?)))
    (for-each (lambda (m) (hashtable-set! h (car m) (cdr m))) members)
    h))

;; The document again, as json->scm builds it, with one more [] in the
;; first array: each name keeps its own count. Every list counts
;; null+array: the first array, "😀"'s null, the array of objects and the
;; [] in it, the edge strings' array, its [[]] and the [] in that, and the
;; added [] = 8.
(define chez-json-counts
  '((null+array . 8) (true . 2) (false . 3) (number . 4) (string . 5) (key . 6)
    (object . 7) (text-bytes . 44)))

(define (chez-json-doc)
  (table (cons k-e (list #t #t #f #f #f 1 2.5 -3 100000000000000000000 '()))
         (cons k-smile '())
         (cons "k" (table))
         (cons k-cyrillic (list (table) (table) (table) (table) (table) '()))
         (cons "" "x")
         (cons k-edge (append edge-strings (list (list '()))))))

(test-equal "chez-json tree: the document, '() in both roles"
  chez-json-counts
  (chez-json-tree-counts (chez-json-doc)))

(test-equal "chez-json tree: a second walk counts afresh"
  chez-json-counts
  (begin (chez-json-tree-counts (chez-json-doc)) (chez-json-tree-counts (chez-json-doc))))

(test-equal "chez-json tree: '() alone, null or []"
  (with '((null+array . 1)) eight)
  (chez-json-tree-counts '()))

(test-equal "chez-json tree: [[], null] and the like, three lists"
  (with '((null+array . 3)) eight)
  (chez-json-tree-counts (list '() '())))

(test-equal "chez-json tree: an empty object"
  (with '((object . 1)) eight)
  (chez-json-tree-counts (table)))

(test-equal "chez-json tree: a key past the BMP"
  (with '((object . 1) (key . 1) (null+array . 1) (text-bytes . 4)) eight)
  (chez-json-tree-counts (table (cons k-smile '()))))

(test-equal "chez-json tree: the symbol null raises"
  'chez-json-tree-counts
  (raise-who (lambda () (chez-json-tree-counts (list 'null)))))

(test-equal "chez-json tree: a vector raises"
  'chez-json-tree-counts
  (raise-who (lambda () (chez-json-tree-counts (vector 1)))))

(test-equal "chez-json tree: a symbol key raises"
  'chez-json-tree-counts
  (raise-who (lambda () (chez-json-tree-counts (table (cons 'a 1))))))

(test-equal "chez-json tree: an improper list raises"
  'chez-json-tree-counts
  (raise-who (lambda () (chez-json-tree-counts (cons 1 2)))))

(test-equal "chez-json tree: a character raises"
  'chez-json-tree-counts
  (raise-who (lambda () (chez-json-tree-counts (list #\a)))))

;; --- 3. SRFI 180's json-fold ---------------------------------------------------

;; fold-over : (Listof Any) -> ((Any Any -> Any) (Any -> Any) (Any -> Any)
;;                              (Any -> Any) (Any -> Any) Any -> Any)
;; A json-fold over EVENTS, json-generator's events as a list, with
;; %json-fold's seeds: at array-start the elements' seed is
;; (array-start seed); at array-end the fold goes on with
;; (proc (array-end inner-seed) seed), SEED being the one from before the
;; array; objects likewise; any other event is (proc event seed). It
;; returns the seed it ends with.
(define (fold-over events)
  (lambda (proc array-start array-end object-start object-end seed)
    (let-values (((seed rest)
                  (let loop ((es events) (seed seed))
                    (if (null? es)
                        (values seed '())
                        (let ((e (car es)))
                          (cond ((memq e '(array-end object-end)) (values seed (cdr es)))
                                ((eq? e 'array-start)
                                 (let-values (((inner rest) (loop (cdr es) (array-start seed))))
                                   (loop rest (proc (array-end inner) seed))))
                                ((eq? e 'object-start)
                                 (let-values (((inner rest) (loop (cdr es) (object-start seed))))
                                   (loop rest (proc (object-end inner) seed))))
                                (else (loop (cdr es) (proc e seed)))))))))
      seed)))

;; The document's events. A key follows a value that closed an array, an
;; object, and a string.
(define doc-events
  (append
   (list 'object-start
         k-e 'array-start 'null #t #t #f #f #f 1 2.5 -3 100000000000000000000 'array-end
         k-smile 'array-start 'array-end
         "k" 'object-start 'object-end
         k-cyrillic 'array-start
         'object-start 'object-end 'object-start 'object-end 'object-start 'object-end
         'object-start 'object-end 'object-start 'object-end
         'array-start 'array-end 'array-start 'array-end 'array-end
         "" "x"
         k-edge 'array-start)
   edge-strings
   (list 'array-start 'array-start 'array-end 'array-end 'array-end 'object-end)))

(test-equal "srfi-180 fold: the document, keys apart from strings"
  doc-counts
  (srfi-180-fold-counts (fold-over doc-events)))

(test-equal "srfi-180 fold: a second fold counts afresh"
  doc-counts
  (begin (srfi-180-fold-counts (fold-over doc-events))
         (srfi-180-fold-counts (fold-over doc-events))))

(test-equal "srfi-180 fold: a string value after a string key"
  (with '((object . 1) (key . 1) (string . 1) (text-bytes . 8)) nine)
  (srfi-180-fold-counts (fold-over (list 'object-start "null" "null" 'object-end))))

(test-equal "srfi-180 fold: a string alone"
  (with '((string . 1) (text-bytes . 4)) nine)
  (srfi-180-fold-counts (fold-over (list k-smile))))

(test-equal "srfi-180 fold: null alone"
  (with '((null . 1)) nine)
  (srfi-180-fold-counts (fold-over (list 'null))))

(test-equal "srfi-180 fold: a key that isn't a string raises"
  'srfi-180-fold-counts
  (raise-who (lambda () (srfi-180-fold-counts (fold-over (list 'object-start 1 2 'object-end))))))

(test-equal "srfi-180 fold: an object closed after its key raises"
  'srfi-180-fold-counts
  (raise-who (lambda () (srfi-180-fold-counts (fold-over (list 'object-start "a" 'object-end))))))

(test-equal "srfi-180 fold: a value no event holds raises"
  'srfi-180-fold-counts
  (raise-who (lambda () (srfi-180-fold-counts (fold-over (list 'array-start #\a 'array-end))))))

(test-equal "srfi-180 fold: a fold that ends off the top raises"
  'srfi-180-fold-counts
  (raise-who (lambda ()
               (srfi-180-fold-counts
                (lambda (proc array-start array-end object-start object-end seed)
                  (object-start seed))))))

(test-end "bench-walks")

(exit (suite-exit-status runner))
