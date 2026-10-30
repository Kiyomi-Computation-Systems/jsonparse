;;; tests/test-machine-driver.sps: the suite for (jsonparse-testing machine),
;;; the driver every conformance and fuzz suite trusts. A driver that is wrong
;;; makes those suites pass or fail for the wrong reason, so each of its
;;; views is held to traces written out by hand here.
;;;
;;; trace-content and trace-outcome are given traces built by hand, not
;;; traces the machine made, so they can be wrong only if the driver is.
;;; run-machine is checked on small inputs against whole traces written out
;;; from the grammar's rules: the feed results, the fragments, and the
;;; context stack's answers.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing property)
        (jsonparse-testing machine))

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

(test-begin "machine-driver")

;; --- helpers ------------------------------------------------------------------

(define (bytes s) (string->utf8 s))
(define (bv . xs) (u8-list->bytevector xs))

;; answer : (-> Any) -> Any
;; THUNK's value, or (raised TEXT): so a raise is never mistaken for a value.
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; spans : Schedule -> (Listof (List Nat Nat))
(define (spans schedule) (map (lambda (f) (list (cadr f) (caddr f))) schedule))

;; fed : Schedule -> Bytevector
;; The bytes the schedule feeds, in order.
(define (fed schedule)
  (apply bytevector-append*
         (map (lambda (f)
                (let ((out (make-bytevector (- (caddr f) (cadr f)))))
                  (bytevector-copy! (car f) (cadr f) out 0 (- (caddr f) (cadr f)))
                  out))
              schedule)))

(define (bytevector-append* . bvs)
  (let* ((n (fold-left + 0 (map bytevector-length bvs)))
         (out (make-bytevector n)))
    (fold-left (lambda (at bv)
                 (bytevector-copy! bv 0 out at (bytevector-length bv))
                 (+ at (bytevector-length bv)))
               0 bvs)
    out))

(define (run s schedule-of)
  (answer (lambda () (run-machine generated-machine (schedule-of (bytes s)) '()))))

(define (whole s) (run s whole-schedule))
(define (by1 s) (run s (lambda (bv) (chunk-schedule bv 1))))

;; --- chunk-schedule -----------------------------------------------------------

(define seven (bytes "abcdefg"))

(test-equal "chunk-schedule: 7 bytes in 3s are 0-3, 3-6, then the short 6-7"
  '((0 3) (3 6) (6 7))
  (spans (chunk-schedule seven 3)))

(test-equal "chunk-schedule: 7 bytes in 1s are seven feeds"
  '((0 1) (1 2) (2 3) (3 4) (4 5) (5 6) (6 7))
  (spans (chunk-schedule seven 1)))

(test-equal "chunk-schedule: a size that divides the input leaves no short feed"
  '((0 7))
  (spans (chunk-schedule seven 7)))

(test-equal "chunk-schedule: a size above the input is one feed"
  '((0 7))
  (spans (chunk-schedule seven 31)))

(test-equal "chunk-schedule: an empty input is one empty feed"
  '((0 0))
  (spans (chunk-schedule (bytes "") 4)))

(test-equal "chunk-schedule: every feed is over the input's own bytevector, and they cover it"
  '(#t #t #t #t)
  (let ((s (chunk-schedule seven 3)))
    (list (eq? (car (car s)) seven) (eq? (car (caddr s)) seven)
          (equal? (fed s) seven) (= (length s) 3))))

(test-equal "whole-schedule: the input in one feed"
  '((0 7))
  (spans (whole-schedule seven)))

;; --- random-schedule ----------------------------------------------------------

;; 5000 bytes, each different from the next, so a feed out of order shows.
(define big
  (let ((bv (make-bytevector 5000)))
    (do ((i 0 (+ i 1))) ((= i 5000) bv)
      (bytevector-u8-set! bv i (mod (* i 7) 256)))))

(define (contiguous? sp len)
  (let loop ((sp sp) (at 0))
    (cond ((null? sp) (= at len))
          ((not (= (caar sp) at)) #f)
          (else (loop (cdr sp) (cadar sp))))))

(define drawn (random-schedule big 12345))

(test-equal "random-schedule: the feeds start at 0, join end to start, and end at the length"
  #t
  (contiguous? (spans (car drawn)) 5000))

(test-equal "random-schedule: the bytes fed are the input, in order"
  big
  (fed (car drawn)))

(test-equal "random-schedule: every feed is 0 to 64 bytes"
  #t
  (for-all (lambda (sp) (<= 0 (- (cadr sp) (car sp)) 64)) (spans (car drawn))))

(test-equal "random-schedule: over ten states, feeds are empty and feeds are not"
  '(#t #t)
  (let ((lens (apply append
                     (map (lambda (st)
                            (map (lambda (sp) (- (cadr sp) (car sp)))
                                 (spans (car (random-schedule big st)))))
                          '(1 2 3 4 5 6 7 8 9 10)))))
    (list (and (memv 0 lens) #t) (exists positive? lens))))

(test-equal "random-schedule: the same state gives the same schedule and state"
  #t
  (let ((again (random-schedule big 12345)))
    (and (equal? (spans (car again)) (spans (car drawn)))
         (equal? (cdr again) (cdr drawn)))))

(test-equal "random-schedule: another state gives another schedule"
  #f
  (equal? (spans (car (random-schedule big 54321))) (spans (car drawn))))

(test-equal "random-schedule: the state moves on"
  #f
  (equal? (cdr drawn) 12345))

(test-equal "random-schedule: feeds scale with the input: 12 bytes in feeds of 0 to 3, 1 byte in feeds of 0 to 1"
  '(#t #t #t)
  (let ((twelve (random-schedule (bytes "abcdefghijkl") 777))
        (one (random-schedule (bytes "a") 777)))
    (list (for-all (lambda (sp) (<= 0 (- (cadr sp) (car sp)) 3)) (spans (car twelve)))
          (for-all (lambda (sp) (<= 0 (- (cadr sp) (car sp)) 1)) (spans (car one)))
          (> (length (spans (car twelve))) 3))))

(test-equal "random-schedule: a 12-byte input over ten states has some feed of 3 bytes"
  #t
  (exists (lambda (st)
            (exists (lambda (sp) (= 3 (- (cadr sp) (car sp))))
                    (spans (car (random-schedule (bytes "abcdefghijkl") st)))))
          '(1 2 3 4 5 6 7 8 9 10)))

(test-equal "random-schedule: an empty input is one empty feed"
  '((0 0))
  (spans (car (random-schedule (bytes "") 12345))))

;; --- trace-outcome: a hand-built trace for each verdict -------------------------

(test-equal "trace-outcome: a finished last result is accepted"
  '(accepted)
  (answer (lambda ()
            (trace-outcome '(array-start (feed need-input 1 1 1 #f)
                             (finish finished 1 0 1 #f))))))

(test-equal "trace-outcome: an error is rejected, with its code and offset"
  '(rejected invalid-escape 4)
  (answer (lambda ()
            (trace-outcome '(string-start
                             (feed error 4 4 4 (invalid-escape 4 byte e-escape #f #f #f)))))))

(test-equal "trace-outcome: an error at finish is rejected too"
  '(rejected unexpected-eof 3)
  (answer (lambda ()
            (trace-outcome '((feed need-input 3 3 3 #f)
                             (finish error 3 0 3 (unexpected-eof 3 eof value #f #f #f)))))))

(test-equal "trace-outcome: a last result still needing input is other"
  '(other need-input)
  (answer (lambda () (trace-outcome '((feed need-input 3 3 3 #f))))))

(test-equal "trace-outcome: the last result decides, not the first"
  '(accepted)
  (answer (lambda ()
            (trace-outcome '((feed error 9 0 9 (unexpected-byte 9 byte e-unexpected #f #f #f))
                             x (finish finished 9 0 9 #f))))))

;; --- trace-content: hand-built traces ------------------------------------------

(test-equal "trace-content: feed results go, and adjacent chars fragments join"
  '(string-start (chars #vu8(97 98 99)) string-end (accepted))
  (answer (lambda ()
            (trace-content '(string-start (chars #vu8(97)) (feed need-input 2 1 2 #f)
                             (chars #vu8(98 99)) string-end
                             (feed need-input 4 1 4 #f)
                             (finish finished 4 0 4 #f))))))

(test-equal "trace-content: adjacent number fragments join"
  '(array-start (number #vu8(49 50 51)) number-end (accepted))
  (answer (lambda ()
            (trace-content '(array-start (number #vu8(49)) (feed need-input 2 1 2 #f)
                             (number #vu8(50)) (feed need-input 3 1 3 #f)
                             (number #vu8(51)) number-end
                             (finish finished 4 0 4 #f))))))

(test-equal "trace-content: an event between two fragments keeps them apart"
  '((chars #vu8(97)) (escape 10) (chars #vu8(98)) (accepted))
  (answer (lambda ()
            (trace-content '((chars #vu8(97)) (escape 10) (feed need-input 4 4 4 #f)
                             (chars #vu8(98)) (finish finished 5 0 5 #f))))))

(test-equal "trace-content: a chars fragment and a number fragment are not joined"
  '((chars #vu8(97)) (number #vu8(49)) (chars #vu8(98)) (accepted))
  (answer (lambda ()
            (trace-content '((chars #vu8(97)) (number #vu8(49)) (chars #vu8(98))
                             (finish finished 3 0 3 #f))))))

(test-equal "trace-content: an empty fragment joins and adds nothing"
  '((chars #vu8(97)) (accepted))
  (answer (lambda ()
            (trace-content '((chars #vu8()) (feed need-input 1 1 1 #f)
                             (chars #vu8(97)) (feed need-input 2 1 2 #f)
                             (chars #vu8()) (finish finished 2 0 2 #f))))))

(test-equal "trace-content: an error's undelivered span bytes join the last fragment of the span"
  '(string-start (chars #vu8(97 98)) (rejected control-character 3))
  (answer (lambda ()
            (trace-content
             '(string-start (chars #vu8(97)) (feed need-input 2 2 2 #f)
               (feed error 3 1 3 (control-character 3 byte e-control chars 2 #vu8(98))))))))

(test-equal "trace-content: undelivered bytes with no fragment before them become one"
  '(string-start (chars #vu8(97 98)) (rejected control-character 3))
  (answer (lambda ()
            (trace-content
             '(string-start
               (feed error 3 3 3 (control-character 3 byte e-control chars 1 #vu8(97 98))))))))

(test-equal "trace-content: undelivered number bytes join a number fragment, not a chars one"
  '(array-start (chars #vu8(120)) (number #vu8(49 50)) (rejected invalid-number 4))
  (answer (lambda ()
            (trace-content
             '(array-start (chars #vu8(120)) (number #vu8(49))
               (feed error 4 1 4 (invalid-number 4 byte e-number number 2 #vu8(50))))))))

(test-equal "trace-content: undelivered bytes come after an escape, apart from the chars before it"
  '((chars #vu8(97)) (escape 10) (chars #vu8(98)) (rejected control-character 6))
  (answer (lambda ()
            (trace-content
             '((chars #vu8(97)) (escape 10)
               (feed error 6 2 6 (control-character 6 byte e-control chars 5 #vu8(98))))))))

(test-equal "trace-content: an error without a span adds nothing"
  '(array-start (rejected unexpected-byte 2))
  (answer (lambda ()
            (trace-content
             '(array-start (feed error 2 2 2 (unexpected-byte 2 byte e-unexpected #f #f #f)))))))

(test-equal "trace-content: the same content under two schedules is the same"
  #t
  (equal? (trace-content
           '(string-start (chars #vu8(97 98)) string-end (feed need-input 4 4 4 #f)
             (finish finished 4 0 4 #f)))
          (trace-content
           '(string-start (chars #vu8(97)) (feed need-input 2 1 2 #f)
             (chars #vu8(98)) string-end (feed need-input 4 2 4 #f)
             (finish finished 4 0 4 #f)))))

;; --- run-machine: whole traces, written by hand --------------------------------

(test-equal "run-machine: [1} in one feed is rejected at the }, after asking context"
  '(array-start (number #vu8(49)) number-end (context array)
    (feed error 2 2 2 (unexpected-byte 2 byte e-unexpected #f #f #f)
     e-unexpected #f (1 511 0 0)))
  (whole "[1}"))

(test-equal "run-machine: [1} in feeds of 1 byte, the result of each feed"
  '(array-start (feed need-input 1 1 1 #f arr-first #f (1 511 0 0))
    (number #vu8(49)) (feed need-input 2 1 2 #f num-int number (1 511 0 0))
    number-end (context array)
    (feed error 2 0 2 (unexpected-byte 2 byte e-unexpected #f #f #f)
     e-unexpected #f (1 511 0 0)))
  (by1 "[1}"))

(test-equal "run-machine: {\"a\":1] is rejected at the ]: the object is the context"
  '(object-start key-start (chars #vu8(97)) key-end (number #vu8(49)) number-end
    (context object)
    (feed error 6 6 6 (unexpected-byte 6 byte e-unexpected #f #f #f)
     e-unexpected #f (1 511 0 0)))
  (whole "{\"a\":1]"))

(test-equal "run-machine: [{\"a\":1] is rejected at the ]"
  '(array-start object-start key-start (chars #vu8(97)) key-end (number #vu8(49))
    number-end (context object)
    (feed error 7 7 7 (unexpected-byte 7 byte e-unexpected #f #f #f)
     e-unexpected #f (2 510 0 0)))
  (whole "[{\"a\":1]"))

(test-equal "run-machine: {\"a\":[1} is rejected at the }: the array is the context"
  '(object-start key-start (chars #vu8(97)) key-end array-start (number #vu8(49))
    number-end (context array)
    (feed error 7 7 7 (unexpected-byte 7 byte e-unexpected #f #f #f)
     e-unexpected #f (2 510 0 0)))
  (whole "{\"a\":[1}"))

(test-equal "run-machine: [[1],{\"a\":[]}] is accepted; context answers array, array, object, array"
  '(array-start array-start (number #vu8(49)) number-end (context array)
    array-end (context array)
    object-start key-start (chars #vu8(97)) key-end array-start array-end
    (context object) object-end (context array) array-end
    (feed need-input 14 14 14 #f top-done #f (0 512 0 0))
    (finish finished 14 0 14 #f done #f (0 512 0 0)))
  (whole "[[1],{\"a\":[]}]"))

(test-equal "run-machine: {\"a\":{\"b\":[{}]}} is accepted; the stack pops one level per close"
  '(object-start key-start (chars #vu8(97)) key-end
    object-start key-start (chars #vu8(98)) key-end
    array-start object-start object-end (context array)
    array-end (context object) object-end (context object) object-end
    (feed need-input 16 16 16 #f top-done #f (0 512 0 0))
    (finish finished 16 0 16 #f done #f (0 512 0 0)))
  (whole "{\"a\":{\"b\":[{}]}}"))

(test-equal "run-machine: a feed after an error is not made"
  '(array-start (number #vu8(49)) number-end (context array)
    (feed error 2 2 2 (unexpected-byte 2 byte e-unexpected #f #f #f)
     e-unexpected #f (1 511 0 0)))
  (run "[1}]]]" (lambda (bv) (chunk-schedule bv 3))))

(test-equal "run-machine: a string with an escape and the empty fragment after it"
  '(string-start (chars #vu8(97)) (escape 10) (chars #vu8()) string-end
    (feed need-input 5 5 5 #f top-done #f (0 512 10 0))
    (finish finished 5 0 5 #f done #f (0 512 10 0)))
  (whole "\"a\\n\""))

(test-equal "run-machine: an error inside a chars span keeps the span's bytes as undelivered"
  '(string-start
    (feed error 3 3 3 (control-character 3 byte e-control chars 1 #vu8(97 98))
     e-control chars (0 512 0 0)))
  (answer (lambda () (run-machine generated-machine (whole-schedule (bv 34 97 98 1 34)) '()))))

(test-equal "run-machine: the same, in feeds of 2: one chars fragment delivered, one byte undelivered"
  '(string-start (chars #vu8(97)) (feed need-input 2 2 2 #f str-chars chars (0 512 0 0))
    (feed error 3 1 3 (control-character 3 byte e-control chars 2 #vu8(98))
     e-control chars (0 512 0 0)))
  (answer (lambda ()
            (run-machine generated-machine (chunk-schedule (bv 34 97 98 1 34) 2) '()))))

(test-equal "run-machine: an empty input finishes in error, unexpected-eof at 0"
  '((feed need-input 0 0 0 #f value #f (0 512 0 0))
    (finish error 0 0 0 (unexpected-eof 0 eof value #f #f #f) value #f (0 512 0 0)))
  (whole ""))

;; --- the views of a real run ----------------------------------------------------

(test-equal "trace-content of a run: one feed and 2-byte feeds of an error in a span agree"
  '(string-start (chars #vu8(97 98)) (rejected control-character 3))
  (answer (lambda ()
            (trace-content
             (run-machine generated-machine (chunk-schedule (bv 34 97 98 1 34) 2) '())))))

(test-equal "trace-content of a run: one feed gives the same"
  '(string-start (chars #vu8(97 98)) (rejected control-character 3))
  (answer (lambda ()
            (trace-content
             (run-machine generated-machine (whole-schedule (bv 34 97 98 1 34)) '())))))

(test-equal "trace-outcome of a run: [1} is rejected at 2; [1] is accepted"
  '((rejected unexpected-byte 2) (accepted))
  (answer (lambda ()
            (list (trace-outcome (whole "[1}")) (trace-outcome (whole "[1]"))))))

(test-equal "interpreted-machine gives the trace the generated one does, on [[1],{\"a\":[]}]"
  (whole "[[1],{\"a\":[]}]")
  (answer (lambda ()
            (run-machine interpreted-machine (whole-schedule (bytes "[[1],{\"a\":[]}]")) '()))))

(test-equal "corpus-files: names with the suffix, sorted"
  #t
  (let ((names (corpus-files "tests/corpus/jsontestsuite/test_parsing" ".json")))
    (and (> (length names) 300)
         (equal? names (list-sort string<? names))
         (for-all (lambda (n) (> (string-length n) 5)) names))))

(test-end "machine-driver")

(exit (suite-exit-status runner))
