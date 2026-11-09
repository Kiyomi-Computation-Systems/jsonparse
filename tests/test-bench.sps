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
;;;   6. the report cross-checks every lane and parser before it prints, and
;;;      prints exactly the text below.
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

(test-equal "consistent results cross-check clean"
  '()
  (cross-check files runtimes results))

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
         (cross-check files runtimes
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
         (cross-check files runtimes
                      (with-result results "escaped-string.json" 'jsonparse 'tree+walk
                                   (lambda (r) (replace-counts r (bump (without-number-bytes events-fixture) name))))))
       (map car (without-number-bytes events-fixture))))

(test-equal "scan's number bytes must be the handler's"
  '("records-2k.json: scan number: events 100000, scan 99999")
  (cross-check files runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan
                            (lambda (r)
                              (replace-counts r '((string . 400000) (number . 99999)
                                                  (whitespace . 200000) (other . 300001)))))))

(test-equal "scan must cover the file's bytes"
  '("records-2k.json: scan covers 999999 bytes of 1000000")
  (cross-check files runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan
                            (lambda (r)
                              (replace-counts r '((string . 400000) (number . 100000)
                                                  (whitespace . 200000) (other . 299999)))))))

(test-equal "a result that read another size than the file's first result is named"
  '("records-2k.json: jsonparse scan read 999999 bytes, not 1000000"
    "records-2k.json: scan covers 1000000 bytes of 999999")
  (cross-check files runtimes
               (with-result results "records-2k.json" 'jsonparse 'scan
                            (lambda (r)
                              (map-fields (lambda (field) (if (eq? (car field) 'bytes) '(bytes 999999) field)) r)))))

(test-equal "a lane whose timed passes counted otherwise than its passes times one pass's is named"
  '(("records-2k.json: yajl events timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse events timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse tree+walk timed passes counted null 201, not 200")
    ("records-2k.json: jsonparse scan timed passes counted string 80000001, not 80000000"))
  (map (lambda (parser lane)
         (cross-check files runtimes
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
  (cross-check files runtimes
               (with-result results "escaped-string.json" 'jsonparse 'events
                            (lambda (r)
                              (cons (car r) (filter (lambda (field) (not (eq? (car field) 'timed-counts)))
                                                    (cdr r)))))))

(test-equal "a lane that ran other passes than ten rounds of iterations-for's is named"
  '(("records-2k.json: yajl parse ran 199 passes, not 200")
    ("records-2k.json: jsonparse tree ran 210 passes, not 200"))
  (list (cross-check files runtimes
                     (with-result results "records-2k.json" 'yajl 'parse
                                  (lambda (r) (set-field r 'passes 199))))
        (cross-check files runtimes
                     (with-result results "records-2k.json" 'jsonparse 'tree
                                  (lambda (r) (set-field r 'passes 210))))))

(test-equal "a lane that ran other passes a round than iterations-for's is named"
  '("escaped-string.json: jsonparse scan ran 39 passes a round, not 40")
  (cross-check files runtimes
               (with-result results "escaped-string.json" 'jsonparse 'scan
                            (lambda (r) (set-field r 'iterations 39)))))

(test-equal "the lock's files are the results' files"
  '(("x.json: no results")
    ("escaped-string.json: not in the lock"))
  (list (cross-check (append files '("x.json")) runtimes results)
        (cross-check '("records-2k.json") runtimes results)))

(test-equal "a missing lane is named"
  '("escaped-string.json: no yajl parse result")
  (cross-check files runtimes
               (filter (lambda (r) (not (and (equal? (cadr (assq 'file (cdr r))) "escaped-string.json")
                                             (eq? (cadr (assq 'parser (cdr r))) 'yajl)
                                             (eq? (cadr (assq 'lane (cdr r))) 'parse))))
                       results)))

(test-equal "a lane given twice is named"
  '("records-2k.json: jsonparse scan given twice")
  (cross-check files runtimes (append results (list (list-ref results 6)))))

(test-equal "a result with other rounds than its runtime's is named"
  '("records-2k.json: jsonparse tree has 8 rounds, not 9")
  (cross-check files runtimes
               (with-result results "records-2k.json" 'jsonparse 'tree
                            (lambda (r)
                              (map-fields (lambda (field) (if (eq? (car field) 'round-ns) (cons 'round-ns (cddr field)) field))
                                          r)))))

(test-equal "a parser with two runtimes is named"
  '("yajl has 2 runtimes")
  (cross-check files (append runtimes (list (cadr runtimes))) results))

(test-equal "runtimes that differ in rounds or round bytes are named"
  '(("yajl ran 9 rounds of 10000000 bytes, jsonparse 9 of 20000000")
    ("yajl ran 7 rounds of 20000000 bytes, jsonparse 9 of 20000000"))
  (map (lambda (rounds round-bytes)
         (cross-check files (list (car runtimes)
                            `(runtime (parser yajl) (version "2.1.0") (compiler "gcc 14.3.0") (flags "-O2")
                                      (rounds ,rounds) (round-bytes ,round-bytes)))
                      results))
       '(9 7) '(10000000 20000000)))

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

(test-equal "group-digits puts a comma every three digits"
  '("0" "999" "1,000" "12,345" "1,000,000")
  (map group-digits '(0 999 1000 12345 1000000)))

(define expected-report
  (string-append
   "# jsonparse benchmarks\n"
   "\n"
   "- **Date (UTC):** 2026-11-08\n"
   "- **Machine:** CPU X, x86_64, Linux 1.0\n"
   "- **jsonparse:** Chez Scheme Version 10.4.1 (ta6le), libraries compiled ahead of time at optimize-level 0\n"
   "- **yajl:** 2.1.0; its harness built by gcc 14.3.0 with -O2\n"
   "- **Pinned:** CPU 7, at most 4500 MHz, governor powersave\n"
   "- **Method:** a warm-up round, then 9 timed rounds of at least 20,000,000 bytes each (ADR-0013). Rates are MB/s, where 1 MB is 10^6 bytes: the best round, then the median. A gap is yajl's median over jsonparse's.\n"
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
   "`tree` builds the value with `bytevector->json`, and `tree+walk` then counts it as `events` does. `scan` only sorts each byte as The files does: the least a Scheme loop reading a byte at a time does.\n"
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

(test-equal "the report, whole"
  expected-report
  (report-text machine runtimes results))

(test-end "bench")

(exit (suite-exit-status runner))
