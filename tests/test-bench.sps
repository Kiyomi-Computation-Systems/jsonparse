#!r6rs
;;; tests/test-bench.sps: the benchmark harness's own core, (jsonparse-bench)
;;; and (jsonparse-bench report) (ADR-0013, ADR-0023). The timings are the
;;; harness's to take; this suite holds what decides whether a timing means
;;; anything:
;;;
;;;   1. composition, the scan lane, classifies every byte: inside a string
;;;      (quotes and escapes included), number text, whitespace, or other;
;;;   2. the events lane's counting handler counts each kind of value and the
;;;      text it saw, however the input is split, one count per parser;
;;;   3. tree-counts counts a built value as the handler counts the text, so
;;;      the two agree on JSONTestSuite's y_ files and nativejson-benchmark's
;;;      round trips, as composition's number bytes do;
;;;   4. the statistics: median, MB/s in 10^6 bytes, iterations per round,
;;;      and measure, which times rounds after a warm-up round;
;;;   5. the synthetic files are M0's, byte for byte in length and shape;
;;;   6. the report cross-checks the plan, every runtime, and every lane of
;;;      each parser the plan names before it prints; gives no rate to a
;;;      comparator's lane that fails or disagrees with jsonparse's events;
;;;      and prints exactly the texts below (ADR-0024).
(import (rnrs)
        (only (chezscheme) make-time sleep collect statistics sstats-gc-count)
        (srfi :64)
        (jsonparse-testing)
        (only (jsonparse-testing machine) corpus-files)
        (jsonparse parser)
        (jsonparse easy)
        (jsonparse-bench)
        (jsonparse-bench report))

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

(define (u8 s) (string->utf8 s))

(define (read-bytes path)
  (call-with-port (open-file-input-port path) get-bytevector-all))

;; raise-who : (-> Any) -> (U 'no-raise Symbol)
;; What THUNK's raise names as its who, 'no-who for a raise naming none,
;; or 'no-raise. A raise from deeper down, such as list-ref's or div's,
;; names another who than the check a test means.
(define (raise-who thunk)
  (guard (e ((who-condition? e) (condition-who e))
            (#t 'no-who))
    (thunk)
    'no-raise))

;; One document reaching every kind: an escaped key, both literals, null, a
;; negative exponent number, an escaped quote, an empty object and an empty
;; array.
(define doc
  "{\"a\\u00e9\": [1, -2.5e3, true, false, null, \"x\\\"y\", {}], \"b\": []}")

(define doc-counts
  '((null . 1) (true . 1) (false . 1) (number . 2) (string . 1) (key . 2)
    (object . 2) (array . 2) (number-bytes . 7) (text-bytes . 7)))

(define (without-number-bytes counts)
  (filter (lambda (p) (not (eq? (car p) 'number-bytes))) counts))

(test-begin "bench")

;; --- 1. composition ----------------------------------------------------------

(test-equal "composition of the document"
  '((string . 18) (number . 7) (whitespace . 9) (other . 30))
  (composition (u8 doc)))

(test-equal "the document is 64 bytes, so composition covered each once"
  64 (bytevector-length (u8 doc)))

(test-equal "JSON's four whitespace bytes, and nothing else, are whitespace"
  '((string . 0) (number . 1) (whitespace . 5) (other . 3))
  (composition (u8 "\t[\r\n1 ]\n\f")))

(test-equal "the e of true and false is not number text; an exponent's is"
  '((string . 0) (number . 3) (whitespace . 0) (other . 13))
  (composition (u8 "[1e5,true,false]")))

(test-equal "an exponent's sign and a fraction are number text"
  '((string . 0) (number . 7) (whitespace . 0) (other . 2))
  (composition (u8 "[-0.5E-3]")))

(test-equal "a backslash at the very end ends the text it escapes"
  '((string . 3) (number . 0) (whitespace . 0) (other . 0))
  (composition (u8 "\"a\\")))

(test-equal "an escaped backslash does not escape the closing quote"
  '((string . 5) (number . 1) (whitespace . 1) (other . 3))
  (composition (u8 "[\"a\\\\\", 1]")))

(test-equal "an escaped quote does not close the string"
  '((string . 8) (number . 0) (whitespace . 0) (other . 2))
  (composition (u8 "[\"a\\\"],1\"]")))

(test-equal "a number at the end of the input is number text"
  '((string . 0) (number . 3) (whitespace . 0) (other . 0))
  (composition (u8 "-12")))

(test-equal "digits inside a string are string bytes"
  '((string . 5) (number . 0) (whitespace . 0) (other . 0))
  (composition (u8 "\"1 2\"")))

;; --- 2. the counting handler -------------------------------------------------

(test-equal "the scalar's UTF-8 length either side of each boundary"
  '(1 1 1 2 2 3 3 4 4)
  (map utf8-length/scalar '(#x0 #x41 #x7F #x80 #x7FF #x800 #xFFFF #x10000 #x10FFFF)))

(test-equal "the counting handler counts the document"
  doc-counts
  (events-counts (u8 doc)))

(test-equal "fed a byte at a time, it counts the same"
  doc-counts
  (let ((counts (make-counts)) (bv (u8 doc)))
    (let ((p (make-json-parser counting-handler counts)))
      (do ((i 0 (+ i 1))) ((= i (bytevector-length bv)))
        (json-parser-feed! p bv i (+ i 1)))
      (json-parser-finish! p)
      (counts->alist counts))))

(test-equal "a surrogate pair is one scalar of four UTF-8 bytes"
  '((null . 0) (true . 0) (false . 0) (number . 0) (string . 1) (key . 0)
    (object . 0) (array . 0) (number-bytes . 0) (text-bytes . 6))
  (events-counts (u8 "\"\\ud83d\\ude00\\n\\u0041\"")))

(test-equal "two parsers interleaved keep their own counts"
  (list doc-counts
        '((null . 0) (true . 0) (false . 0) (number . 3) (string . 0) (key . 0)
          (object . 0) (array . 1) (number-bytes . 3) (text-bytes . 0)))
  (let* ((a (u8 doc)) (b (u8 "[1,2,3]"))
         (ca (make-counts)) (cb (make-counts))
         (pa (make-json-parser counting-handler ca))
         (pb (make-json-parser counting-handler cb)))
    (json-parser-feed! pa a 0 20)
    (json-parser-feed! pb b 0 3)
    (json-parser-feed! pa a 20 (bytevector-length a))
    (json-parser-feed! pb b 3 (bytevector-length b))
    (json-parser-finish! pa)
    (json-parser-finish! pb)
    (list (counts->alist ca) (counts->alist cb))))

(test-equal "events-counts raises on text that is not JSON"
  'events-counts
  (raise-who (lambda () (events-counts (u8 "[1,")))))

;; --- 3. tree-counts against the handler --------------------------------------

(test-equal "tree-counts counts the document as the handler does"
  (without-number-bytes doc-counts)
  (tree-counts (bytevector->json (u8 doc))))

(test-equal "an empty object, the empty list, is an object"
  '((null . 0) (true . 0) (false . 0) (number . 0) (string . 0) (key . 0)
    (object . 1) (array . 0) (text-bytes . 0))
  (tree-counts (bytevector->json (u8 "{}"))))

(test-equal "an empty array and an empty object inside one"
  '((null . 0) (true . 0) (false . 0) (number . 0) (string . 0) (key . 0)
    (object . 1) (array . 2) (text-bytes . 0))
  (tree-counts (bytevector->json (u8 "[{}, []]"))))

(test-equal "a key's and a string's text are counted as UTF-8"
  '((null . 0) (true . 0) (false . 0) (number . 0) (string . 1) (key . 1)
    (object . 1) (array . 0) (text-bytes . 7))
  (tree-counts (bytevector->json (u8 "{\"\\u00e9\": \"\\ud83d\\ude00a\"}"))))

(test-equal "tree-counts refuses what JSON's tree never holds"
  '(tree-counts tree-counts tree-counts)
  (map (lambda (value) (raise-who (lambda () (tree-counts value))))
       (list (list (cons 'k 1)) (vector #\a) 'nil)))

(define corpus
  (append
   (map (lambda (f) (string-append "tests/corpus/jsontestsuite/test_parsing/" f))
        (filter (lambda (f) (char=? #\y (string-ref f 0)))
                (corpus-files "tests/corpus/jsontestsuite/test_parsing" ".json")))
   (map (lambda (f) (string-append "tests/corpus/nativejson-benchmark/files/" f))
        (corpus-files "tests/corpus/nativejson-benchmark/files" ".json"))))

(test-equal "the corpus is JSONTestSuite's 95 y_ files and 27 round trips"
  122 (length corpus))

(test-equal "on every corpus file, tree-counts agrees with the handler"
  '()
  (filter (lambda (path)
            (let ((bv (read-bytes path)))
              (not (equal? (without-number-bytes (events-counts bv))
                           (tree-counts (bytevector->json bv))))))
          corpus))

(test-equal "on every corpus file, composition's number bytes are the handler's"
  '()
  (filter (lambda (path)
            (let ((bv (read-bytes path)))
              (not (= (cdr (assq 'number (composition bv)))
                      (cdr (assq 'number-bytes (events-counts bv)))))))
          corpus))

(test-equal "on every corpus file, composition covers each byte once"
  '()
  (filter (lambda (path)
            (let ((bv (read-bytes path)))
              (not (= (bytevector-length bv)
                      (apply + (map cdr (composition bv)))))))
          corpus))

;; --- 4. the statistics -------------------------------------------------------

(test-equal "the median of an odd count is the middle one, in any order"
  '(20 5)
  (list (median '(30 10 20)) (median '(5))))

(test-equal "the median of an even count is the mean of the middle two"
  '(25 51/2)
  (list (median '(40 10 30 20)) (median '(26 25))))

(test-equal "the median of nothing raises"
  'median
  (raise-who (lambda () (median '()))))

(test-equal "MB/s counts 10^6 bytes a megabyte"
  '(1.0 6.0 1.048576)
  (list (mb/s 1000000 1 1000000000)
        (mb/s 2000000 3 1000000000)
        (mb/s 1048576 1 1000000000)))

(test-equal "iterations per round: the fewest that read the round's bytes"
  '(20 7 1 1)
  (map (lambda (size) (iterations-for size 20000)) '(1000 3000 20000 30000)))

(test-equal "iterations-for raises on an empty file or an empty round"
  '(iterations-for iterations-for)
  (map (lambda (args) (raise-who (lambda () (apply iterations-for args))))
       '((0 20000) (1000 0))))

(test-equal "measure calls the thunk for a warm-up round and then each timed round"
  '(5 18 #t)
  (let ((calls 0))
    (let-values (((ns allocated gc-ns)
                  (measure (lambda () (set! calls (+ calls 1))) 3 5)))
      (list (length ns) calls
            (and (for-all (lambda (n) (and (exact? n) (integer? n) (>= n 0))) ns)
                 (exact? gc-ns) (>= gc-ns 0))))))

;; Each round starts from a full collection, the warm-up's included, so a
;; thunk that allocates nothing sees one collection per round, and perhaps
;; one Chez starts for measure's own allocation.
(test-equal "measure collects before the warm-up round and before each timed round"
  #t
  (let ((before (sstats-gc-count (statistics))))
    (measure (lambda () #f) 1 4)
    (<= 5 (- (sstats-gc-count (statistics)) before) 6)))

(test-equal "duration->ns counts the seconds too"
  '(2000000005 999999999 0)
  (map duration->ns
       (list (make-time 'time-duration 5 2) (make-time 'time-duration 999999999 0)
             (make-time 'time-duration 0 0))))

;; A round of one pass that sleeps 10 ms takes at least 10 ms of wall
;; time, and far less than a second: the clock is monotonic wall time, not
;; the thread's CPU time, which sleeping doesn't spend.
(test-equal "measure times by the wall clock"
  #t
  (let-values (((ns allocated gc-ns)
                (measure (lambda () (sleep (make-time 'time-duration 10000000 0))) 1 1)))
    (<= 10000000 (car ns) 500000000)))

(test-equal "measure counts the collections inside its rounds, and only there"
  #t
  (let-values (((ns allocated gc-ns) (measure (lambda () (collect)) 2 3)))
    (< 0 gc-ns (apply + ns))))

;; A thunk allocating a 1,000-byte bytevector, 3 times a round for 5 timed
;; rounds, allocates 15,000 bytes and some headers. The warm-up round
;; would add 3,000 more.
(test-equal "measure counts the timed rounds' allocation, not the warm-up's"
  #t
  (let-values (((ns allocated gc-ns) (measure (lambda () (make-bytevector 1000)) 3 5)))
    (<= 15000 allocated 17000)))

(define (thunk-of lane bv)
  (let-values (((thunk tally) (lane-thunk lane bv))) thunk))

(test-equal "every lane parses a document"
  '(no-raise no-raise no-raise no-raise no-raise)
  (map (lambda (lane) (raise-who (thunk-of lane (u8 doc))))
       '(parse events tree tree+walk scan)))

(test-equal "every lane but scan raises on text that is not JSON, naming its check"
  '(parse events bytevector->json bytevector->json no-raise)
  (map (lambda (lane) (raise-who (thunk-of lane (u8 "[1, 2"))))
       '(parse events tree tree+walk scan)))

;; times : Nat (Listof (Pair Symbol Nat)) -> same, each count times N
(define (times n counts) (map (lambda (p) (cons (car p) (* n (cdr p)))) counts))

(test-equal "a lane's tally sums what its passes counted"
  (list (cons 3 '())
        (cons 3 (times 3 doc-counts))
        (cons 3 '())
        (cons 3 (times 3 (without-number-bytes doc-counts)))
        (cons 3 (times 3 (composition (u8 doc)))))
  (map (lambda (lane)
         (let-values (((thunk tally) (lane-thunk lane (u8 doc))))
           (thunk) (thunk) (thunk)
           (tally)))
       '(parse events tree tree+walk scan)))

(test-equal "a tally before any pass is zero passes and no counts"
  '((0) (0 (null . 0) (true . 0) (false . 0) (number . 0) (string . 0) (key . 0)
           (object . 0) (array . 0) (number-bytes . 0) (text-bytes . 0))
    (0) (0) (0))
  (map (lambda (lane)
         (let-values (((thunk tally) (lane-thunk lane (u8 doc)))) (tally)))
       '(parse events tree tree+walk scan)))

(test-equal "a pass that raises is not tallied"
  '(0 0 0 0)
  (map (lambda (lane)
         (let-values (((thunk tally) (lane-thunk lane (u8 "[1, 2"))))
           (raise-who thunk)
           (car (tally))))
       '(parse events tree tree+walk)))

(test-equal "two lanes of one kind keep their own tallies"
  (list (cons 2 (times 2 doc-counts))
        (cons 1 (events-counts (u8 "[1,2,3]"))))
  (let-values (((ta tally-a) (lane-thunk 'events (u8 doc)))
               ((tb tally-b) (lane-thunk 'events (u8 "[1,2,3]"))))
    (ta) (tb) (ta)
    (list (tally-a) (tally-b))))

(test-equal "the lanes, in the order the report gives them"
  '(parse events tree tree+walk scan)
  lanes)

;; --- 5. the synthetic files ----------------------------------------------------

(test-equal "M0's three synthetic files, by name"
  '("ints-40k.json" "records-2k.json" "escaped-string.json")
  (map car synthetic-files))

(test-equal "each at M0's size"
  '(228891 320189 245004)
  (map (lambda (f) (bytevector-length ((cdr f)))) synthetic-files))

(test-equal "ints, small"
  "[0,1,2]"
  (utf8->string (synthetic-ints 3)))

(test-equal "records, small"
  "[{\"id\":0,\"name\":\"user-0\",\"email\":\"u0@example.com\",\"score\":0.5,\"active\":true,\"tags\":[\"a\",\"b\",\"c\"],\"addr\":{\"city\":\"Tokyo\",\"zip\":\"100-0\"},\"note\":null},{\"id\":1,\"name\":\"user-1\",\"email\":\"u1@example.com\",\"score\":3.5,\"active\":false,\"tags\":[\"a\",\"b\",\"c\"],\"addr\":{\"city\":\"Tokyo\",\"zip\":\"100-1\"},\"note\":null}]"
  (utf8->string (synthetic-records 2)))

(test-equal "escaped, small"
  "[\"lorem ipsum dolor sit amet, \\n\\u00e9\\ud83d\\ude00 lorem ipsum dolor sit amet, \\n\\u00e9\\ud83d\\ude00 \"]"
  (utf8->string (synthetic-escaped 2)))

;; --- 6. the report -------------------------------------------------------------

(define (e6 . l) (map (lambda (n) (* n 1000000)) l))

(define events-fixture
  '((null . 1) (true . 2) (false . 3) (number . 4) (string . 5) (key . 6)
    (object . 7) (array . 8) (number-bytes . 100000) (text-bytes . 10)))

(define (res file bytes parser lane iterations ns . extra)
  `(result (file ,file) (bytes ,bytes) (parser ,parser) (lane ,lane)
           (iterations ,iterations) (round-ns ,@ns) ,@extra))

;; Two files of a fiction whose rates come out round: BYTES x ITERATIONS is
;; 2 x 10^7 for both, so a round of 40 ms is 500 MB/s. ITERATIONS is what
;; iterations-for gives for 2 x 10^7 round bytes, and each lane ran 10
;; rounds of them, the warm-up's included.
(define (file-results file bytes iterations jp-events-ns)
  (let ((passes (* 10 iterations))
        (scanned `((string . ,(* bytes 2/5)) (number . 100000)
                   (whitespace . ,(* bytes 1/5))
                   (other . ,(- bytes (* bytes 2/5) 100000 (* bytes 1/5))))))
    (define (counted counts)
      (list `(counts ,@counts) `(passes ,passes) `(timed-counts ,@(times passes counts))))
    (define uncounted (list '(counts) `(passes ,passes)))
    (list
     (apply res file bytes 'yajl 'parse iterations (e6 40 45 46 48 50 52 53 55 60) uncounted)
     (apply res file bytes 'yajl 'events iterations (e6 50 55 60 61 125/2 63 64 70 80)
            (counted events-fixture))
     (apply res file bytes 'jsonparse 'parse iterations (e6 100 110 115 120 125 126 130 140 150)
            (append uncounted '((allocated 18000) (gc-ns 0))))
     (apply res file bytes 'jsonparse 'events iterations jp-events-ns
            (append (counted events-fixture) '((allocated 36000) (gc-ns 0))))
     (apply res file bytes 'jsonparse 'tree iterations (e6 400 420 450 480 500 510 520 530 600)
            (append uncounted '((allocated 900000000) (gc-ns 441000000))))
     (apply res file bytes 'jsonparse 'tree+walk iterations (e6 500 550 600 610 625 630 640 650 700)
            (append (counted (without-number-bytes events-fixture))
                    '((allocated 900000000) (gc-ns 0))))
     (apply res file bytes 'jsonparse 'scan iterations (e6 20 21 22 23 25 26 27 28 29)
            (append (counted scanned) '((allocated 0) (gc-ns 0)))))))

(define files '("records-2k.json" "escaped-string.json"))

(define results
  (append (file-results "records-2k.json" 1000000 20 (e6 125 150 160 180 200 210 220 230 240))
          (file-results "escaped-string.json" 500000 40 (e6 80 90 95 98 100 105 110 120 130))))

(define runtimes
  '((runtime (parser jsonparse) (version "Chez Scheme Version 10.4.1") (machine-type "ta6le")
             (optimize-level 0) (rounds 9) (round-bytes 20000000))
    (runtime (parser yajl) (version "2.1.0") (compiler "gcc 14.3.0") (flags "-O2")
             (rounds 9) (round-bytes 20000000))))

;; The plan for jsonparse and yajl alone. Its parsers needn't come in the
;; report's order.
(define plan
  '(plan (rounds 9) (round-bytes 20000000) (parsers (yajl 20000000) (jsonparse 20000000))))

(define machine
  '((cpu . "CPU X") (arch . "x86_64") (os . "Linux 1.0") (date . "2026-11-08")
    (pin . "CPU 7, at most 4500 MHz, governor powersave")))

(test-equal "machine lines are read as KEY: VALUE"
  machine
  (read-machine "cpu: CPU X\narch: x86_64\nos: Linux 1.0\ndate: 2026-11-08\npin: CPU 7, at most 4500 MHz, governor powersave\n"))

(test-equal "a machine value may hold \": \", and blank lines are skipped"
  '((cpu . "A: B") (os . "x"))
  (read-machine "\ncpu: A: B\n\nos: x"))

(test-equal "a machine line without \": \" raises"
  'read-machine
  (raise-who (lambda () (read-machine "cpu A"))))

(test-equal "the plan is the one datum its text holds, comments and spacing aside"
  plan
  (read-plan "; written by make\n(plan (rounds 9) (round-bytes 20000000)\n  (parsers (yajl 20000000) (jsonparse 20000000)))\n\n"))

(test-equal "a plan's text holding no datum, or two, raises"
  '(read-plan read-plan read-plan)
  (map (lambda (text) (raise-who (lambda () (read-plan text))))
       '("" "  ; nothing\n" "(plan) (plan)")))

(test-equal "consistent results cross-check clean"
  '()
  (cross-check files plan runtimes results))

;; map-fields : (Field -> Field) Result -> Result, F applied to each field
(define (map-fields f r) (cons (car r) (map f (cdr r))))

;; replace-counts : Result (Listof (Pair Symbol Nat)) -> Result
;; R with one pass's counts LANE-COUNTS, and timed counts to match them.
(define (replace-counts r lane-counts)
  (let ((passes (cadr (assq 'passes (cdr r)))))
    (map-fields (lambda (field)
                  (case (car field)
                    ((counts) (cons 'counts lane-counts))
                    ((timed-counts) (cons 'timed-counts (times passes lane-counts)))
                    (else field)))
                r)))

;; set-field : Result Symbol Any -> Result, with KEY's one value VALUE
(define (set-field r key value)
  (map-fields (lambda (field) (if (eq? (car field) key) (list key value) field)) r))

(define (with-result results file parser lane f)
  (map (lambda (r)
         (if (and (equal? (cadr (assq 'file (cdr r))) file)
                  (eq? (cadr (assq 'parser (cdr r))) parser)
                  (eq? (cadr (assq 'lane (cdr r))) lane))
             (f r)
             r))
       results))

;; bump : (Listof (Pair Symbol Nat)) Symbol -> same, NAME's count one more
(define (bump counts name)
  (map (lambda (p) (if (eq? (car p) name) (cons name (+ (cdr p) 1)) p)) counts))

(test-equal "a count yajl and jsonparse disagree on is named, for each of the ten"
  (map (lambda (name)
         (list (string-append "records-2k.json: events " (symbol->string name) ": yajl "
                              (number->string (+ 1 (cdr (assq name events-fixture))))
                              ", jsonparse " (number->string (cdr (assq name events-fixture))))))
       count-names)
  (map (lambda (name)
         (cross-check files plan runtimes
                      (with-result results "records-2k.json" 'yajl 'events
                                   (lambda (r) (replace-counts r (bump events-fixture name))))))
       count-names))

(test-equal "the ten count names, in order"
  '(null true false number string key object array number-bytes text-bytes)
  count-names)

(test-equal "a count the walk and the handler disagree on is named, for each of the nine"
  (map (lambda (name)
         (list (string-append "escaped-string.json: tree+walk " (symbol->string name) ": events "
                              (number->string (cdr (assq name events-fixture)))
                              ", tree+walk " (number->string (+ 1 (cdr (assq name events-fixture)))))))
       (map car (without-number-bytes events-fixture)))
  (map (lambda (name)
         (cross-check files plan runtimes
                      (with-result results "escaped-string.json" 'jsonparse 'tree+walk
                                   (lambda (r) (replace-counts r (bump (without-number-bytes events-fixture) name))))))
       (map car (without-number-bytes events-fixture))))

(test-equal "scan's number bytes must be the handler's"
  '("records-2k.json: scan number: events 100000, scan 99999")
  (cross-check files plan runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan
                            (lambda (r)
                              (replace-counts r '((string . 400000) (number . 99999)
                                                  (whitespace . 200000) (other . 300001)))))))

(test-equal "scan must cover the file's bytes"
  '("records-2k.json: scan covers 999999 bytes of 1000000")
  (cross-check files plan runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan
                            (lambda (r)
                              (replace-counts r '((string . 400000) (number . 100000)
                                                  (whitespace . 200000) (other . 299999)))))))

(define (set-bytes n) (lambda (r) (set-field r 'bytes n)))

(test-equal "a result that read another size than jsonparse's scan is named"
  '("records-2k.json: yajl parse read 999999 bytes, not 1000000")
  (cross-check files plan runtimes
               (with-result results "records-2k.json" 'yajl 'parse (set-bytes 999999))))

;; 1,000,001 bytes take 20 passes to read 2 x 10^7, as 1,000,000 do, so
;; only the sizes differ.
(test-equal "the file's size is the one jsonparse's scan read"
  '("records-2k.json: jsonparse parse read 1000000 bytes, not 1000001"
    "records-2k.json: jsonparse events read 1000000 bytes, not 1000001"
    "records-2k.json: jsonparse tree read 1000000 bytes, not 1000001"
    "records-2k.json: jsonparse tree+walk read 1000000 bytes, not 1000001"
    "records-2k.json: yajl parse read 1000000 bytes, not 1000001"
    "records-2k.json: yajl events read 1000000 bytes, not 1000001"
    "records-2k.json: scan covers 1000000 bytes of 1000001")
  (cross-check files plan runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan (set-bytes 1000001))))

(test-equal "a lane whose timed passes counted otherwise than its passes times one pass's is named"
  '(("records-2k.json: yajl events timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse events timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse tree+walk timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse scan timed passes counted string 80000001, not 80000000"))
  (map (lambda (parser lane)
         (cross-check files plan runtimes
                      (with-result results "records-2k.json" parser lane
                                   (lambda (r)
                                     (map-fields (lambda (field)
                                                   (if (eq? (car field) 'timed-counts)
                                                       (cons 'timed-counts
                                                             (cons (cons (caadr field) (+ 1 (cdadr field)))
                                                                   (cddr field)))
                                                       field))
                                                 r)))))
       '(yajl jsonparse jsonparse jsonparse)
       '(events events tree+walk scan)))

(test-equal "a counted lane with no timed counts is named"
  '("escaped-string.json: jsonparse events has no timed counts")
  (cross-check files plan runtimes
               (with-result results "escaped-string.json" 'jsonparse 'events
                            (lambda (r)
                              (cons (car r) (filter (lambda (field) (not (eq? (car field) 'timed-counts)))
                                                    (cdr r)))))))

(test-equal "a lane that ran other passes than ten rounds of iterations-for's is named"
  '(("records-2k.json: yajl parse ran 199 passes, not 200")
    ("records-2k.json: jsonparse tree ran 210 passes, not 200"))
  (list (cross-check files plan runtimes
                     (with-result results "records-2k.json" 'yajl 'parse
                                  (lambda (r) (set-field r 'passes 199))))
        (cross-check files plan runtimes
                     (with-result results "records-2k.json" 'jsonparse 'tree
                                  (lambda (r) (set-field r 'passes 210))))))

(test-equal "a lane that ran other passes a round than iterations-for's is named"
  '("escaped-string.json: jsonparse scan ran 39 passes a round, not 40")
  (cross-check files plan runtimes
               (with-result results "escaped-string.json" 'jsonparse 'scan
                            (lambda (r) (set-field r 'iterations 39)))))

(test-equal "the lock's files are the results' files"
  '(("x.json: no results")
    ("escaped-string.json: not in the lock"))
  (list (cross-check (append files '("x.json")) plan runtimes results)
        (cross-check '("records-2k.json") plan runtimes results)))

(test-equal "a missing lane is named"
  '("escaped-string.json: no yajl parse result")
  (cross-check files plan runtimes
               (filter (lambda (r) (not (and (equal? (cadr (assq 'file (cdr r))) "escaped-string.json")
                                             (eq? (cadr (assq 'parser (cdr r))) 'yajl)
                                             (eq? (cadr (assq 'lane (cdr r))) 'parse))))
                       results)))

(test-equal "a lane given twice is named"
  '("records-2k.json: jsonparse scan given twice")
  (cross-check files plan runtimes (append results (list (list-ref results 6)))))

(test-equal "a result with other rounds than the plan's is named"
  '("records-2k.json: jsonparse tree has 8 rounds, not 9")
  (cross-check files plan runtimes
               (with-result results "records-2k.json" 'jsonparse 'tree
                            (lambda (r)
                              (map-fields (lambda (field) (if (eq? (car field) 'round-ns) (cons 'round-ns (cddr field)) field))
                                          r)))))

(test-equal "a parser with two runtimes is named"
  '("yajl has 2 runtimes")
  (cross-check files plan (append runtimes (list (cadr runtimes))) results))

(test-equal "a parser with no runtime is named"
  '(("no jsonparse runtime") ("no yajl runtime"))
  (list (cross-check files plan (cdr runtimes) results)
        (cross-check files plan (list (car runtimes)) results)))

(test-equal "a runtime with other rounds or round bytes than the plan's is named"
  '(("yajl ran 9 rounds of 10000000 bytes; the plan says 9 of 20000000")
    ("yajl ran 7 rounds of 20000000 bytes; the plan says 9 of 20000000"))
  (map (lambda (rounds round-bytes)
         (cross-check files plan
                      (list (car runtimes)
                            `(runtime (parser yajl) (version "2.1.0") (compiler "gcc 14.3.0") (flags "-O2")
                                      (rounds ,rounds) (round-bytes ,round-bytes)))
                      results))
       '(9 7) '(10000000 20000000)))

;; --- the plan ---

(define plan-shape
  "the plan is not (plan (rounds R) (round-bytes B) (parsers (PARSER BYTES) ...))")

;; with-parsers : (Listof (List Symbol Integer)) -> Plan
(define (with-parsers entries)
  `(plan (rounds 9) (round-bytes 20000000) (parsers ,@entries)))

(define malformed-plans
  (let ((jy '((jsonparse 20000000) (yajl 20000000))))
    (list 'plan
          '()
          `(plans (rounds 9) (round-bytes 20000000) (parsers ,@jy))
          '(plan (rounds 9) (round-bytes 20000000))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy) (rounds 9))
          '(plan (rounds 9) (round-bytes 20000000) (parsers (jsonparse 20000000) (yajl 20000000)) . x)
          `(plan (round-bytes 20000000) (rounds 9) (parsers ,@jy))
          `(plan (rounds 9) (round-bytes 20000000) (counts ,@jy))
          `(plan (rounds) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds 9 9) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds 0) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds -9) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds 9.0) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds 9/2) (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds "9") (round-bytes 20000000) (parsers ,@jy))
          `(plan (rounds 9) (round-bytes 0) (parsers ,@jy))
          `(plan (rounds 9) (round-bytes 2e7) (parsers ,@jy))
          '(plan (rounds 9) (round-bytes 20000000) parsers)
          (list 'plan '(rounds 9) '(round-bytes 20000000) (cons 'parsers (append jy 'racket)))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy racket))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy (racket)))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy (racket 20000000 1)))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy ("racket" 20000000)))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy (racket 2e7)))
          `(plan (rounds 9) (round-bytes 20000000) (parsers ,@jy (racket "20000000"))))))

(test-equal "a plan of another shape is named, and nothing more is checked"
  (map (lambda (p) (list plan-shape)) malformed-plans)
  (map (lambda (p) (cross-check files p runtimes results)) malformed-plans))

(test-equal "a plan must name jsonparse and yajl"
  '(("the plan names no jsonparse" "the plan names no yajl")
    ("the plan names no yajl"))
  (list (cross-check files (with-parsers '()) runtimes results)
        (cross-check files (with-parsers '((jsonparse 20000000))) runtimes results)))

(test-equal "a plan naming a parser the report doesn't know is named, once"
  '(("the plan names orjson, a parser the report doesn't know")
    ("the plan names orjson, a parser the report doesn't know"
     "the plan names orjson 2 times"))
  (list (cross-check files (with-parsers '((jsonparse 20000000) (orjson 20000000) (yajl 20000000)))
                     runtimes results)
        (cross-check files (with-parsers '((orjson 20000000) (jsonparse 20000000) (orjson 20000000)
                                           (yajl 20000000)))
                     runtimes results)))

(test-equal "a plan naming a parser more than once is named"
  '("the plan names racket 2 times" "the plan names yajl 3 times")
  (cross-check files (with-parsers '((racket 20000000) (yajl 20000000) (jsonparse 20000000)
                                     (racket 20000000) (yajl 20000000) (yajl 20000000)))
               runtimes results))

(test-equal "jsonparse and yajl read the plan's round bytes"
  '("the plan gives jsonparse rounds of 20000001 bytes, not 20000000"
    "the plan gives yajl rounds of 10000000 bytes, not 20000000")
  (cross-check files (with-parsers '((jsonparse 20000001) (yajl 10000000))) runtimes results))

(test-equal "a comparator reads rounds of at least a byte, and no more than the plan's"
  '("the plan gives chibi rounds of 0 bytes, not 1 to 20000000"
    "the plan gives chez-json rounds of -5 bytes, not 1 to 20000000"
    "the plan gives gambit rounds of 20000001 bytes, not 1 to 20000000")
  (cross-check files (with-parsers '((jsonparse 20000000) (chibi 0) (yajl 20000000)
                                     (chez-json -5) (gambit 20000001)))
               runtimes results))

;; --- the comparators ---

;; around : Nat -> (Listof Nat), nine rounds whose median is M ms, and
;; whose best and mean are not
(define (around m) (e6 (- m 5) (- m 1) m m m (+ m 1) (+ m 2) (+ m 3) (+ m 50)))

;; peer : String Nat Symbol Symbol Nat Nat (Listof (Pair Symbol Nat)) -> Result
;; A comparator's result: ITERATIONS passes a round over FILE's BYTES, a
;; median round of M ms, and one pass's COUNTS, '() for a lane counting
;; nothing. Each lane ran 10 rounds, the warm-up's included.
(define (peer file bytes parser lane iterations m counts)
  (let ((passes (* 10 iterations)))
    (apply res file bytes parser lane iterations (around m)
           `(counts ,@counts) `(passes ,passes)
           (if (null? counts) '() (list `(timed-counts ,@(times passes counts)))))))

(define (failure file parser lane reason)
  `(failure (file ,file) (parser ,parser) (lane ,lane) (reason ,reason)))

(define nine (without-number-bytes events-fixture))

;; chez-json counts null and arrays as one: 1 null and 8 arrays.
(define chez-json-counts
  '((null+array . 9) (true . 2) (false . 3) (number . 4) (string . 5) (key . 6)
    (object . 7) (text-bytes . 10)))

;; peer-results : String Nat Nat Nat -> (Listof Result)
;; Every comparator's results for FILE of BYTES. FULL passes a round read
;; 2 x 10^7 bytes; Gambit reads half that, Chibi a fifth and chez-json a
;; tenth. Each median is K times the records file's, so each rate is 1/K
;; of its rate there.
(define (peer-results file bytes full k)
  (define (p parser lane iterations m counts)
    (peer file bytes parser lane iterations (* k m) counts))
  (let ((gambit (/ full 2)) (chibi (/ full 5)) (chez-json (/ full 10)))
    (list (p 'rapidjson 'parse full 20 '())
          (p 'rapidjson 'events full 25 events-fixture)
          (p 'jackson 'parse full 50 '())
          (p 'jackson 'events full 80 events-fixture)
          (p 'srfi-180 'events full 400 nine)
          (p 'srfi-180 'tree full 500 '())
          (p 'srfi-180 'tree+walk full 625 nine)
          (p 'racket 'tree full 200 '())
          (p 'racket 'tree+walk full 250 nine)
          (p 'guile-json 'tree full 160 '())
          (p 'guile-json 'tree+walk full 400 nine)
          (p 'gambit 'tree gambit 125 '())
          (p 'gambit 'tree+walk gambit 200 nine)
          (p 'gerbil 'tree full 1000 '())
          (p 'gerbil 'tree+walk full 1250 nine)
          (p 'chibi 'tree chibi 2000 '())
          (p 'chibi 'tree+walk chibi 2500 nine)
          (p 'chez-json 'tree chez-json 4000 '())
          (p 'chez-json 'tree+walk chez-json 5000 chez-json-counts)
          (p 'simdjson 'tree full 8 '())
          (p 'simdjson 'tree+walk full 10 nine)
          (p 'yyjson 'tree full 16 '())
          (p 'yyjson 'tree+walk full 20 nine))))

;; Every parser, in no order the report keeps; three read smaller rounds.
(define peers-plan
  '(plan (rounds 9) (round-bytes 20000000)
         (parsers (yyjson 20000000) (chez-json 2000000) (jsonparse 20000000) (chibi 4000000)
                  (racket 20000000) (yajl 20000000) (simdjson 20000000) (gambit 10000000)
                  (jackson 20000000) (guile-json 20000000) (srfi-180 20000000) (gerbil 20000000)
                  (rapidjson 20000000))))

(define peers-runtimes
  (append
   (map (lambda (p)
          `(runtime (parser ,(car p)) (version ,(cadr p)) (how ,(caddr p))
                    (rounds 9) (round-bytes ,(cadddr p))))
        '((rapidjson "1.1.0" "the SAX Reader, numbers as strings; g++ 14.3.0 -O2" 20000000)
          (jackson "2.23.0" "JsonParser.nextToken, on OpenJDK 25" 20000000)
          (srfi-180 "e45cb7da" "json-fold and json-read, on Chez Scheme Version 10.4.1" 20000000)
          (racket "9.3" "read-json, by raco make" 20000000)
          (guile-json "4.7.3" "json->scm, by guild compile" 20000000)
          (gambit "4.9.7" "the json reader, by gsc -exe" 10000000)
          (gerbil "0.18.1" ":std/text/json, by gxc -exe" 20000000)
          (chibi "0.12" "(chibi json), interpreted" 4000000)
          (chez-json "a9d6a302" "json->scm, on Chez Scheme Version 10.4.1" 2000000)
          (simdjson "4.6.3" "the DOM parser; g++ 14.3.0 -O2" 20000000)
          (yyjson "0.12.0" "yyjson_read; gcc 14.3.0 -O2" 20000000)))
   runtimes))

(define clean-peers-results
  (append (peer-results "records-2k.json" 1000000 20 1)
          (peer-results "escaped-string.json" 500000 40 2)
          results))

(define chez-json-reason "json->scm: bad escape\nat byte 31")

;; Two lanes that disagree with jsonparse's events, and chez-json failing
;; both its lanes on one file.
(define peers-results
  (fold-left (lambda (rs change) (apply with-result rs change))
             clean-peers-results
             (list (list "records-2k.json" 'racket 'tree+walk
                         (lambda (r) (replace-counts r (bump nine 'null))))
                   (list "records-2k.json" 'srfi-180 'events
                         (lambda (r) (replace-counts r (bump (bump nine 'number) 'text-bytes))))
                   (list "escaped-string.json" 'chez-json 'tree
                         (lambda (r) (failure "escaped-string.json" 'chez-json 'tree chez-json-reason)))
                   (list "escaped-string.json" 'chez-json 'tree+walk
                         (lambda (r) (failure "escaped-string.json" 'chez-json 'tree+walk chez-json-reason))))))

(define (the-result rs file parser lane)
  (find (lambda (r) (and (equal? (cadr (assq 'file (cdr r))) file)
                         (eq? (cadr (assq 'parser (cdr r))) parser)
                         (eq? (cadr (assq 'lane (cdr r))) lane)))
        rs))

(define (without rs file parser lane)
  (let ((r (the-result rs file parser lane)))
    (filter (lambda (x) (not (eq? x r))) rs)))

(define (with-runtime rts parser f)
  (map (lambda (rt) (if (eq? (cadr (assq 'parser (cdr rt))) parser) (f rt) rt)) rts))

(define (peer-runtime parser)
  (find (lambda (rt) (eq? (cadr (assq 'parser (cdr rt))) parser)) peers-runtimes))

;; check-peers : (Listof Form) -> (Listof String), the comparators' fixture
;; with RESULTS
(define (check-peers results) (cross-check files peers-plan peers-runtimes results))

(test-equal "a comparator that fails or disagrees stops nothing"
  '()
  (check-peers peers-results))

(test-equal "every parser the plan names has one runtime, and no other parser has one"
  '(("no racket runtime")
    ("chibi has 2 runtimes")
    ("chibi has a runtime, but the plan doesn't name it")
    ("chibi has a runtime, but the plan doesn't name it"))
  (list (cross-check files peers-plan
                     (filter (lambda (rt) (not (eq? rt (peer-runtime 'racket)))) peers-runtimes)
                     peers-results)
        (cross-check files peers-plan (cons (peer-runtime 'chibi) peers-runtimes) peers-results)
        (cross-check files plan (cons (peer-runtime 'chibi) runtimes) results)
        (cross-check files plan (append (list (peer-runtime 'chibi)) runtimes (list (peer-runtime 'chibi)))
                     results)))

(test-equal "a comparator's runtime holds to the plan's rounds and its own round bytes"
  '(("chez-json ran 9 rounds of 20000000 bytes; the plan says 9 of 2000000")
    ("racket ran 10 rounds of 20000000 bytes; the plan says 9 of 20000000"))
  (list (cross-check files peers-plan
                     (with-runtime peers-runtimes 'chez-json (lambda (rt) (set-field rt 'round-bytes 20000000)))
                     peers-results)
        (cross-check files peers-plan
                     (with-runtime peers-runtimes 'racket (lambda (rt) (set-field rt 'rounds 10)))
                     peers-results)))

(test-equal "a result or failure of a parser the plan doesn't name is named"
  '("chibi has results, but the plan doesn't name it"
    "gambit has results, but the plan doesn't name it")
  (cross-check files plan runtimes
               (append results
                       (list (the-result clean-peers-results "records-2k.json" 'chibi 'tree)
                             (failure "escaped-string.json" 'gambit 'tree "no")
                             (the-result clean-peers-results "escaped-string.json" 'chibi 'tree)))))

(test-equal "every lane of each parser the plan names is given once a file, as a result or a failure"
  '(("records-2k.json: no gerbil tree result")
    ("escaped-string.json: racket tree given twice")
    ("records-2k.json: chez-json tree+walk given twice"))
  (list (check-peers (without peers-results "records-2k.json" 'gerbil 'tree))
        (check-peers (cons (failure "escaped-string.json" 'racket 'tree "again") peers-results))
        (check-peers (cons (the-result peers-results "records-2k.json" 'chez-json 'tree+walk)
                           peers-results))))

(test-equal "a result or failure for a lane its parser doesn't have is named, once"
  '(("records-2k.json: racket has no events lane")
    ("escaped-string.json: yajl has no tree lane")
    ("escaped-string.json: srfi-180 has no parse lane"))
  (list (check-peers (append (list (set-field (the-result peers-results "records-2k.json" 'rapidjson 'events)
                                              'parser 'racket)
                                   (failure "records-2k.json" 'racket 'events "and again"))
                             peers-results))
        (check-peers (cons (set-field (the-result peers-results "escaped-string.json" 'jsonparse 'tree)
                                      'parser 'yajl)
                           peers-results))
        (check-peers (cons (failure "escaped-string.json" 'srfi-180 'parse "no lane") peers-results))))

(test-equal "a failure of jsonparse's or yajl's is named"
  '(("records-2k.json: yajl events fails: lexical error: invalid char in json text")
    ("escaped-string.json: jsonparse tree fails: the parse did not finish"))
  (list (check-peers (with-result peers-results "records-2k.json" 'yajl 'events
                                  (lambda (r) (failure "records-2k.json" 'yajl 'events
                                                       "lexical error: invalid char in json text"))))
        (check-peers (with-result peers-results "escaped-string.json" 'jsonparse 'tree
                                  (lambda (r) (failure "escaped-string.json" 'jsonparse 'tree
                                                       "the parse did not finish"))))))

(test-equal "a comparator's rounds, size and passes are checked, its passes by its own round bytes"
  '(("records-2k.json: chez-json tree ran 20 passes a round, not 2"
     "records-2k.json: chez-json tree ran 200 passes, not 20")
    ("escaped-string.json: chibi tree ran 81 passes, not 80")
    ("records-2k.json: gambit tree has 8 rounds, not 9")
    ("escaped-string.json: simdjson tree read 499999 bytes, not 500000"))
  (list (check-peers (with-result peers-results "records-2k.json" 'chez-json 'tree
                                  (lambda (r) (set-field (set-field r 'iterations 20) 'passes 200))))
        (check-peers (with-result peers-results "escaped-string.json" 'chibi 'tree
                                  (lambda (r) (set-field r 'passes 81))))
        (check-peers (with-result peers-results "records-2k.json" 'gambit 'tree
                                  (lambda (r) (map-fields (lambda (field)
                                                            (if (eq? (car field) 'round-ns)
                                                                (cons 'round-ns (cddr field))
                                                                field))
                                                          r))))
        (check-peers (with-result peers-results "escaped-string.json" 'simdjson 'tree (set-bytes 499999)))))

;; set-rounds : Result (Nat -> Any) -> Result, each round's nanoseconds F of them
(define (set-rounds r f)
  (map-fields (lambda (field)
                (if (eq? (car field) 'round-ns) (cons 'round-ns (map f (cdr field))) field))
              r))

;; A round of 0 ns would divide by zero, and one below would give a
;; negative rate.
(test-equal "every round's time is a positive whole number of nanoseconds"
  '(("records-2k.json: yyjson tree has a round of 0 ns, not a positive whole number")
    ("records-2k.json: yyjson tree has a round of -203708 ns, not a positive whole number")
    ("escaped-string.json: jsonparse events has a round of 100000000.0 ns, not a positive whole number")
    ("escaped-string.json: rapidjson events has a round of 1/2 ns, not a positive whole number"))
  (list (check-peers (with-result peers-results "records-2k.json" 'yyjson 'tree
                                  (lambda (r) (set-rounds r (lambda (ns) (if (= ns 16000000) 0 ns))))))
        (check-peers (with-result peers-results "records-2k.json" 'yyjson 'tree
                                  (lambda (r) (set-rounds r (lambda (ns) (if (= ns 16000000) -203708 ns))))))
        (check-peers (with-result peers-results "escaped-string.json" 'jsonparse 'events
                                  (lambda (r) (set-rounds r (lambda (ns) (if (= ns 100000000) 1e8 ns))))))
        (check-peers (with-result peers-results "escaped-string.json" 'rapidjson 'events
                                  (lambda (r) (set-rounds r (lambda (ns) (if (= ns 50000000) 1/2 ns))))))))

(test-equal "a counted lane's counts name exactly its parser's names, once each"
  '(("records-2k.json: racket tree+walk counts (null true false number string key object array), not (null true false number string key object array text-bytes)"
     "records-2k.json: racket tree+walk timed counts (null true false number string key object array), not (null true false number string key object array text-bytes)")
    ("escaped-string.json: srfi-180 events counts (null true false number string key object array number-bytes text-bytes), not (null true false number string key object array text-bytes)"
     "escaped-string.json: srfi-180 events timed counts (null true false number string key object array number-bytes text-bytes), not (null true false number string key object array text-bytes)")
    ("records-2k.json: rapidjson events counts (null true false number string key object array number-bytes null), not (null true false number string key object array number-bytes text-bytes)"
     "records-2k.json: rapidjson events timed counts (null true false number string key object array number-bytes null), not (null true false number string key object array number-bytes text-bytes)")
    ("records-2k.json: chez-json tree+walk counts (null true false number string key object array text-bytes), not (null+array true false number string key object text-bytes)"
     "records-2k.json: chez-json tree+walk timed counts (null true false number string key object array text-bytes), not (null+array true false number string key object text-bytes)")
    ("escaped-string.json: guile-json tree+walk counts (null true false number string key object array), not (null true false number string key object array text-bytes)"))
  (list (check-peers (with-result peers-results "records-2k.json" 'racket 'tree+walk
                                  (lambda (r) (replace-counts r (filter (lambda (p) (not (eq? (car p) 'text-bytes))) nine)))))
        (check-peers (with-result peers-results "escaped-string.json" 'srfi-180 'events
                                  (lambda (r) (replace-counts r events-fixture))))
        (check-peers (with-result peers-results "records-2k.json" 'rapidjson 'events
                                  (lambda (r) (replace-counts r (append (filter (lambda (p) (not (eq? (car p) 'text-bytes))) events-fixture)
                                                                        '((null . 1)))))))
        (check-peers (with-result peers-results "records-2k.json" 'chez-json 'tree+walk
                                  (lambda (r) (replace-counts r nine))))
        (check-peers (with-result peers-results "escaped-string.json" 'guile-json 'tree+walk
                                  (lambda (r)
                                    (map-fields (lambda (field)
                                                  (if (eq? (car field) 'counts)
                                                      (cons 'counts (filter (lambda (p) (not (eq? (car p) 'text-bytes)))
                                                                            (cdr field)))
                                                      field))
                                                r))))))

(test-equal "a counted lane's timed counts name exactly its parser's names"
  '("records-2k.json: jackson events timed counts (null true false number string key object array number-bytes), not (null true false number string key object array number-bytes text-bytes)")
  (check-peers (with-result peers-results "records-2k.json" 'jackson 'events
                            (lambda (r)
                              (map-fields (lambda (field)
                                            (if (eq? (car field) 'timed-counts)
                                                (cons 'timed-counts
                                                      (filter (lambda (p) (not (eq? (car p) 'text-bytes))) (cdr field)))
                                                field))
                                          r)))))

(define (add-field r field) (append r (list field)))

(test-equal "a lane that counts nothing has empty counts and no timed counts"
  '(("records-2k.json: racket tree has counts, for a lane that counts nothing")
    ("escaped-string.json: rapidjson parse has timed counts, for a lane that counts nothing")
    ("records-2k.json: jsonparse tree has counts, for a lane that counts nothing"
     "records-2k.json: jsonparse tree has timed counts, for a lane that counts nothing"))
  (list (check-peers (with-result peers-results "records-2k.json" 'racket 'tree
                                  (lambda (r) (replace-counts r '((null . 1))))))
        (check-peers (with-result peers-results "escaped-string.json" 'rapidjson 'parse
                                  (lambda (r) (add-field r '(timed-counts)))))
        (check-peers (with-result peers-results "records-2k.json" 'jsonparse 'tree
                                  (lambda (r) (add-field (replace-counts r nine)
                                                         `(timed-counts ,@(times 200 nine))))))))

;; bump-timed : Result Symbol -> Result, its timed count of NAME one more
(define (bump-timed r name)
  (map-fields (lambda (field)
                (if (eq? (car field) 'timed-counts) (cons 'timed-counts (bump (cdr field) name)) field))
              r))

(test-equal "a comparator's timed passes count one pass's counts times the passes"
  '(("records-2k.json: jackson events timed passes counted number-bytes 20000001, not 20000000")
    ("records-2k.json: chez-json tree+walk timed passes counted null+array 181, not 180")
    ("escaped-string.json: srfi-180 events has no timed counts"))
  (list (check-peers (with-result peers-results "records-2k.json" 'jackson 'events
                                  (lambda (r) (bump-timed r 'number-bytes))))
        (check-peers (with-result peers-results "records-2k.json" 'chez-json 'tree+walk
                                  (lambda (r) (bump-timed r 'null+array))))
        (check-peers (with-result peers-results "escaped-string.json" 'srfi-180 'events
                                  (lambda (r)
                                    (cons (car r) (filter (lambda (field) (not (eq? (car field) 'timed-counts)))
                                                          (cdr r))))))))

(test-equal "a comparator's lane that disagrees is still checked whole"
  '("records-2k.json: racket tree+walk timed passes counted null 401, not 400")
  (check-peers (with-result peers-results "records-2k.json" 'racket 'tree+walk
                            (lambda (r) (bump-timed r 'null)))))

;; --- the voided cells ---

(test-equal "the voided cells, by file, then in the report's order of parsers and lanes"
  `(("escaped-string.json" chez-json tree fails ,chez-json-reason)
    ("escaped-string.json" chez-json tree+walk fails ,chez-json-reason)
    ("records-2k.json" srfi-180 events disagrees "number 5, jsonparse 4; text-bytes 11, jsonparse 10")
    ("records-2k.json" racket tree disagrees "its tree+walk disagrees")
    ("records-2k.json" racket tree+walk disagrees "null 2, jsonparse 1"))
  (voided-cells peers-results))

;; The walk is the only check of the value a tree builder built.
(test-equal "a comparator's tree follows its walk on the same file, and no other lane does"
  `((("records-2k.json" gambit tree fails "its tree+walk fails")
     ("records-2k.json" gambit tree+walk fails "gsc: heap overflow"))
    (("escaped-string.json" srfi-180 tree disagrees "its tree+walk disagrees")
     ("escaped-string.json" srfi-180 tree+walk disagrees "text-bytes 11, jsonparse 10")))
  (list (voided-cells (with-result clean-peers-results "records-2k.json" 'gambit 'tree+walk
                                   (lambda (r) (failure "records-2k.json" 'gambit 'tree+walk
                                                        "gsc: heap overflow"))))
        (voided-cells (with-result clean-peers-results "escaped-string.json" 'srfi-180 'tree+walk
                                   (lambda (r) (replace-counts r (bump nine 'text-bytes)))))))

(test-equal "a comparator's parse follows its events on the same file, and its own failure stands"
  '((("records-2k.json" rapidjson parse disagrees "its events disagrees")
     ("records-2k.json" rapidjson events disagrees "key 7, jsonparse 6"))
    (("escaped-string.json" jackson parse fails "its events fails")
     ("escaped-string.json" jackson events fails "JsonParseException"))
    (("records-2k.json" jackson parse fails "out of memory")
     ("records-2k.json" jackson events disagrees "key 7, jsonparse 6")))
  (list (voided-cells (with-result clean-peers-results "records-2k.json" 'rapidjson 'events
                                   (lambda (r) (replace-counts r (bump events-fixture 'key)))))
        (voided-cells (with-result clean-peers-results "escaped-string.json" 'jackson 'events
                                   (lambda (r) (failure "escaped-string.json" 'jackson 'events
                                                        "JsonParseException"))))
        (voided-cells (with-result (with-result clean-peers-results "records-2k.json" 'jackson 'events
                                                (lambda (r) (replace-counts r (bump events-fixture 'key))))
                                   "records-2k.json" 'jackson 'parse
                                   (lambda (r) (failure "records-2k.json" 'jackson 'parse "out of memory"))))))

(test-equal "a tree's own failure stands, once, whatever its walk did"
  '(("records-2k.json" chibi tree fails "chibi: out of memory")
    ("records-2k.json" chibi tree+walk disagrees "key 7, jsonparse 6"))
  (voided-cells (fold-left (lambda (rs change) (apply with-result rs change))
                           clean-peers-results
                           (list (list "records-2k.json" 'chibi 'tree
                                       (lambda (r) (failure "records-2k.json" 'chibi 'tree
                                                            "chibi: out of memory")))
                                 (list "records-2k.json" 'chibi 'tree+walk
                                       (lambda (r) (replace-counts r (bump nine 'key))))))))

(test-equal "comparators that agree, and jsonparse and yajl alone, void nothing"
  '(() ())
  (list (voided-cells clean-peers-results) (voided-cells results)))

(test-equal "each name a comparator counts is held to jsonparse's events"
  (append
   (map (lambda (name)
          (list (list "records-2k.json" 'rapidjson 'parse 'disagrees "its events disagrees")
                (list "records-2k.json" 'rapidjson 'events 'disagrees
                      (string-append (symbol->string name) " "
                                     (number->string (+ 1 (cdr (assq name events-fixture))))
                                     ", jsonparse " (number->string (cdr (assq name events-fixture)))))))
        (map car events-fixture))
   (map (lambda (name)
          (list (list "escaped-string.json" 'gerbil 'tree 'disagrees "its tree+walk disagrees")
                (list "escaped-string.json" 'gerbil 'tree+walk 'disagrees
                      (string-append (symbol->string name) " "
                                     (number->string (+ 1 (cdr (assq name nine))))
                                     ", jsonparse " (number->string (cdr (assq name nine)))))))
        (map car nine)))
  (append
   (map (lambda (name)
          (voided-cells (with-result clean-peers-results "records-2k.json" 'rapidjson 'events
                                     (lambda (r) (replace-counts r (bump events-fixture name))))))
        (map car events-fixture))
   (map (lambda (name)
          (voided-cells (with-result clean-peers-results "escaped-string.json" 'gerbil 'tree+walk
                                     (lambda (r) (replace-counts r (bump nine name))))))
        (map car nine))))

(test-equal "chez-json's null+array is held to jsonparse's null and array together"
  '(("records-2k.json" chez-json tree disagrees "its tree+walk disagrees")
    ("records-2k.json" chez-json tree+walk disagrees "null+array 10, jsonparse 9; key 7, jsonparse 6"))
  (voided-cells (with-result clean-peers-results "records-2k.json" 'chez-json 'tree+walk
                             (lambda (r) (replace-counts r (bump (bump chez-json-counts 'null+array) 'key))))))

;; --- lanes too slow to time ---

;; too-slow : String Nat Symbol Symbol Nat Nat (Listof (Pair Symbol Nat)) -> Form
;; A lane its harness didn't time: one pass over FILE's BYTES took PASS-NS,
;; past LIMIT-NS, and counted COUNTS, '() in a lane counting nothing.
(define (too-slow file bytes parser lane pass-ns limit-ns counts)
  `(too-slow (file ,file) (bytes ,bytes) (parser ,parser) (lane ,lane)
             (pass-ns ,pass-ns) (limit-ns ,limit-ns) (counts ,@counts)))

;; set-counts : Form (Listof (Pair Symbol Nat)) -> Form, with counts COUNTS
(define (set-counts r counts)
  (map-fields (lambda (field) (if (eq? (car field) 'counts) (cons 'counts counts) field)) r))

;; SRFI 180's three lanes on the records file, none timed: 100 s, 125 s
;; and 150 s a pass, past a limit of 10 s.
(define (slow-srfi-180 rs)
  (fold-left (lambda (rs change) (apply with-result rs change))
             rs
             (map (lambda (lane pass-ns counts)
                    (list "records-2k.json" 'srfi-180 lane
                          (lambda (r) (too-slow "records-2k.json" 1000000 'srfi-180 lane
                                                pass-ns 10000000000 counts))))
                  '(events tree tree+walk)
                  '(100000000000 125000000000 150000000000)
                  (list nine '() nine))))

(define (with-slow-srfi-180 lane f)
  (with-result (slow-srfi-180 clean-peers-results) "records-2k.json" 'srfi-180 lane f))

(test-equal "lanes too slow to time stop nothing"
  '()
  (check-peers (slow-srfi-180 clean-peers-results)))

(test-equal "a lane too slow to time is held to its size, the method's limit, a whole pass past it, and its names"
  '(("records-2k.json: srfi-180 events read 999999 bytes, not 1000000")
    ("records-2k.json: srfi-180 tree took 10000000000 ns a pass, not past the method's limit of 10000000000 ns")
    ("records-2k.json: srfi-180 tree took 2.5e10 ns a pass, not past the method's limit of 10000000000 ns")
    ("records-2k.json: srfi-180 tree had a limit of 0 ns, not the method's 10000000000 ns"
     "records-2k.json: srfi-180 tree took 5 ns a pass, not past the method's limit of 10000000000 ns")
    ("records-2k.json: srfi-180 tree had a limit of 20000000000 ns, not the method's 10000000000 ns")
    ("records-2k.json: srfi-180 tree+walk counts (null true false number string object array text-bytes), not (null true false number string key object array text-bytes)")
    ("records-2k.json: srfi-180 tree has counts, for a lane that counts nothing"))
  (list (check-peers (with-slow-srfi-180 'events (lambda (r) (set-field r 'bytes 999999))))
        (check-peers (with-slow-srfi-180 'tree (lambda (r) (set-field r 'pass-ns 10000000000))))
        (check-peers (with-slow-srfi-180 'tree (lambda (r) (set-field r 'pass-ns 2.5e10))))
        (check-peers (with-slow-srfi-180 'tree (lambda (r) (set-field (set-field r 'pass-ns 5) 'limit-ns 0))))
        (check-peers (with-slow-srfi-180 'tree (lambda (r) (set-field (set-field r 'pass-ns 30000000000)
                                                                       'limit-ns 20000000000))))
        (check-peers (with-slow-srfi-180 'tree+walk
                                         (lambda (r) (set-counts r (filter (lambda (p) (not (eq? (car p) 'key))) nine)))))
        (check-peers (with-slow-srfi-180 'tree (lambda (r) (set-counts r nine))))))

(test-equal "a lane of jsonparse's or yajl's too slow to time is named"
  '(("records-2k.json: yajl events was too slow to time")
    ("escaped-string.json: jsonparse tree was too slow to time"))
  (list (check-peers (with-result peers-results "records-2k.json" 'yajl 'events
                                  (lambda (r) (too-slow "records-2k.json" 1000000 'yajl 'events
                                                        20000000000 10000000000 events-fixture))))
        (check-peers (with-result peers-results "escaped-string.json" 'jsonparse 'tree
                                  (lambda (r) (too-slow "escaped-string.json" 500000 'jsonparse 'tree
                                                        20000000000 10000000000 '()))))))

(test-equal "a lane too slow to time beside a result for it is given twice"
  '("records-2k.json: srfi-180 events given twice")
  (check-peers (cons (too-slow "records-2k.json" 1000000 'srfi-180 'events 100000000000 10000000000 nine)
                     clean-peers-results)))

(test-equal "a lane too slow to time has no rate, and its pass's time and rate say why"
  '(("records-2k.json" srfi-180 events too-slow "one pass took 100.0 s, 0.010 MB/s; the limit is 10.0 s")
    ("records-2k.json" srfi-180 tree too-slow "one pass took 125.0 s, 0.0080 MB/s; the limit is 10.0 s")
    ("records-2k.json" srfi-180 tree+walk too-slow "one pass took 150.0 s, 0.0067 MB/s; the limit is 10.0 s"))
  (voided-cells (slow-srfi-180 clean-peers-results)))

(test-equal "a lane too slow that counts otherwise disagrees, and a tree too slow follows such a walk"
  '(("records-2k.json" srfi-180 events disagrees "key 7, jsonparse 6")
    ("records-2k.json" srfi-180 tree disagrees "its tree+walk disagrees")
    ("records-2k.json" srfi-180 tree+walk disagrees "text-bytes 11, jsonparse 10"))
  (voided-cells (with-result (with-slow-srfi-180 'events (lambda (r) (set-counts r (bump nine 'key))))
                             "records-2k.json" 'srfi-180 'tree+walk
                             (lambda (r) (set-counts r (bump nine 'text-bytes))))))

;; Its counts checked the value, so a walk too slow to time leaves the
;; tree's rate standing.
(test-equal "a walk too slow to time leaves its tree a rate, and a tree's own failure stands"
  '((("records-2k.json" gambit tree+walk too-slow "one pass took 20.0 s, 0.050 MB/s; the limit is 10.0 s"))
    (("records-2k.json" gambit tree fails "gsc: heap overflow")
     ("records-2k.json" gambit tree+walk too-slow "one pass took 20.0 s, 0.050 MB/s; the limit is 10.0 s")))
  (let ((slow-walk (with-result clean-peers-results "records-2k.json" 'gambit 'tree+walk
                                (lambda (r) (too-slow "records-2k.json" 1000000 'gambit 'tree+walk
                                                      20000000000 10000000000 nine)))))
    (list (voided-cells slow-walk)
          (voided-cells (with-result slow-walk "records-2k.json" 'gambit 'tree
                                     (lambda (r) (failure "records-2k.json" 'gambit 'tree
                                                          "gsc: heap overflow")))))))

(test-equal "a method line says when the rounds are fewer than ADR-0013's nine"
  '("a warm-up round, then 9 timed rounds of at least 20,000,000 bytes each (ADR-0013)."
    "a warm-up round, then 8 timed rounds of at least 1,000 bytes each: fewer than ADR-0013's 9, so not a measurement to record."
    "a warm-up round, then 10 timed rounds of at least 999 bytes each (ADR-0013).")
  (list (method-text 9 20000000) (method-text 8 1000) (method-text 10 999)))

(test-equal "a target is met at the target itself, and not just past it"
  '("- **records-2k.json, events:** not measured; the target is 2x."
    "- **records-2k.json, events:** 2.0x behind yajl; the target is 2x, met."
    "- **records-2k.json, events:** 2.0x behind yajl; the target is 2x, not met.")
  (list (target-line "records-2k.json" 2 #f)
        (target-line "records-2k.json" 2 2)
        (target-line "records-2k.json" 2 20001/10000)))

(test-equal "fixed rounds to the nearest, and pads the decimals"
  '("2.3" "0.05" "0.33" "5.00" "0.00" "454.5" "12")
  (list (fixed 2.26 1) (fixed 1/20 2) (fixed 1/3 2) (fixed 5 2) (fixed 0.004 2)
        (fixed 454.54 1) (fixed 12.4 0)))

(test-equal "rate-text gives one decimal, and below 1 MB/s two significant digits"
  '("903.5" "1.0" "1.0" "0.68" "0.079" "0.010" "0.0095" "0.00012" "0.0")
  (map rate-text (list 903.46 1 0.96 68/100 79/1000 1/100 949/100000 123/1000000 0)))

(test-equal "group-digits puts a comma every three digits"
  '("0" "999" "1,000" "12,345" "1,000,000")
  (map group-digits '(0 999 1000 12345 1000000)))

(test-equal "prose-list joins strings as a sentence does"
  '("" "A" "A and B" "A, B, and C" "A, B, C, and D")
  (map prose-list '(() ("A") ("A" "B") ("A" "B" "C") ("A" "B" "C" "D"))))

;; The report of jsonparse and yajl alone, in pieces each report below
;; shares: its head, down to yajl's line; the Pinned line; the Method line,
;; with SMALLER after the rounds; and its body, from The files on.

(define report-head
  (string-append
   "# jsonparse benchmarks\n"
   "\n"
   "- **Date (UTC):** 2026-11-08\n"
   "- **Machine:** CPU X, x86_64, Linux 1.0\n"
   "- **jsonparse:** Chez Scheme Version 10.4.1 (ta6le), libraries compiled ahead of time at optimize-level 0\n"
   "- **yajl:** 2.1.0; its harness built by gcc 14.3.0 with -O2\n"))

(define report-pinned "- **Pinned:** CPU 7, at most 4500 MHz, governor powersave\n")

(define (method-line smaller)
  (string-append
   "- **Method:** a warm-up round, then 9 timed rounds of at least 20,000,000 bytes each (ADR-0013)."
   smaller
   " Rates are MB/s, where 1 MB is 10^6 bytes: the best round, then the median. A gap is yajl's median over jsonparse's.\n"))

(define report-body
  (string-append
   "\n"
   "## The files\n"
   "\n"
   "What each file is made of, in bytes: inside strings (quotes and escapes included), number text, whitespace, and the rest.\n"
   "\n"
   "| File | Bytes | Strings | Numbers | Whitespace | Other |\n"
   "|:--|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 500,000 | 40.0% | 20.0% | 20.0% | 20.0% |\n"
   "| records-2k.json | 1,000,000 | 40.0% | 10.0% | 20.0% | 30.0% |\n"
   "\n"
   "## jsonparse against yajl\n"
   "\n"
   "`parse` listens to nothing. `events` counts each value by kind, and the bytes of every number's and string's text.\n"
   "\n"
   "| File | parse: yajl | jsonparse | gap | events: yajl | jsonparse | gap |\n"
   "|:--|--:|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 500.0 / 400.0 | 200.0 / 160.0 | 2.5x | 400.0 / 320.0 | 250.0 / 200.0 | 1.6x |\n"
   "| records-2k.json | 500.0 / 400.0 | 200.0 / 160.0 | 2.5x | 400.0 / 320.0 | 160.0 / 100.0 | 3.2x |\n"
   "\n"
   "## The M3 targets\n"
   "\n"
   "- **records-2k.json, events:** 3.2x behind yajl; the target is 2x, not met.\n"
   "- **escaped-string.json, events:** 1.6x behind yajl; the target is 4x, met.\n"
   "\n"
   "## jsonparse's own lanes\n"
   "\n"
   "`tree` builds the value with `bytevector->json`, and `tree+walk` then counts it as `events` does. `scan` only sorts each byte, as the table of files does: the least a Scheme loop reading a byte at a time does.\n"
   "\n"
   "| File | tree | tree+walk | scan |\n"
   "|:--|--:|--:|--:|\n"
   "| escaped-string.json | 50.0 / 40.0 | 40.0 / 32.0 | 1000.0 / 800.0 |\n"
   "| records-2k.json | 50.0 / 40.0 | 40.0 / 32.0 | 1000.0 / 800.0 |\n"
   "\n"
   "## Allocation and collection\n"
   "\n"
   "Bytes allocated per input byte, and the share of the timed rounds spent collecting.\n"
   "\n"
   "| File | parse | events | tree | tree+walk | scan |\n"
   "|:--|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 0.00, 0.0% | 0.00, 0.0% | 5.00, 10.0% | 5.00, 0.0% | 0.00, 0.0% |\n"
   "| records-2k.json | 0.00, 0.0% | 0.00, 0.0% | 5.00, 10.0% | 5.00, 0.0% | 0.00, 0.0% |\n"))

(define cells-with-no-rate
  (string-append
   "\n"
   "## Cells with no rate\n"
   "\n"
   "A comparator's lane has no rate when it rejected the file (`fails`), counted other values than jsonparse's `events` (`disagrees`), or its first pass ran past its harness's time limit (`too slow`).\n"
   "\n"))

(test-equal "the report of jsonparse and yajl alone, whole"
  (string-append report-head report-pinned (method-line "") report-body)
  (report-text machine plan runtimes results))

(test-equal "the report of every parser, a voided cell among them, whole"
  (string-append
   report-head
   "- **RapidJSON:** 1.1.0; the SAX Reader, numbers as strings; g++ 14.3.0 -O2\n"
   "- **Jackson:** 2.23.0; JsonParser.nextToken, on OpenJDK 25\n"
   "- **SRFI 180:** e45cb7da; json-fold and json-read, on Chez Scheme Version 10.4.1\n"
   "- **Racket:** 9.3; read-json, by raco make\n"
   "- **guile-json:** 4.7.3; json->scm, by guild compile\n"
   "- **Gambit:** 4.9.7; the json reader, by gsc -exe\n"
   "- **Gerbil:** 0.18.1; :std/text/json, by gxc -exe\n"
   "- **Chibi:** 0.12; (chibi json), interpreted\n"
   "- **chez-json:** a9d6a302; json->scm, on Chez Scheme Version 10.4.1\n"
   "- **simdjson:** 4.6.3; the DOM parser; g++ 14.3.0 -O2\n"
   "- **yyjson:** 0.12.0; yyjson_read; gcc 14.3.0 -O2\n"
   report-pinned
   (method-line " Slow comparators read smaller rounds: Gambit 10,000,000 bytes, Chibi 4,000,000 bytes, and chez-json 2,000,000 bytes.")
   report-body
   "\n"
   "## Event parsers\n"
   "\n"
   "Parsers that hand over each value as they read it: each one's median rate, in MB/s.\n"
   "\n"
   "| File | events: jsonparse | yajl | RapidJSON | Jackson | SRFI 180 |\n"
   "|:--|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 200.0 | 320.0 | 400.0 | 125.0 | 25.0 |\n"
   "| records-2k.json | 100.0 | 320.0 | 800.0 | 250.0 | disagrees |\n"
   "\n"
   "| File | parse: jsonparse | yajl | RapidJSON | Jackson |\n"
   "|:--|--:|--:|--:|--:|\n"
   "| escaped-string.json | 160.0 | 400.0 | 500.0 | 200.0 |\n"
   "| records-2k.json | 160.0 | 400.0 | 1000.0 | 400.0 |\n"
   "\n"
   "## Tree builders\n"
   "\n"
   "Parsers that build the whole value: each one's median rate, in MB/s. `tree+walk` then counts the value as `events` does.\n"
   "\n"
   "| File | tree: jsonparse | Racket | guile-json | Gambit | Gerbil | Chibi | SRFI 180 | chez-json |\n"
   "|:--|--:|--:|--:|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 40.0 | 50.0 | 62.5 | 40.0 | 10.0 | 1.0 | 20.0 | fails |\n"
   "| records-2k.json | 40.0 | disagrees | 125.0 | 80.0 | 20.0 | 2.0 | 40.0 | 0.50 |\n"
   "\n"
   "| File | tree+walk: jsonparse | Racket | guile-json | Gambit | Gerbil | Chibi | SRFI 180 | chez-json |\n"
   "|:--|--:|--:|--:|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 32.0 | 40.0 | 25.0 | 25.0 | 8.0 | 0.80 | 16.0 | fails |\n"
   "| records-2k.json | 32.0 | disagrees | 50.0 | 50.0 | 16.0 | 1.6 | 32.0 | 0.40 |\n"
   "\n"
   "## Ceilings\n"
   "\n"
   "Parsers built for speed in C and C++: a ceiling, not a target. Each one's median rate, in MB/s.\n"
   "\n"
   "| File | tree: jsonparse | simdjson | yyjson | tree+walk: jsonparse | simdjson | yyjson |\n"
   "|:--|--:|--:|--:|--:|--:|--:|\n"
   "| escaped-string.json | 40.0 | 1250.0 | 625.0 | 32.0 | 1000.0 | 500.0 |\n"
   "| records-2k.json | 40.0 | 2500.0 | 1250.0 | 32.0 | 2000.0 | 1000.0 |\n"
   cells-with-no-rate
   "- **escaped-string.json, chez-json, tree:** fails: json->scm: bad escape at byte 31\n"
   "- **escaped-string.json, chez-json, tree+walk:** fails: json->scm: bad escape at byte 31\n"
   "- **records-2k.json, SRFI 180, events:** disagrees: number 5, jsonparse 4; text-bytes 11, jsonparse 10\n"
   "- **records-2k.json, Racket, tree:** disagrees: its tree+walk disagrees\n"
   "- **records-2k.json, Racket, tree+walk:** disagrees: null 2, jsonparse 1\n")
  (report-text machine peers-plan peers-runtimes peers-results))

;; SRFI 180 at half the round bytes, and yyjson: one event peer, no
;; parse peer, one tree peer and one ceiling.
(define partial-plan
  '(plan (rounds 9) (round-bytes 20000000)
         (parsers (jsonparse 20000000) (yyjson 20000000) (srfi-180 10000000) (yajl 20000000))))

(define partial-runtimes
  (append (list (set-field (peer-runtime 'srfi-180) 'round-bytes 10000000) (peer-runtime 'yyjson))
          runtimes))

(define partial-results
  (append (list (peer "records-2k.json" 1000000 'srfi-180 'events 10 200 nine)
                (peer "records-2k.json" 1000000 'srfi-180 'tree 10 250 '())
                (peer "records-2k.json" 1000000 'srfi-180 'tree+walk 10 400 nine)
                (peer "escaped-string.json" 500000 'srfi-180 'events 20 400 nine)
                (peer "escaped-string.json" 500000 'srfi-180 'tree 20 500 '())
                (peer "escaped-string.json" 500000 'srfi-180 'tree+walk 20 800 nine))
          (filter (lambda (r) (eq? (cadr (assq 'parser (cdr r))) 'yyjson)) clean-peers-results)
          results))

(test-equal "a few comparators cross-check clean"
  '()
  (cross-check files partial-plan partial-runtimes partial-results))

;; partial-report : String String String -> String
;; The report of partial-plan, whole, with EVENTS and TREE SRFI 180's cells
;; on the records file, and TAIL after the ceilings.
(define (partial-report events tree tail)
  (string-append
   report-head
   "- **SRFI 180:** e45cb7da; json-fold and json-read, on Chez Scheme Version 10.4.1\n"
   "- **yyjson:** 0.12.0; yyjson_read; gcc 14.3.0 -O2\n"
   report-pinned
   (method-line " Slow comparators read smaller rounds: SRFI 180 10,000,000 bytes.")
   report-body
   "\n"
   "## Event parsers\n"
   "\n"
   "Parsers that hand over each value as they read it: each one's median rate, in MB/s.\n"
   "\n"
   "| File | events: jsonparse | yajl | SRFI 180 |\n"
   "|:--|--:|--:|--:|\n"
   "| escaped-string.json | 200.0 | 320.0 | 25.0 |\n"
   "| records-2k.json | 100.0 | 320.0 | " events " |\n"
   "\n"
   "## Tree builders\n"
   "\n"
   "Parsers that build the whole value: each one's median rate, in MB/s. `tree+walk` then counts the value as `events` does.\n"
   "\n"
   "| File | tree: jsonparse | SRFI 180 |\n"
   "|:--|--:|--:|\n"
   "| escaped-string.json | 40.0 | 20.0 |\n"
   "| records-2k.json | 40.0 | " tree " |\n"
   "\n"
   "| File | tree+walk: jsonparse | SRFI 180 |\n"
   "|:--|--:|--:|\n"
   "| escaped-string.json | 32.0 | 12.5 |\n"
   "| records-2k.json | 32.0 | 25.0 |\n"
   "\n"
   "## Ceilings\n"
   "\n"
   "Parsers built for speed in C and C++: a ceiling, not a target. Each one's median rate, in MB/s.\n"
   "\n"
   "| File | tree: jsonparse | yyjson | tree+walk: jsonparse | yyjson |\n"
   "|:--|--:|--:|--:|--:|\n"
   "| escaped-string.json | 40.0 | 625.0 | 32.0 | 500.0 |\n"
   "| records-2k.json | 40.0 | 1250.0 | 32.0 | 1000.0 |\n"
   tail))

(test-equal "the report of a few comparators shows only their columns and sections, whole"
  (partial-report "50.0" "40.0" "")
  (report-text machine partial-plan partial-runtimes partial-results))

;; SRFI 180's events and tree on the records file too slow to time.
(define slow-partial-results
  (fold-left (lambda (rs change) (apply with-result rs change))
             partial-results
             (list (list "records-2k.json" 'srfi-180 'events
                         (lambda (r) (too-slow "records-2k.json" 1000000 'srfi-180 'events
                                               100000000000 10000000000 nine)))
                   (list "records-2k.json" 'srfi-180 'tree
                         (lambda (r) (too-slow "records-2k.json" 1000000 'srfi-180 'tree
                                               125000000000 10000000000 '()))))))

(test-equal "lanes too slow to time cross-check clean"
  '()
  (cross-check files partial-plan partial-runtimes slow-partial-results))

(test-equal "the report of lanes too slow to time says so in their cells, and why below, whole"
  (partial-report
   "too slow" "too slow"
   (string-append
    cells-with-no-rate
    "- **records-2k.json, SRFI 180, events:** too slow: one pass took 100.0 s, 0.010 MB/s; the limit is 10.0 s\n"
    "- **records-2k.json, SRFI 180, tree:** too slow: one pass took 125.0 s, 0.0080 MB/s; the limit is 10.0 s\n"))
  (report-text machine partial-plan partial-runtimes slow-partial-results))

(test-end "bench")

(exit (suite-exit-status runner))
