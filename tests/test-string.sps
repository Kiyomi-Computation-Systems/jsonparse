#!r6rs
;;; tests/test-string.sps: (jsonparse string)'s strings and keys (ADR-0010,
;;; ADR-0015, ADR-0016).
;;;
;;; 1. The differential. For every JSONTestSuite file and every yajl case,
;;;    the strings and keys the parser assembles, as UTF-8, must equal the
;;;    key and string events of the generated machine's reference trace
;;;    (trace-events over run-machine) under the same schedule. Whole, in
;;;    chunks of 1, 2, 3 and 7 bytes, under every split into two feeds for
;;;    files of at most 64 bytes, and under three seeded random schedules for
;;;    longer ones. Rejected files count: the strings completed before the
;;;    error must agree too. Numbers run in text mode, so no stop ends a
;;;    parse the reference runs on.
;;; 2. The yajl gold, a second oracle, decoded by yajl itself: each case's
;;;    strings and keys, in order, must equal the gold's. Five cases are left
;;;    out because our parser differs from yajl on them for reasons that
;;;    have nothing to do with a string's text (tests/test-yajl.sps pins
;;;    each): deep_arrays (the depth limit), high_overflow and low_overflow
;;;    (exact integers), isolated_surrogate_marker (a lone surrogate is
;;;    rejected) and leading_zero_in_number (rejected one value earlier).
;;;    The option-prefixed cases run in strict mode and reject early, so
;;;    their strings must be a prefix of the gold's.
;;; 3. Hand-pinned cases, whole traces: every escape, \u at each UTF-8
;;;    length boundary, surrogate pairs, raw UTF-8 of 1 to 4 bytes, mixed
;;;    text, empty strings and keys. Under every split into two and into
;;;    three feeds of the mixed input, the entries are the same as whole
;;;    (the feeds' own results differ with the split, so the entries are
;;;    compared without them, and the last result must be finished).
;;; 4. The API without a parser: sub-ranges, each UTF-8 length, empty and
;;;    repeated takes, a fresh string, reset, bytes that are not UTF-8,
;;;    and the documented pattern, the assembler as the parser's context.
;;; 5. Buffer growth, at 256 and 512 bytes and beyond, with parts and
;;;    escapes straddling each growth point.
;;; 6. Refusals: each an assertion violation, checked by who, message and
;;;    irritants. A sentinel stands for "nothing raised".
;;;
;;; Expected values are written in the suite with \x...; escapes; nothing is
;;; copied from the corpus.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing string)
        (jsonparse-testing yajl)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse string)
        (only (chezscheme) bwp-object? collect weak-cons)
        (only (byte-machine test prng) make-prng))

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

;; --- helpers ----------------------------------------------------------------

(define (u8 s) (string->utf8 s))

;; bytes : (U String (Listof Byte) Bytevector) ... -> Bytevector
;; The parts in order: a string as its UTF-8, a list as its bytes.
(define (bytes . parts)
  (u8-list->bytevector
   (apply append (map (lambda (p)
                        (cond ((string? p) (bytevector->u8-list (u8 p)))
                              ((bytevector? p) (bytevector->u8-list p))
                              (else p)))
                      parts))))

;; j : String -> String
;; JSON text from a string written with ' for a quote and ~ for a backslash.
(define (j s)
  (list->string (map (lambda (c) (case c ((#\') #\") ((#\~) #\\) (else c)))
                     (string->list s))))

(define (range from to)
  (if (>= from to) '() (cons from (range (+ from 1) to))))

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

(define default-options (make-json-options))
(define text-options (make-json-options 'number-mode 'text))

;; --- 1. the differential ----------------------------------------------------

;; Pairs (key BYTES) and (string BYTES), in order.
(define (string-events events)
  (let loop ((es events) (acc '()))
    (cond ((null? es) (reverse acc))
          ((and (pair? (car es)) (memq (caar es) '(key string)))
           (loop (cdr es) (cons (car es) acc)))
          (else (loop (cdr es) acc)))))

(define (as-bytes e) (list (car e) (u8 (cadr e))))

;; The parser's keys and strings under SCHEDULE, as bytes.
(define (parser-strings schedule options)
  (map as-bytes (string-events (run-assembler schedule options))))

;; The reference's, from the generated machine.
(define (reference-strings schedule)
  (string-events (trace-events (run-machine generated-machine schedule '()))))

(define (chunks bv) (map (lambda (k) (cons k (chunk-schedule bv k))) '(1 2 3 7)))

(define (splits bv)
  (let ((len (bytevector-length bv)))
    (map (lambda (i) (cons (list 'split i) (list (list bv 0 i) (list bv i len))))
         (range 0 (+ len 1)))))

(define (random-schedules bv seed)
  (let loop ((k 0) (state (make-prng seed)) (acc '()))
    (if (= k 3)
        (reverse acc)
        (let ((drawn (random-schedule bv state)))
          (loop (+ k 1) (cdr drawn) (cons (cons (list 'random k) (car drawn)) acc))))))

(define (schedules-of bv seed)
  (append (list (cons 'whole (whole-schedule bv)))
          (chunks bv)
          (if (<= (bytevector-length bv) 64) (splits bv) (random-schedules bv seed))))

(define compared 0)

;; The labelled schedules of BV whose assembled strings differ from the
;; reference's: '() or a list of (label parser-strings reference-strings).
(define (differences bv seed)
  (let loop ((ss (schedules-of bv seed)) (bad '()))
    (if (null? ss)
        (reverse bad)
        (let ((mine (parser-strings (cdar ss) text-options))
              (theirs (reference-strings (cdar ss))))
          (set! compared (+ compared (length theirs)))
          (loop (cdr ss)
                (if (equal? mine theirs)
                    bad
                    (cons (list (caar ss) mine theirs) bad)))))))

(define jts-dir "tests/corpus/jsontestsuite/test_parsing/")
(define yajl-dir "tests/corpus/yajl/cases/")

;; (path . bytes) for each corpus file.
(define corpus
  (append
   (map (lambda (f) (cons (string-append jts-dir f) (file-bytes (string-append jts-dir f))))
        (corpus-files jts-dir ".json"))
   (map (lambda (f) (cons (string-append yajl-dir f) (file-bytes (string-append yajl-dir f))))
        (corpus-files yajl-dir ".json"))))

(test-begin "string")

(test-equal "the corpus is 376 files, 23 of them over 64 bytes"
  '(376 23)
  (list (length corpus)
        (length (filter (lambda (f) (> (bytevector-length (cdr f)) 64)) corpus))))

(test-equal "differential: no corpus file's strings differ from the reference's, under any schedule"
  '()
  (let loop ((fs corpus) (seed 20261030) (bad '()))
    (if (null? fs)
        (reverse bad)
        (let ((d (differences (cdar fs) seed)))
          (loop (cdr fs) (+ seed 1)
                (if (null? d) bad (cons (list (caar fs) (car d)) bad)))))))

(test-equal "differential: the reference's strings and keys were compared in numbers"
  #t
  (> compared 5000))

;; --- 2. the yajl gold -----------------------------------------------------------

(define left-out
  '("deep_arrays" "high_overflow" "isolated_surrogate_marker"
    "leading_zero_in_number" "low_overflow"))

(define (prefix-of? p l)
  (or (null? p) (and (pair? l) (equal? (car p) (car l)) (prefix-of? (cdr p) (cdr l)))))

(define (starts-with? s p)
  (and (>= (string-length s) (string-length p)) (string=? p (substring s 0 (string-length p)))))

(define (option-prefixed? name)
  (exists (lambda (p) (starts-with? name p)) '("ac_" "ag_" "am_" "ap_")))

(define yajl-names
  (map (lambda (f) (substring f 0 (- (string-length f) 5))) (corpus-files yajl-dir ".json")))

(define (gold-strings name)
  (string-events (gold-events (file-bytes (string-append yajl-dir name ".json.gold")))))

(define (case-bytes name) (file-bytes (string-append yajl-dir name ".json")))

(test-equal "gold: the left-out cases are yajl cases, and the rest are 58 less 5"
  '(#t 53)
  (list (for-all (lambda (n) (and (member n yajl-names) #t)) left-out)
        (length (filter (lambda (n) (not (member n left-out))) yajl-names))))

(test-equal "gold: each plain case's strings and keys equal the gold's, whole and in chunks of 1, 3 and 31"
  '()
  (filter
   values
   (map (lambda (name)
          (let ((bv (case-bytes name)) (want (gold-strings name)))
            (let ((got (map (lambda (s) (parser-strings s text-options))
                            (list (whole-schedule bv) (chunk-schedule bv 1)
                                  (chunk-schedule bv 3) (chunk-schedule bv 31)))))
              (and (not (for-all (lambda (g) (equal? g want)) got))
                   (list name want got)))))
        (filter (lambda (n) (not (or (member n left-out) (option-prefixed? n)))) yajl-names))))

(test-equal "gold: each option-prefixed case's strings are a prefix of the gold's"
  '()
  (filter
   values
   (map (lambda (name)
          (let ((got (parser-strings (whole-schedule (case-bytes name)) text-options))
                (want (gold-strings name)))
            (and (not (prefix-of? got want)) (list name want got))))
        (filter option-prefixed? yajl-names))))

(test-equal "gold: the plain cases hold 60 or more strings and keys between them"
  #t
  (>= (apply + (map (lambda (n) (length (gold-strings n)))
                    (filter (lambda (n) (not (or (member n left-out) (option-prefixed? n))))
                            yajl-names)))
      60))

;; --- 3. hand-pinned cases ------------------------------------------------------------

;; whole : Bytevector -> Trace
(define (trace-of bv) (run-assembler (whole-schedule bv) default-options))

;; An accepted trace: the entries, then the feed and the finish, which have
;; read all LEN bytes.
(define (accepted entries len)
  (append entries (list (list 'feed 'need-input #f len) (list 'finish 'finished #f len))))

(define (entries-of trace)
  (filter (lambda (e) (not (and (pair? e) (memq (car e) '(feed finish))))) trace))

(define (pin name bv entries)
  (test-equal (string-append "pinned: " name)
    (accepted entries (bytevector-length bv))
    (trace-of bv)))

(define (in-array s) (bytes "[" s "]"))



(define (array-of . strings) (append '(array-start) (map (lambda (s) (list 'string s)) strings) '(array-end)))

;; (name input entries): each input's whole trace is pinned, and then every
;; split of it into two feeds.
(define cases
  (list
   (list "every simple escape, in one string"
         (u8 (j "['~'~~~/~b~f~n~r~t']"))
         (array-of "\"\\/\x8;\xc;\n\r\t"))
   (list "each simple escape alone"
         (u8 (j "['~'','~~','~/','~b','~f','~n','~r','~t']"))
         (array-of "\"" "\\" "/" "\x8;" "\xc;" "\n" "\r" "\t"))
   (list "\\u at the UTF-8 length boundaries"
         (u8 (j "['~u0000','~u007F','~u0080','~u07FF','~u0800','~uFFFF']"))
         (array-of "\x0;" "\x7f;" "\x80;" "\x7ff;" "\x800;" "\xffff;"))
   (list "\\u hex digits in either case, and with text around"
         (u8 (j "['~u00e9','~u00E9','a~u20acb','~uabCD']"))
         (array-of "\xe9;" "\xe9;" "a\x20ac;b" "\xabcd;"))
   (list "surrogate pairs for U+10000, U+1D11E and U+10FFFF"
         (u8 (j "['~uD800~uDC00','~uD834~uDD1E','~uDBFF~uDFFF','x~ud83d~ude00y']"))
         (array-of "\x10000;" "\x1d11e;" "\x10ffff;" "x\x1f600;y"))
   (list "raw UTF-8 of 1, 2, 3 and 4 bytes"
         (bytes "[\"A\",\"" '(#xC3 #xA9) "\",\"" '(#xE2 #x82 #xAC) "\",\""
                '(#xF0 #x9F #x98 #x80) "\",\"" '(#xF4 #x8F #xBF #xBF) "\"]")
         (array-of "A" "\xe9;" "\x20ac;" "\x1f600;" "\x10ffff;"))
   (list "raw and escaped text mixed"
         (bytes "[\"a~u00e9" '(#xC3 #xA9) "~n" '(#xF0 #x9F #x98 #x80) "~uD834~uDD1E" '(#xE2 #x82 #xAC) "z\"]")
         #f)
   (list "the empty string and the empty key"
         (u8 (j "{'':'','a':[''],'':{}}"))
         '(object-start (key "") (string "") (key "a") array-start (string "") array-end
                        (key "") object-start object-end object-end))
   (list "keys with escapes and raw text"
         (bytes "{\"k~u00e9\":\"v\",\"" '(#xE2 #x82 #xAC) "~t\":\"~uD83D~uDE00\"}")
         #f)
   (list "a top-level string"
         (u8 (j "'~u00e9x'"))
         '((string "\xe9;x")))))

;; The mixed cases hold ~ for a backslash; build them here.
(define (tilde bv)
  (u8-list->bytevector (map (lambda (b) (if (= b 126) 92 b)) (bytevector->u8-list bv))))

(define mixed-bytes (tilde (list-ref (list-ref cases 6) 1)))
(define keys-bytes (tilde (list-ref (list-ref cases 8) 1)))

(define all-cases
  (map (lambda (c)
         (cond ((string=? (car c) "raw and escaped text mixed")
                (list (car c) mixed-bytes (array-of "a\xe9;\xe9;\n\x1f600;\x1d11e;\x20ac;z")))
               ((string=? (car c) "keys with escapes and raw text")
                (list (car c) keys-bytes
                      '(object-start (key "k\xe9;") (string "v") (key "\x20ac;\t")
                                     (string "\x1f600;") object-end)))
               (else c)))
       cases))

(for-each
 (lambda (c)
   (let ((bv (cadr c)) (entries (caddr c)))
     (pin (car c) bv entries)))
 all-cases)

;; Every split into two feeds: the entries are the whole run's, and the run
;; finishes at the last byte.
(define (split-failures bv entries schedules)
  (filter values
          (map (lambda (s)
                 (let ((t (run-assembler (cdr s) default-options)))
                   (and (not (and (equal? (entries-of t) entries)
                                  (equal? (car (reverse t))
                                          (list 'finish 'finished #f (bytevector-length bv)))))
                        (list (car s) t))))
               schedules)))

(define (triple-splits bv)
  (let ((len (bytevector-length bv)))
    (apply append
           (map (lambda (i)
                  (map (lambda (k)
                         (cons (list 'split i k)
                               (list (list bv 0 i) (list bv i k) (list bv k len))))
                       (range i (+ len 1))))
                (range 0 (+ len 1))))))

(for-each
 (lambda (c)
   (test-equal (string-append "split in two: " (car c))
     '()
     (split-failures (cadr c) (caddr c) (splits (cadr c)))))
 all-cases)

(for-each
 (lambda (name)
   (let ((c (assoc name all-cases)))
     (test-equal (string-append "split in three: " name)
       '()
       (split-failures (cadr c) (caddr c) (triple-splits (cadr c))))))
 '("raw and escaped text mixed" "surrogate pairs for U+10000, U+1D11E and U+10FFFF"
   "keys with escapes and raw text"))

(test-equal "the split cases cover the multi-byte characters: a split falls inside each one"
  #t
  (let* ((bv mixed-bytes)
         (starts (filter (lambda (i) (and (< 0 i (bytevector-length bv))
                                         (= (bitwise-and (bytevector-u8-ref bv i) #xC0) #x80)))
                         (range 0 (bytevector-length bv)))))
    (>= (length starts) 6)))

;; A rejected input still builds the strings it completed. The x is at
;; offset 16.
(test-equal "an error after a string: the strings stay, and the parse ends in the error"
  '(array-start (string "ab") (string "\xe9;") (feed error unexpected-byte 16))
  (run-assembler
   (whole-schedule (bytes (j "['a~u0062','") '(#xC3 #xA9) "\" x"))
   default-options))

;; --- 4. the API without a parser -------------------------------------------------

;; built : (json-assembler -> Any) -> Any
;; BODY's value on a fresh assembler.
(define (built body) (body (make-json-assembler)))

(define (chars! a bv) (json-assembler-chars! a bv 0 (bytevector-length bv)))

(test-equal "chars!: a sub-range with start above 0"
  "cde"
  (built (lambda (a)
           (json-assembler-chars! a (u8 "abcdefg") 2 5)
           (json-assembler-string! a))))

(test-equal "chars!: several sub-ranges join in order, and an empty range adds nothing"
  "bcxyzg"
  (built (lambda (a)
           (json-assembler-chars! a (u8 "abcdefg") 1 3)
           (json-assembler-chars! a (u8 "abcdefg") 4 4)
           (json-assembler-chars! a (u8 "xyzxyz") 0 3)
           (json-assembler-chars! a (u8 "abcdefg") 6 7)
           (json-assembler-string! a))))

(test-equal "chars!: a sub-range of a multi-byte character's parts, cut inside it"
  "\x20ac;\xe9;"
  (built (lambda (a)
           (let ((bv (bytes '(0 #xE2 #x82 #xAC #xC3 #xA9 0))))
             (json-assembler-chars! a bv 1 3)
             (json-assembler-chars! a bv 3 4)
             (json-assembler-chars! a bv 4 5)
             (json-assembler-chars! a bv 5 6)
             (json-assembler-string! a)))))

(define boundaries
  ;; (scalar bytes-in-UTF-8)
  '((#x0 1) (#x41 1) (#x7F 1) (#x80 2) (#x7FF 2) (#x800 3) (#xD7FF 3) (#xE000 3)
    (#xFFFF 3) (#x10000 4) (#x10FFFF 4)))

(for-each
 (lambda (b)
   (test-equal (string-append "escape!: U+" (number->string (car b) 16) " is "
                              (number->string (cadr b)) " byte(s)")
     (list (string (integer->char (car b))) (cadr b))
     (built (lambda (a)
              (json-assembler-escape! a (car b))
              ;; The string, and the UTF-8 length it encodes to.
              (let ((s (json-assembler-string! a)))
                (list s (bytevector-length (string->utf8 s))))))))
 boundaries)

(test-equal "escape!: all the boundary scalars in one string, with chars between"
  (apply string-append
         (map (lambda (b) (string-append (string (integer->char (car b))) "-")) boundaries))
  (built (lambda (a)
           (for-each (lambda (b)
                       (json-assembler-escape! a (car b))
                       (chars! a (u8 "-")))
                     boundaries)
           (json-assembler-string! a))))

(test-equal "string!: with no parts it is the empty string"
  ""
  (built json-assembler-string!))

(test-equal "string!: taken twice in a row, the second is the empty string"
  '("abc" "" "")
  (built (lambda (a)
           (chars! a (u8 "abc"))
           (let* ((first (json-assembler-string! a))
                  (second (json-assembler-string! a))
                  (third (json-assembler-string! a)))
             (list first second third)))))

(test-equal "string!: taking empties the assembler, so the next text starts clean"
  '("abc" "de")
  (built (lambda (a)
           (chars! a (u8 "abc"))
           (let ((first (json-assembler-string! a)))
             (chars! a (u8 "de"))
             (list first (json-assembler-string! a))))))

(test-equal "string!: a returned string is fresh; changing it changes nothing later"
  '("abc" "abc" #f "zbc")
  (built (lambda (a)
           (chars! a (u8 "abc"))
           (let ((first (json-assembler-string! a)))
             (chars! a (u8 "abc"))
             (let ((second (json-assembler-string! a)))
               (string-set! first 0 #\z)
               (list second (string-copy second) (eq? first second) first))))))

(test-equal "string!: the returned string is not the assembler's own text, even for a second one"
  '("xbc" "abc")
  (built (lambda (a)
           (chars! a (u8 "abc"))
           (let ((first (json-assembler-string! a)))
             (string-set! first 0 #\x)
             (chars! a (u8 "abc"))
             (list first (json-assembler-string! a))))))

(test-equal "chars!: changing the bytevector afterwards changes nothing"
  "abc"
  (built (lambda (a)
           (let ((bv (u8 "abc")))
             (chars! a bv)
             (bytevector-u8-set! bv 0 122)
             (json-assembler-string! a)))))

(test-equal "reset!: drops a half-built string"
  '("d" "")
  (built (lambda (a)
           (chars! a (u8 "abc"))
           (json-assembler-escape! a #x1F600)
           (json-assembler-reset! a)
           (chars! a (u8 "d"))
           (let ((first (json-assembler-string! a)))
             (json-assembler-reset! a)
             (list first (json-assembler-string! a))))))

(test-equal "reset!: on an empty assembler leaves it empty"
  ""
  (built (lambda (a) (json-assembler-reset! a) (json-assembler-string! a))))

(test-equal "bytes that are not UTF-8 become U+FFFD"
  '("a\xfffd;b" "\xfffd;" "\xe9;\xfffd;")
  (built (lambda (a)
           (chars! a (bytes '(#x61 #xFF #x62)))
           (let* ((x (json-assembler-string! a))
                  (y (begin (chars! a (bytes '(#xFE))) (json-assembler-string! a)))
                  (z (begin (chars! a (bytes '(#xC3 #xA9 #xFF))) (json-assembler-string! a))))
             (list x y z)))))

;; The documented pattern: the assembler is the parser's context, and
;; chars, escape and number-chars are the assembler's procedures as they are.
(define (parse-with-pattern text)
  (let* ((a (make-json-assembler))
         (seen '())
         (note! (lambda (x) (set! seen (cons x seen))))
         (handler (make-json-handler
                   'chars json-assembler-chars!
                   'escape json-assembler-escape!
                   'key-end (lambda (a) (note! (list 'key (json-assembler-string! a))) #f)
                   'string-end (lambda (a) (note! (list 'string (json-assembler-string! a))) #f)
                   'number-chars json-assembler-number-chars!
                   'number-end (lambda (a) (note! (list 'number (json-assembler-number! a))) #f)))
         (parser (make-json-parser handler a))
         (fed (json-parser-feed! parser (u8 text)))
         (done (json-parser-finish! parser)))
    (list (reverse seen) (json-result-status fed) (json-result-status done))))

(test-equal "the documented pattern: the assembler as context, three procedures passed as they are"
  '(((key "k\xe9;") (string "a\x1f600;\xe9;b") (number 12) (string "")) need-input finished)
  (parse-with-pattern (j "{'k~u00e9':['a~uD83D~uDE00~u00e9b',12,'']}")))

;; --- 5. buffer growth ---------------------------------------------------------------

;; The text at position i of a pattern that tells every position apart
;; (mod 26) and so shows a byte lost or moved.
(define (pattern-char i) (integer->char (+ 97 (mod i 26))))

(define (pattern n offset)
  (let ((s (make-string n)))
    (for-each (lambda (i) (string-set! s i (pattern-char (+ offset i)))) (range 0 n))
    s))

;; Feeds the pattern of N bytes to A in parts of the sizes in SIZES, taken
;; in turn, then takes the string.
(define (assemble-in-parts a n sizes)
  (let ((text (u8 (pattern n 0))))
    (let loop ((at 0) (ss sizes))
      (when (< at n)
        (let ((end (min n (+ at (car ss)))))
          (json-assembler-chars! a text at end)
          (loop end (if (null? (cdr ss)) sizes (cdr ss))))))
    (json-assembler-string! a)))

(for-each
 (lambda (n)
   (for-each
    (lambda (sizes)
      (test-equal (string-append "growth: " (number->string n) " bytes in parts of "
                                 (apply string-append
                                        (map (lambda (s) (string-append (number->string s) " ")) sizes)))
        (pattern n 0)
        (built (lambda (a) (assemble-in-parts a n sizes)))))
    '((1) (7 100 3) (256) (1000) (100000))))
 '(255 256 257 512 513 100000))

(test-equal "growth: a single part larger than double the buffer, after a small one"
  (string-append "z" (pattern 1500 0))
  (built (lambda (a)
           (chars! a (u8 "z"))
           (chars! a (u8 (pattern 1500 0)))
           (json-assembler-string! a))))

(test-equal "growth: a part past two doublings in one step, on a buffer filled to the brim"
  (string-append (pattern 256 0) (pattern 3000 0))
  (built (lambda (a)
           (chars! a (u8 (pattern 256 0)))
           (chars! a (u8 (pattern 3000 0)))
           (json-assembler-string! a))))

;; Escapes of 2, 3 and 4 bytes, placed so the escape starts at each byte
;; from K-1 before the growth point to the point itself.
(define escape-samples '((#xE9 2) (#x20AC 3) (#x1F600 4)))

(define (straddle-cases point)
  (apply append
         (map (lambda (sample)
                (map (lambda (before)
                       (list (car sample) (- point before)))
                     (range 0 (+ (cadr sample) 2))))
              escape-samples)))

(define (straddle-failures point)
  (filter values
          (map (lambda (case)
                 (let* ((scalar (car case)) (prefix (cadr case))
                        (want (string-append (pattern prefix 0) (string (integer->char scalar))
                                             (pattern 300 7)))
                        (got (built (lambda (a)
                                      (chars! a (u8 (pattern prefix 0)))
                                      (json-assembler-escape! a scalar)
                                      (chars! a (u8 (pattern 300 7)))
                                      (json-assembler-string! a)))))
                   (and (not (string=? want got)) (list scalar prefix))))
               (straddle-cases point))))

(test-equal "growth: escapes of 2, 3 and 4 bytes straddling or touching 256"
  '() (straddle-failures 256))

(test-equal "growth: ... and 512"
  '() (straddle-failures 512))

(test-equal "growth: ... and 1024, after the buffer grew twice by escapes"
  '()
  (filter values
          (map (lambda (case)
                 (let* ((scalar (car case)) (prefix (cadr case))
                        (want (string-append (pattern 300 0) (pattern prefix 5)
                                             (string (integer->char scalar))))
                        (got (built (lambda (a)
                                      (chars! a (u8 (pattern 300 0)))
                                      (chars! a (u8 (pattern prefix 5)))
                                      (json-assembler-escape! a scalar)
                                      (json-assembler-string! a)))))
                   (and (not (string=? want got)) (list scalar prefix))))
               (map (lambda (c) (list (car c) (- (cadr c) 300))) (straddle-cases 1024)))))

(test-equal "growth: a string built from escapes alone, 4 bytes each, 100000 of them"
  (make-string 100000 #\x1F600)
  (built (lambda (a)
           (for-each (lambda (i) (json-assembler-escape! a #x1F600)) (range 0 100000))
           (json-assembler-string! a))))

(test-equal "growth: escapes of every length alternating, 30000 of them"
  (let ((cycle (list #\a #\xE9 #\x20AC #\x1F600)))
    (list->string (map (lambda (i) (list-ref cycle (mod i 4))) (range 0 30000))))
  (built (lambda (a)
           (for-each (lambda (i)
                       (json-assembler-escape! a (char->integer (list-ref (list #\a #\xE9 #\x20AC #\x1F600)
                                                                           (mod i 4)))))
                     (range 0 30000))
           (json-assembler-string! a))))

(test-equal "growth: the buffer keeps its size, so a small string after a large one is right"
  '("small" "")
  (built (lambda (a)
           (assemble-in-parts a 100000 '(1000))
           (chars! a (u8 "small"))
           (let ((s (json-assembler-string! a)))
             (list s (json-assembler-string! a))))))

(test-equal "growth: one assembler builds many strings of different sizes, each right"
  '()
  (let ((a (make-json-assembler)))
    (filter values
            (map (lambda (n)
                   (and (not (string=? (pattern n 3) (begin (let ((t (u8 (pattern n 3))))
                                                              (chars! a t))
                                                            (json-assembler-string! a))))
                        n))
                 '(10 300 5 600 0 255 1025 2 100000 7)))))

;; 1-byte escapes at a growth point: the buffer must grow for them too.
(define one-byte-escapes '(10 34 92 65))

(define (one-byte-failures prefix)
  (filter values
          (map (lambda (scalar)
                 (let ((got (built (lambda (a)
                                     (chars! a (u8 (pattern prefix 0)))
                                     (json-assembler-escape! a scalar)
                                     (chars! a (u8 "z"))
                                     (json-assembler-string! a))))
                       (want (string-append (pattern prefix 0) (string (integer->char scalar)) "z")))
                   (and (not (string=? got want)) (list scalar prefix))))
               one-byte-escapes)))

(test-equal "growth: a 1-byte escape landing exactly at fill 256, 512 and 1024, and one byte either side"
  '()
  (apply append (map one-byte-failures '(255 256 257 511 512 513 1023 1024 1025))))

(test-equal "growth: a string of 1-byte escapes alone, its fill crossing each power of two to 4096"
  (pattern 5000 0)
  (built (lambda (a)
           (for-each (lambda (i) (json-assembler-escape! a (char->integer (pattern-char i))))
                     (range 0 5000))
           (json-assembler-string! a))))

(test-equal "growth: chars and 1-byte escapes alternating, escapes at the even positions, so the fill meets each power of two on an escape"
  (pattern 5000 0)
  (built (lambda (a)
           (for-each (lambda (i)
                       (if (odd? i)
                           (json-assembler-chars! a (u8 (pattern 1 i)) 0 1)
                           (json-assembler-escape! a (char->integer (pattern-char i)))))
                     (range 0 5000))
           (json-assembler-string! a))))

(test-equal "through the parser: 256 bytes and then a 1-byte escape, and the same at 512"
  (list (accepted (list (list 'string (string-append (pattern 256 0) "\n"))) 260)
        (accepted (list (list 'string (string-append (pattern 512 0) "\"" ))) 516))
  (list (trace-of (bytes "\"" (pattern 256 0) (j "~n") "\""))
        (trace-of (bytes "\"" (pattern 512 0) (j "~'") "\""))))

;; Two live assemblers, their parts and escapes interleaved: each gives back
;; its own string.
(test-equal "two assemblers, interleaved parts and escapes, each give back their own string"
  '("abc\x20ac;defg" "XY\x1f600;Z\n!" "" "k")
  (let ((a (make-json-assembler)) (b (make-json-assembler)))
    (chars! a (u8 "abc"))
    (chars! b (u8 "XY"))
    (json-assembler-escape! a #x20AC)
    (json-assembler-escape! b #x1F600)
    (chars! a (u8 "def"))
    (chars! b (u8 "Z"))
    (json-assembler-escape! b 10)
    (json-assembler-escape! a 103)
    (chars! b (u8 "!"))
    (let* ((sa (json-assembler-string! a))
           (sb (json-assembler-string! b))
           (empty (json-assembler-string! a)))
      (chars! b (u8 "k"))
      (list sa sb empty (json-assembler-string! b)))))

(test-equal "two assemblers grown in turn past several growth points, each right"
  (list (pattern 3000 0) (pattern 2500 9))
  (let ((a (make-json-assembler)) (b (make-json-assembler)))
    (for-each (lambda (i)
                (json-assembler-chars! a (u8 (pattern 1 i)) 0 1)
                (when (< i 2500) (json-assembler-escape! b (char->integer (pattern-char (+ i 9))))))
              (range 0 3000))
    (let* ((sb (json-assembler-string! b)) (sa (json-assembler-string! a)))
      (list sa sb))))

(test-equal "two assemblers: a reset of one leaves the other's text"
  '("" "keep")
  (let ((a (make-json-assembler)) (b (make-json-assembler)))
    (chars! a (u8 "drop"))
    (chars! b (u8 "keep"))
    (json-assembler-reset! a)
    (list (json-assembler-string! a) (json-assembler-string! b))))

;; Retention: the assembler keeps no reference to a string it returned. A
;; weak pair holds the only other reference; after a collection it is broken.
(define (weak-of-built-string chars-text)
  (let ((a (make-json-assembler)))
    (chars! a (u8 chars-text))
    (weak-cons (json-assembler-string! a) #f)))

(define (weak-of-long-string)
  (let ((a (make-json-assembler)))
    (assemble-in-parts a 5000 '(300))
    (chars! a (u8 "x"))
    (weak-cons (json-assembler-string! a) #f)))

(define (kept-string-survives)
  ;; The control: a string held by the test survives the same collection.
  (let* ((a (make-json-assembler))
         (s (begin (chars! a (u8 "held")) (json-assembler-string! a)))
         (w (weak-cons s #f)))
    (collect)
    (and (eq? (car w) s) (string=? s "held"))))

(test-equal "control: a string the test holds survives a collection"
  #t
  (kept-string-survives))

(let ((w1 (weak-of-built-string "abc"))
      (w2 (weak-of-long-string)))
  (collect)
  (test-equal "retention: after a collection, strings the assembler returned are gone (small, then 5,000 bytes)"
    '(#t #t)
    (list (bwp-object? (car w1)) (bwp-object? (car w2)))))

;; --- 6. refusals --------------------------------------------------------------------

;; refusal : (-> Any) -> (U 'no-raise (List who message irritants) (List 'other Text))
;; What THUNK raised. A sentinel for a return, which is no refusal.
(define (refusal thunk)
  (guard (e ((assertion-violation? e)
             (list (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (and (irritants-condition? e) (condition-irritants e))))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

(define a0 (make-json-assembler))
(define bv0 (u8 "abcdef"))

(for-each
 (lambda (thing)
   (for-each
    (lambda (entry)
      (let ((who (car entry)) (call (cadr entry)))
        (test-equal (string-append (symbol->string who) " given " (describe thing))
          (list who "not an assembler" (list thing))
          (refusal (lambda () (call thing))))))
    (list (list 'json-assembler-chars! (lambda (x) (json-assembler-chars! x bv0 0 1)))
          (list 'json-assembler-escape! (lambda (x) (json-assembler-escape! x 65)))
          (list 'json-assembler-string! (lambda (x) (json-assembler-string! x)))
          (list 'json-assembler-number-chars! (lambda (x) (json-assembler-number-chars! x bv0 0 1)))
          (list 'json-assembler-number! (lambda (x) (json-assembler-number! x)))
          (list 'json-assembler-reset! (lambda (x) (json-assembler-reset! x))))))
 (list 42 #f bv0 "assembler" (make-json-options)))

(test-equal "chars! checks the assembler before the bytevector"
  '(json-assembler-chars! "not an assembler" (1))
  (refusal (lambda () (json-assembler-chars! 1 "no" 0 0))))

(for-each
 (lambda (who proc)
   (for-each
    (lambda (thing)
      (test-equal (string-append (symbol->string who) " given the non-bytevector " (describe thing))
        (list who "not a bytevector" (list thing))
        (refusal (lambda () (proc a0 thing 0 0)))))
    (list "abcdef" #f '(1 2) 7 (vector 1 2)))
   (for-each
    (lambda (r)
      (test-equal (string-append (symbol->string who) " given the range " (describe (car r)) " "
                                 (describe (cadr r)))
        (list who "the range is not within the bytevector" (list (car r) (cadr r) 6))
        (refusal (lambda () (proc a0 bv0 (car r) (cadr r))))))
    (list '(3 2) '(0 7) '(7 7) '(-1 3) '(0 -1) '(-2 -1) '(1.0 3) '(0 3.0) '(a 3) '(0 b)
          '(#f 3) '(0 #f) (list (expt 2 70) (expt 2 71)) (list 0 (expt 2 70)) '(1/2 3))))
 '(json-assembler-chars! json-assembler-number-chars!)
 (list json-assembler-chars! json-assembler-number-chars!))

(test-equal "a valid full range, an empty range at the end, and an empty range at the start are no refusal"
  '(no-raise no-raise no-raise)
  (list (let ((r (refusal (lambda () (json-assembler-chars! a0 bv0 0 6))))) (json-assembler-reset! a0) r)
        (let ((r (refusal (lambda () (json-assembler-chars! a0 bv0 6 6))))) (json-assembler-reset! a0) r)
        (let ((r (refusal (lambda () (json-assembler-chars! a0 bv0 0 0))))) (json-assembler-reset! a0) r)))

(for-each
 (lambda (x)
   (test-equal (string-append "escape! given " (describe x))
     (list 'json-assembler-escape! "not a Unicode scalar value" (list x))
     (refusal (lambda () (json-assembler-escape! a0 x)))))
 (list #xD800 #xDFFF #xDBFF #xDC00 #x110000 #x7FFFFFFF -1 -65 1.0 65.0 'x "A" #f (expt 2 70) 1/2 #\A))

(test-equal "a refused call writes nothing: each refusal is the one expected, and the text before is whole"
  '((json-assembler-chars! "the range is not within the bytevector" (4 9 6))
    (json-assembler-escape! "not a Unicode scalar value" (#xD800))
    (json-assembler-chars! "the range is not within the bytevector" (5 2 6))
    "ab")
  (let ((a (make-json-assembler)))
    (chars! a (u8 "ab"))
    (let* ((r1 (refusal (lambda () (json-assembler-chars! a bv0 4 9))))
           (r2 (refusal (lambda () (json-assembler-escape! a #xD800))))
           (r3 (refusal (lambda () (json-assembler-chars! a bv0 5 2))))
           (s (json-assembler-string! a)))
      (list r1 r2 r3 s))))

(for-each
 (lambda (x)
   (test-equal (string-append "make-json-assembler given " (describe x))
     (list 'make-json-assembler "not an options record" (list x))
     (refusal (lambda () (make-json-assembler x)))))
 (list 42 #f 'flonum "options" '() (vector) bv0 '(number-mode text)))

(test-equal "make-json-assembler given options, and none, is no refusal"
  '(no-raise no-raise)
  (list (refusal (lambda () (make-json-assembler)))
        (refusal (lambda () (make-json-assembler (make-json-options 'number-mode 'exact))))))

(test-end "string")

(exit (suite-exit-status runner))
