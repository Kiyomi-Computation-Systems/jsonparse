;;; tests/test-bench-callbacks.sps: (jsonparse-bench callbacks), the lanes
;;; `make bench-callbacks` times to split the callback path's cost (ADR-0025).
;;;
;;;   1. the lanes, what each m- lane binds of byte-machine's callbacks, and
;;;      what the parse and j-noop lanes' handlers have;
;;;   2. m-count's counts: by hand on one document, and equal to the events
;;;      lane's on several; and the calls m-noop delivers, by hand;
;;;   3. every lane's thunk and tally, and a refusal of what isn't one
;;;      document;
;;;   4. the tally check bench/callbacks.sps runs on every lane, and the
;;;      order in which the lanes take turns;
;;;   5. the split per value, and the report, each whole.
;;;
;;; The document counts each of the ten names a different number of times,
;;; so a count under the wrong name changes the whole output.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-bench)
        (jsonparse-bench callbacks))

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

(define (bytes s) (string->utf8 s))

;; null 1, true 2, false 3, numbers 4 (1, -22, 3.5e1 and 4: 10 bytes of
;; text), strings 5 (s, e acute, a surrogate pair, x\ny and the empty one:
;; 10 bytes decoded), keys 6 (a, b, c, d\u0041, e and f: 7 bytes decoded),
;; objects 7 and arrays 8.
(define doc (bytes "{\"a\":[null,true,true,false,false,false,1,-22,3.5e1,4,\"s\",\"\\u00e9\",\"\\ud83d\\ude00\",\"x\\ny\",\"\"],\"b\":{},\"c\":[{},{},{},[],[[]]],\"d\\u0041\":{\"e\":{},\"f\":[[],[]]}}"))

(define doc-counts
  '((null . 1) (true . 2) (false . 3) (number . 4) (string . 5) (key . 6)
    (object . 7) (array . 8) (number-bytes . 10) (text-bytes . 17)))

(define (times counts n) (map (lambda (c) (cons (car c) (* n (cdr c)))) counts))

(test-begin "bench-callbacks")

;; --- 1. the lanes ---------------------------------------------------------------

(test-equal "callback-lanes: the eight, in the report's order"
  '(parse m-events m-spans m-noop m-count m-all j-noop events)
  callback-lanes)

(test-equal "counted-names: what (jsonparse parser) binds for the counting handler, beside the stack's"
  '(null true false number-data number-end chars-data escape string-end key-end)
  counted-names)

(define stack '(object-start object-end array-start array-end context))

(test-equal "machine-bound: each m- lane binds the stack's callbacks, then its own"
  (list (append stack '(null true false number-end escape string-end key-end))
        (append stack '(number-data chars-data))
        (append stack counted-names)
        (append stack counted-names)
        (append stack counted-names '(string-start key-start)))
  (map machine-bound '(m-events m-spans m-noop m-count m-all)))

(test-equal "machine-bound: m-noop binds exactly what m-count binds"
  (machine-bound 'm-count)
  (machine-bound 'm-noop))

(test-equal "machine-bound: a lane that isn't the machine's raises"
  '(machine-bound machine-bound machine-bound machine-bound)
  (map (lambda (lane) (raise-who (lambda () (machine-bound lane)))) '(parse j-noop events m-calls)))

(test-equal "json-bound: parse's handler has no procedures, j-noop's all fourteen"
  '(()
    (null boolean number-chars number-end string-start chars escape string-end
     object-start key-start key-end object-end array-start array-end))
  (map json-bound '(parse j-noop)))

(test-equal "json-bound: any other lane raises"
  '(json-bound json-bound)
  (map (lambda (lane) (raise-who (lambda () (json-bound lane)))) '(events m-noop)))

;; --- 2. m-count's counts, and the calls ---------------------------------------------

(test-equal "machine-counts: the document's counts, by hand"
  doc-counts
  (machine-counts doc))

(test-equal "value-count: the eight kinds, keys included"
  36
  (value-count doc-counts))

(define docs
  (map bytes
       (list "[]" "{}" "0" "\"\"" "-0.5e-7" "null"
             "[\"\\ud800\\udc00\",{\"\\u0000\":null,\"\\\\\":[true,false]}]"
             "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]"
             "{\"k\":\"a long text of fifty bytes, more or less, plain\"}")))

(test-equal "machine-counts: what the events lane counts, on each document"
  (map events-counts (cons doc docs))
  (map machine-counts (cons doc docs)))

(test-equal "machine-counts: raises unless the bytes are one document"
  '(machine-counts machine-counts machine-counts)
  (map (lambda (s) (raise-who (lambda () (machine-counts (bytes s))))) '("[1," "1 2" "{\"a\"}")))

;; By hand: a number is a part and its end; true, null, a key's end and a
;; string's end are one call each; a text is a part, or one empty part when
;; it is empty, and an escape is a call between parts.
(test-equal "machine-calls: the counted callbacks byte-machine calls, by hand"
  '(5 3 2 4 0)
  (map (lambda (s) (machine-calls (bytes s)))
       '("[1,true,\"ab\"]" "{\"k\":null}" "\"\"" "\"a\\nb\"" "[[],{}]")))

(test-equal "machine-calls: raises unless the bytes are one document"
  'machine-calls
  (raise-who (lambda () (machine-calls (bytes "[1,")))))

;; --- 3. the lanes' thunks -------------------------------------------------------

(test-equal "callback-lane-thunk: three passes of each lane, counted; m-count and events count too"
  (map (lambda (lane)
         (cons 3 (if (memq lane '(m-count events)) (times doc-counts 3) '())))
       callback-lanes)
  (map (lambda (lane)
         (let-values (((run tally) (callback-lane-thunk lane doc)))
           (run) (run) (run)
           (tally)))
       callback-lanes))

(test-equal "callback-lane-thunk: each lane's pass raises unless the bytes are one document"
  (map (lambda (lane) 'callback-lane-thunk) callback-lanes)
  (map (lambda (lane)
         (let-values (((run tally) (callback-lane-thunk lane (bytes "[1,"))))
           (raise-who run)))
       callback-lanes))

(test-equal "callback-lane-thunk: an unknown lane raises"
  '(callback-lane-thunk callback-lane-thunk)
  (map (lambda (lane) (raise-who (lambda () (callback-lane-thunk lane doc)))) '(scan m-calls)))

;; --- 4. the tally check, and the turns ------------------------------------------

(test-equal "check-tally: a counting lane that counted the passes' counts, and a lane that counts nothing"
  '(ok ok)
  (list (check-tally 'events doc-counts 4 (cons 4 (times doc-counts 4)))
        (check-tally 'm-noop doc-counts 4 (cons 4 '()))))

(test-equal "check-tally: raises for passes short, alone or with their counts, counts off, counts missing, or counts where none are"
  '(check-tally check-tally check-tally check-tally check-tally)
  (list (raise-who (lambda () (check-tally 'm-noop doc-counts 4 (cons 3 '()))))
        (raise-who (lambda () (check-tally 'm-count doc-counts 4 (cons 3 (times doc-counts 3)))))
        (raise-who (lambda () (check-tally 'm-count doc-counts 4 (cons 4 (times doc-counts 3)))))
        (raise-who (lambda () (check-tally 'events doc-counts 4 (cons 4 '()))))
        (raise-who (lambda () (check-tally 'j-noop doc-counts 4 (cons 4 (times doc-counts 4)))))))

;; Three thunks noting themselves, two passes a round, three turns: a
;; warm-up round of each in order, then turns starting at 0, 1 and 2.
(let* ((log '())
       (thunks (map (lambda (i) (lambda () (set! log (cons i log)))) '(0 1 2)))
       (times (measure-interleaved thunks 2 3)))
  (test-equal "measure-interleaved: a warm-up round of each, then each turn one lane later"
    '(0 0 1 1 2 2  0 0 1 1 2 2  1 1 2 2 0 0  2 2 0 0 1 1)
    (reverse log))
  (test-equal "measure-interleaved: three rounds of whole nanoseconds for each thunk"
    '((#t #t #t) (#t #t #t) (#t #t #t))
    (map (lambda (l) (map (lambda (ns) (and (integer? ns) (exact? ns) (>= ns 0))) l)) times)))

;; --- 5. the split and the report ------------------------------------------------

;; Five turns of each lane, in ns a pass, for ten values. Each split's
;; differences, turn by turn, are their own numbers, so the median of
;; paired differences differs from the difference of medians, the middle
;; half from the least and most, and a split of the wrong two lanes from
;; every expected one.
(define turns
  '((parse 100 200 300 400 500) (m-events 120 210 340 430 550) (m-spans 160 280 340 420 600)
    (m-noop 150 210 390 430 570) (m-count 190 250 430 470 610) (m-all 160 220 400 440 580)
    (j-noop 190 280 490 560 730) (events 260 250 570 680 890)))

(test-equal "callback-split: each split's median a value, and its middle half"
  '((byte-machine 5 3 7) (its-events 3 2 4) (its-spans 6 4 8) (counting 4 4 4)
    (jsonparse 14 7 21) (jsonparse-all 9 6 12) (all 27 16 28))
  (callback-split 10 turns))

(test-equal "callback-split: raises when a lane is missing, or two lanes ran different rounds"
  '(callback-split callback-split)
  (list (raise-who (lambda () (callback-split 10 (cdr turns))))
        (raise-who (lambda () (callback-split 10 (cons '(parse 100 200 300 400) (cdr turns)))))))

(define machine
  '((date . "2026-11-09") (cpu . "Some CPU") (arch . "x86_64") (os . "Linux 7")
    (pin . "CPU 7, at most 4500 MHz, governor powersave")))

(define (same x) (list x x x))

(define rows
  (list (list "big.json" 320189 50000 100000
              '((parse 1880000 1890000 1900000) (m-events 2030000 2050000 2070000)
                (m-spans 2055000 2070000 2085000) (m-noop 2180000 2210000 2240000)
                (m-count 2305000 2340000 2375000) (m-all 2240000 2270000 2300000)
                (j-noop 2470000 2510000 2550000) (events 2445000 2485000 2525000)))
        (list "few.json" 245004 2 9
              (map (lambda (lane ns) (cons lane (same ns)))
                   callback-lanes '(932600 969200 1018800 1046800 1277600 1100000 1306900 1344400)))))

(test-equal "callbacks-text: the whole report"
  (string-append
   "# jsonparse's callback path\n"
   "\n"
   "- **Date (UTC):** 2026-11-09\n"
   "- **Machine:** Some CPU, x86_64, Linux 7\n"
   "- **Pinned:** CPU 7, at most 4500 MHz, governor powersave\n"
   "- **jsonparse:** Chez 10.4.1\n"
   "- **Method:** a warm-up round of each lane, then 9 turns in which each lane has a timed round of at least 20,000,000 bytes, a new parser a pass (ADR-0023, ADR-0025). Each turn starts one lane later.\n"
   "\n"
   "## The lanes\n"
   "\n"
   "Microseconds a pass, the median round. `parse` binds byte-machine's callbacks for the stack alone. `m-events`, `m-spans` and `m-noop` bind, beside the stack's, the callbacks jsonparse binds for `events`: those that carry no bytes, the two that do, or both, to procedures that do nothing; `m-count` counts in them as `events` does, and `m-all` adds `string-start` and `key-start` to `m-noop`. `j-noop` binds jsonparse's fourteen procedures, doing nothing, and `events` is the events lane.\n"
   "\n"
   "| File | Bytes | Values | parse | m-events | m-spans | m-noop | m-count | m-all | j-noop | events |\n"
   "|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n"
   "| big.json | 320,189 | 50,000 | 1890.0 | 2050.0 | 2070.0 | 2210.0 | 2340.0 | 2270.0 | 2510.0 | 2485.0 |\n"
   "| few.json | 245,004 | 2 | 932.6 | 969.2 | 1018.8 | 1046.8 | 1277.6 | 1100.0 | 1306.9 | 1344.4 |\n"
   "\n"
   "## Per value\n"
   "\n"
   "Nanoseconds a value, keys included: the median of the turns' differences between two lanes, then the least and most of their middle half. `calls` is how many callbacks `m-noop` delivers a value that `parse` doesn't. `byte-machine` is `m-noop` less `parse`, and `its events` and `its spans` are `m-events` and `m-spans` less `parse`; `counting` is `m-count` less `m-noop`; `jsonparse` is `events` less `m-count`, and `all fourteen` is `j-noop` less `m-all`; `all` is `events` less `parse`. A file of fewer than 1,000 values gets none.\n"
   "\n"
   "| File | calls | byte-machine | its events | its spans | counting | jsonparse | all fourteen | all |\n"
   "|:--|--:|--:|--:|--:|--:|--:|--:|--:|\n"
   "| big.json | 2.0 | 6.4 [6.0, 6.8] | 3.2 [3.0, 3.4] | 3.6 [3.5, 3.7] | 2.6 [2.5, 2.7] | 2.9 [2.8, 3.0] | 4.8 [4.6, 5.0] | 11.9 [11.3, 12.5] |\n"
   "| few.json | - | - | - | - | - | - | - | - |\n")
  (callbacks-text machine "Chez 10.4.1" 9 20000000 rows))

(test-end "bench-callbacks")

(exit (suite-exit-status runner))
