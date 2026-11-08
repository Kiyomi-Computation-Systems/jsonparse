#!r6rs
;;; tests/test-tree.sps: the values (jsonparse tree) builds (ADR-0006,
;;; ADR-0011, ADR-0017).
;;;
;;; 1. The differential. For every JSONTestSuite file, every yajl case and
;;;    every nativejson-benchmark round-trip file,
;;;    under the defaults and four option sets that together use every
;;;    non-default value of number-mode, object-mode, null, digit-limit and
;;;    depth-limit, the builder's results and value must equal the
;;;    reference's (reference-run folds run-assembler's trace by recursive
;;;    descent).
;;;    Whole, in chunks of 1, 2, 3 and 7 bytes, under every split into two
;;;    feeds for files of at most 64 bytes, and under three seeded random
;;;    schedules for longer ones. Counts measured in the same run show the
;;;    runs held values and each of the stops and errors.
;;; 2. Pinned values, written by hand, whole outputs.
;;; 3. The stack's growth: documents whose slot counts fall at, and either
;;;    side of, each of the first three growth points, as arrays and as
;;;    objects, at the top and inside one and two outer containers.
;;; 4. Depth: nested arrays, objects and both alternating, at and one past
;;;    the limits.
;;; 5. Stops: number-too-long and number-out-of-range, in every position.
;;; 6. Chunking invariance of one document of every kind of value.
;;;
;;; Expected values are written in the suite with \x...; escapes; nothing is
;;; copied from the corpus or from the reference.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing parser)
        (jsonparse-testing tree)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse string)
        (jsonparse tree)
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

(define (->bv x) (if (bytevector? x) x (u8 x)))

;; A record of the suite's own to stand for null, and a second with the same
;; contents, which is not the same record.
(define-record-type nothing (fields tag))
(define nil-a (make-nothing 'same))
(define nil-b (make-nothing 'same))

;; build : (U String Bytevector) json-options -> (U Value #(failed Code Offset))
;; The raw value a builder gives for the input fed whole, or the error, or
;; what a raise was.
(define (build text options)
  (guard (e (#t (vector 'raised (describe e))))
    (let ((b (make-json-builder options)))
      (json-builder-feed! b (->bv text))
      (let ((r (json-builder-finish! b)))
        (if (eq? (json-result-status r) 'finished)
            (json-builder-value b)
            (vector 'failed (json-result-code r) (json-result-offset r)))))))

(define (opts . args) (apply make-json-options args))

;; tree : (U String Bytevector) Any ... -> (List 'built Canonical)
;; Everything that can raise is inside the guard, and the answer is tagged,
;; so a raise, a failure or a cleared stack slot (#f) is never a value.
(define (tree text . args)
  (guard (e (#t (list 'raised (describe e))))
    (list 'built (canonical (build text (apply opts args))))))

;; (name input expected . options)
(define (pin name text expected . args)
  (test-equal (string-append "pinned: " name)
    (list 'built expected)
    (apply tree text args)))

;; raises : (-> Any) -> (U 'raised 'returned)
(define (raises thunk)
  (guard (e ((assertion-violation? e) 'raised))
    (thunk)
    'returned))

;; --- 1. the differential ----------------------------------------------------

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

;; Five option sets: the defaults, which callers use most, and four that
;; each differ from the defaults in at least one dimension and together use
;; every non-default value.
(define diff-options
  (list (cons 'defaults (opts))
        (cons 'flonum-hashtable-nil
              (opts 'object-mode 'hashtable 'null 'nil))
        (cons 'exact-record
              (opts 'number-mode 'exact 'null nil-a))
        (cons 'text-hashtable-record-depth3
              (opts 'number-mode 'text 'object-mode 'hashtable 'null nil-b 'depth-limit 3))
        (cons 'exact-digits4-depth9
              (opts 'number-mode 'exact 'digit-limit 4 'depth-limit 9 'null 'void))))

;; Counts of runs by outcome, measured as the differential goes.
(define value-runs 0)
(define code-runs (make-eq-hashtable))   ; code -> count

(define (count-code! code)
  (hashtable-set! code-runs code (+ 1 (hashtable-ref code-runs code 0))))

(define (runs-with code) (hashtable-ref code-runs code 0))

(define (note-run! run)
  (let ((last (car (reverse run))))
    (cond ((eq? (car last) 'value) (set! value-runs (+ value-runs 1)))
          ((eq? (cadr last) 'error) (count-code! (caddr last))))))

;; The labelled runs of BV whose results or value differ from the reference's.
(define (differences bv seed)
  (let loop ((ss (schedules-of bv seed)) (bad '()))
    (if (null? ss)
        (reverse bad)
        (let loop2 ((os diff-options) (bad bad))
          (if (null? os)
              (loop (cdr ss) bad)
              (let* ((mine (run-builder (cdar ss) (cdar os)))
                     (theirs (reference-run (cdar ss) (cdar os))))
                (note-run! mine)
                (loop2 (cdr os)
                       (if (equal? mine theirs)
                           bad
                           (cons (list (caar ss) (caar os) mine theirs) bad)))))))))

(define jts-dir "tests/corpus/jsontestsuite/test_parsing/")
(define yajl-dir "tests/corpus/yajl/cases/")
(define nj-dir "tests/corpus/nativejson-benchmark/files/")

(define corpus
  (append
   (map (lambda (f) (cons (string-append jts-dir f) (file-bytes (string-append jts-dir f))))
        (corpus-files jts-dir ".json"))
   (map (lambda (f) (cons (string-append yajl-dir f) (file-bytes (string-append yajl-dir f))))
        (corpus-files yajl-dir ".json"))
   (map (lambda (f) (cons (string-append nj-dir f) (file-bytes (string-append nj-dir f))))
        (corpus-files nj-dir ".json"))))

(test-begin "tree")

(test-equal "the corpus is 403 files, 23 of them over 64 bytes"
  '(403 23)
  (list (length corpus)
        (length (filter (lambda (f) (> (bytevector-length (cdr f)) 64)) corpus))))

(test-equal "differential: no run's results or value differ from the reference's"
  '()
  (let loop ((fs corpus) (seed 20261101) (bad '()))
    (if (null? fs)
        (reverse bad)
        (let ((d (differences (cdar fs) seed)))
          (loop (cdr fs) (+ seed 1)
                (if (null? d) bad (cons (list (caar fs) (car d)) bad)))))))

(test-equal "differential: the runs held values, and every kind of stop and error"
  '(#t #t #t #t #t #t)
  (list (> value-runs 1000)
        (> (runs-with 'unexpected-byte) 1000)
        (> (runs-with 'unexpected-eof) 100)
        (> (runs-with 'nesting-too-deep) 100)
        (> (runs-with 'number-too-long) 10)
        (> (runs-with 'number-out-of-range) 10)))

;; --- 2. pinned values ---------------------------------------------------------

(pin "the empty object" "{}" '())
(pin "the empty array" "[]" '#())
(pin "null" "null" 'null)
(pin "true" "true" #t)
(pin "false" "false" #f)
(pin "the empty object under hashtable" "{}" '(hashtable) 'object-mode 'hashtable)

;; numbers, in each mode
(pin "numbers in flonum mode" "[1,-0,-0.0,1.5,1e2]" '#(1 0 -0.0 1.5 100.0))
(pin "numbers in exact mode" "[1,-0,-0.0,1.5,1e2]" '#(1 0 0 3/2 100) 'number-mode 'exact)
(pin "numbers in text mode" "[1,-0,-0.0,1.5,1e2]"
     '#((json-number "1") (json-number "-0") (json-number "-0.0")
        (json-number "1.5") (json-number "1e2"))
     'number-mode 'text)
(pin "a flonum at top level" "1.5" 1.5)
(pin "an integer at top level, flonum mode" " -0 " 0)
(pin "negative zero flonum at top level" "-0.0" -0.0)
(pin "1e2 flonum at top level" "1e2" 100.0)
(pin "1e2 exact at top level" "1e2" 100 'number-mode 'exact)
(pin "1.5 exact at top level" "1.5" 3/2 'number-mode 'exact)
(pin "1 text at top level" "1" '(json-number "1") 'number-mode 'text)
(pin "-0.0 text at top level" "-0.0" '(json-number "-0.0") 'number-mode 'text)

;; top-level scalars, with whitespace around them
(pin "a string at top level, with whitespace" " \t\n\r \"hi\" \n " "hi")
(pin "true with whitespace" "\n true\t" #t)
(pin "false with whitespace" "  false  " #f)
(pin "null with whitespace" "\r\n null \r\n" 'null)
(pin "null with whitespace under the symbol nil" "\r\n null \r\n" 'nil 'null 'nil)
(pin "a number with whitespace" "\t 12 \t" 12)
(pin "an empty array with whitespace" " \n[ \t]\r " '#())
(pin "an empty object with whitespace" " \n{ \t}\r " '())
(pin "every literal in an array"
     "[true,false,null,true]" '#(#t #f null #t))
(pin "a kind of every scalar in an array, under non-default options"
     "[\"s\",7,true,false,null,2.5]" '#("s" 7 #t #f nil 5/2)
     'number-mode 'exact 'null 'nil 'object-mode 'hashtable)

;; strings and keys
(pin "every simple escape in one string"
     (j "['~'~~~/~b~f~n~r~t']") '#("\"\\/\x8;\xc;\n\r\t"))
(pin "\\u at each UTF-8 length, and a surrogate pair"
     (j "['~u0041','~u00e9','~u20ac','~uD83D~uDE00','~u0000','~u007F','~u0080','~u07FF','~u0800','~uFFFF','~uD800~uDC00','~uDBFF~uDFFF']")
     '#("A" "\xe9;" "\x20ac;" "\x1f600;" "\x0;" "\x7f;" "\x80;" "\x7ff;" "\x800;" "\xffff;"
        "\x10000;" "\x10ffff;"))
(pin "raw UTF-8 of 1 to 4 bytes mixed with escapes"
     (bytes "[\"A" '(#xC3 #xA9) '(#xE2 #x82 #xAC) '(#xF0 #x9F #x98 #x80) "~u00e9" "\"]")
     '#("A\xe9;\x20ac;\x1f600;~u00e9"))
(pin "the empty string, alone and in a container" (j "['',['',''],{'a':''}]")
     '#("" #("" "") (("a" . ""))))
(pin "the empty key" (j "{'':1}") '(("" . 1)))
(pin "the empty key and empty value" (j "{'':''}") '(("" . "")))
(pin "keys with escapes"
     (j "{'k~u00e9':1,'~uD83D~uDE00':2,'a~nb':3,'~u20ac':4,'':5,'~u0041':6}")
     '(("k\xe9;" . 1) ("\x1f600;" . 2) ("a\nb" . 3) ("\x20ac;" . 4) ("" . 5) ("A" . 6)))
(pin "a top-level string with an escape" (j "'a~tb'") "a\tb")

;; nesting
(pin "objects in arrays and arrays in objects, several levels"
     (j "[{'a':[1,{'b':[]}]},[[],{}],{'c':{'d':{'e':[true,[null]]}}}]")
     '#((("a" . #(1 (("b" . #()))))) #(#() ()) (("c" . (("d" . (("e" . #(#t #(null))))))))))
(pin "the same, under hashtable"
     (j "[{'a':[1,{'b':[]}]},[[],{}],{'c':{'d':{'e':[true,[null]]}}}]")
     '#((hashtable ("a" . #(1 (hashtable ("b" . #())))))
        #(#() (hashtable))
        (hashtable ("c" . (hashtable ("d" . (hashtable ("e" . #(#t #(null)))))))))
     'object-mode 'hashtable)
(pin "members after a closed container stay in place"
     (j "{'a':[1,2],'b':{'x':1},'c':3,'d':[4],'e':{}}")
     '(("a" . #(1 2)) ("b" . (("x" . 1))) ("c" . 3) ("d" . #(4)) ("e" . ())))
(pin "elements after a closed container stay in place"
     (j "[[1],{'a':2},3,[],{},4]")
     '#(#(1) (("a" . 2)) 3 #() () 4))

;; duplicate keys
(pin "alist: every duplicate kept, in document order"
     (j "{'a':1,'b':2,'a':3,'c':4,'a':5}")
     '(("a" . 1) ("b" . 2) ("a" . 3) ("c" . 4) ("a" . 5)))
(pin "alist: three duplicates of different kinds"
     (j "{'a':1,'a':[2],'a':'three'}")
     '(("a" . 1) ("a" . #(2)) ("a" . "three")))
(pin "hashtable: the last of three duplicates wins, at the first position"
     (j "{'d':1,'d':[2],'d':'three','m':0,'n':null}")
     '(hashtable ("d" . "three") ("m" . 0) ("n" . null))
     'object-mode 'hashtable)
(pin "hashtable: the last of three duplicates wins, in the middle"
     (j "{'a':0,'d':'one','b':1,'d':null,'c':2,'d':{'x':3},'e':4}")
     '(hashtable ("a" . 0) ("b" . 1) ("c" . 2) ("d" . (hashtable ("x" . 3))) ("e" . 4))
     'object-mode 'hashtable)
(pin "hashtable: the last of three duplicates wins, at the last position"
     (j "{'a':0,'b':1,'d':true,'d':{'x':3},'d':[4,5]}")
     '(hashtable ("a" . 0) ("b" . 1) ("d" . #(4 5)))
     'object-mode 'hashtable)
(pin "hashtable: a duplicate in a nested object"
     (j "[{'k':1,'k':2},{'k':3}]")
     '#((hashtable ("k" . 2)) (hashtable ("k" . 3)))
     'object-mode 'hashtable)
(pin "hashtable: the last duplicate is false, which is a value" (j "{'a':true,'a':false}")
     '(hashtable ("a" . #f)) 'object-mode 'hashtable)

;; the hashtable itself
(let ((h (build (j "{'a':1,'b':[2],'c':{'d':3},'a':4}") (opts 'object-mode 'hashtable))))
  (test-equal "hashtable: it is an R6RS hashtable, mutable"
    '(#t #t)
    (list (hashtable? h) (hashtable-mutable? h)))
  (test-equal "hashtable: the size is the number of distinct keys"
    3 (hashtable-size h))
  (test-equal "hashtable: a fresh string key finds each value"
    (list 4 '#(2) 'missing)
    (list (hashtable-ref h (list->string (list #\a)) 'missing)
          (hashtable-ref h (list->string (list #\b)) 'missing)
          (hashtable-ref h (list->string (list #\z)) 'missing)))
  (test-equal "hashtable: the nested object is a mutable hashtable too, found by a fresh key"
    '(#t #t 3)
    (let ((c (hashtable-ref h (list->string (list #\c)) #f)))
      (list (hashtable? c) (hashtable-mutable? c)
            (hashtable-ref c (list->string (list #\d)) 'missing))))
  (test-equal "hashtable: it can be changed; the duplicate's last value is the one kept"
    '(4 9)
    (begin (hashtable-set! h "n" 9)
           (list (hashtable-ref h "a" #f) (hashtable-ref h "n" #f)))))

(let ((v (build "[{},{},{\"a\":1}]" (opts 'object-mode 'hashtable))))
  (test-equal "hashtable: two {} in one document are two distinct hashtables"
    '(#t #t #f #t)
    (list (hashtable? (vector-ref v 0)) (hashtable? (vector-ref v 1))
          (eq? (vector-ref v 0) (vector-ref v 1))
          (and (= 0 (hashtable-size (vector-ref v 0))) (= 0 (hashtable-size (vector-ref v 1))))))
  (test-equal "hashtable: changing one {} leaves the other empty"
    '(1 0)
    (begin (hashtable-set! (vector-ref v 0) "x" 1)
           (list (hashtable-size (vector-ref v 0)) (hashtable-size (vector-ref v 1))))))

(test-equal "hashtable: a document with only duplicates has size 1; the empty one has size 0"
  '(1 0)
  (list (hashtable-size (build (j "{'a':1,'a':2,'a':3}") (opts 'object-mode 'hashtable)))
        (hashtable-size (build "{}" (opts 'object-mode 'hashtable)))))

;; keys that differ only in case stay distinct: string=? and string-hash
(define (ht-of text) (build text (opts 'object-mode 'hashtable)))
(define (fresh . cs) (list->string cs))

(pin "hashtable: keys that differ only in ASCII case are two keys"
     (j "{'a':1,'A':2}") '(hashtable ("A" . 2) ("a" . 1)) 'object-mode 'hashtable)
(pin "hashtable: keys that differ only in a non-ASCII letter's case are two keys"
     (j "{'~u00e9':1,'~u00C9':2}") '(hashtable ("\xc9;" . 2) ("\xe9;" . 1))
     'object-mode 'hashtable)
(test-equal "hashtable: case-different keys: the size and each lookup, by fresh keys"
  '(4 1 2 3 4 missing)
  (let ((h (ht-of (j "{'a':1,'A':2,'~u00e9':3,'~u00C9':4}"))))
    (list (hashtable-size h)
          (hashtable-ref h (fresh #\a) 'missing)
          (hashtable-ref h (fresh #\A) 'missing)
          (hashtable-ref h (fresh #\xe9) 'missing)
          (hashtable-ref h (fresh #\xc9) 'missing)
          (hashtable-ref h (fresh #\b) 'missing))))
(test-equal "hashtable: each object's hash function is string-hash and its equivalence string=?"
  '(#t #t #t #t)
  (let ((h (ht-of (j "{'a':1,'b':{'c':2}}"))))
    (let ((n (hashtable-ref h (fresh #\b) #f)))
      (list (eq? (hashtable-hash-function h) string-hash)
            (eq? (hashtable-equivalence-function h) string=?)
            (eq? (hashtable-hash-function n) string-hash)
            (eq? (hashtable-equivalence-function n) string=?)))))

(test-equal "alist mode builds no hashtable"
  '(#f #f)
  (let ((v (build (j "{'a':{'b':1}}") (opts))))
    (list (hashtable? v) (hashtable? (cdr (car v))))))

;; the null option
(test-equal "null: the symbol, at top level, in an array and as an object value"
  '(nil #(nil 1 nil) (("a" . nil) ("b" . #(nil))))
  (list (build "null" (opts 'null 'nil))
        (build "[null,1,null]" (opts 'null 'nil))
        (build (j "{'a':null,'b':[null]}") (opts 'null 'nil))))

(test-equal "null: the default is the symbol null"
  '(null #(null) (("a" . null)))
  (list (build "null" (opts)) (build "[null]" (opts)) (build (j "{'a':null}") (opts))))

(test-equal "null: a record, the one given, at top level, in an array and as an object value"
  '(#t #t #t #t #f #f)
  (let ((o (opts 'null nil-a)))
    (let ((top (build "null" o))
          (arr (build "[1,null,2]" o))
          (obj (build (j "{'a':null}") o)))
      (list (eq? top nil-a)
            (eq? (vector-ref arr 1) nil-a)
            (eq? (cdr (car obj)) nil-a)
            (and (= 1 (vector-ref arr 0)) (= 2 (vector-ref arr 2)))
            (eq? top nil-b)
            (eq? (vector-ref arr 1) nil-b)))))

(test-equal "null: a record under hashtable, found by a fresh key, and in a nested array"
  '(#t #t)
  (let ((h (build (j "{'a':null,'b':[null,[null]]}") (opts 'null nil-b 'object-mode 'hashtable))))
    (list (eq? (hashtable-ref h (list->string (list #\a)) #f) nil-b)
          (let ((b (hashtable-ref h (list->string (list #\b)) #f)))
            (and (eq? (vector-ref b 0) nil-b)
                 (eq? (vector-ref (vector-ref b 1) 0) nil-b))))))

(test-equal "null: the string \"null\" stays a string, and a key named null stays a key"
  '#("null" (("null" . "null")))
  (build (j "['null',{'null':'null'}]") (opts 'null 'nil)))

(test-equal "null: other literals are untouched under a record"
  '(#t #f 1)
  (vector->list (build "[true,false,1]" (opts 'null nil-a))))

;; --- 3. stack growth ------------------------------------------------------------

;; The stack has 64 slots and doubles. An open container takes a slot, an
;; array member one, an object member two. A push into a full stack grows
;; it: the peak slot count passing 64, 128 and 256 grows it. Documents are
;; made so their peak count is within 2 of each growth point, either side.

(define (join strs sep)
  (if (null? strs)
      ""
      (let loop ((rest (cdr strs)) (acc (car strs)))
        (if (null? rest) acc (loop (cdr rest) (string-append acc sep (car rest)))))))

(define (num->s n) (number->string n))

;; An inner container of N members, its text and its value.
(define (inner-text kind n)
  (if (eq? kind 'array)
      (string-append "[" (join (map num->s (range 0 n)) ",") "]")
      (string-append "{" (join (map (lambda (i) (string-append "\"k" (num->s i) "\":" (num->s i)))
                                    (range 0 n))
                               ",")
                     "}")))

(define (inner-value kind n)
  (if (eq? kind 'array)
      (list->vector (range 0 n))
      (map (lambda (i) (cons (string-append "k" (num->s i)) i)) (range 0 n))))

;; A context wraps the inner container: its pending members come before,
;; one member comes after. SLOTS is how many slots the context takes up
;; before the inner container's own mark.
;; (name slots wrap-text wrap-value)
(define (array-ctx k)
  (list (string-append "array+" (num->s k)) (+ 1 k)
        (lambda (t) (string-append "[" (join (append (map (lambda (i) (num->s (+ 100 i))) (range 0 k))
                                                     (list t "\"after\""))
                                             ",")
                                   "]"))
        (lambda (v) (list->vector (append (map (lambda (i) (+ 100 i)) (range 0 k))
                                          (list v "after"))))))

(define (object-ctx k)
  (list (string-append "object+" (num->s k)) (+ 2 (* 2 k))
        (lambda (t) (string-append
                     "{"
                     (join (append (map (lambda (i) (string-append "\"p" (num->s i) "\":" (num->s (+ 100 i))))
                                        (range 0 k))
                                   (list (string-append "\"inner\":" t) "\"z\":\"after\""))
                           ",")
                     "}"))
        (lambda (v) (append (map (lambda (i) (cons (string-append "p" (num->s i)) (+ 100 i)))
                                 (range 0 k))
                            (list (cons "inner" v) (cons "z" "after"))))))

(define top-ctx (list "top" 0 (lambda (t) t) (lambda (v) v)))

;; Composes contexts: OUTER wraps what INNER wraps.
(define (compose outer inner)
  (list (string-append (car outer) "/" (car inner))
        (+ (cadr outer) (cadr inner))
        (lambda (t) ((caddr outer) ((caddr inner) t)))
        (lambda (v) ((cadddr outer) ((cadddr inner) v)))))

(define contexts
  (list top-ctx
        (array-ctx 0) (array-ctx 1) (array-ctx 2) (array-ctx 3)
        (object-ctx 0) (object-ctx 1) (object-ctx 2)
        (compose (array-ctx 1) (array-ctx 2))
        (compose (object-ctx 1) (array-ctx 1))
        (compose (array-ctx 2) (object-ctx 1))
        (compose (object-ctx 2) (object-ctx 0))
        (compose (array-ctx 3) (compose (object-ctx 1) (array-ctx 0)))))

(define growth-points '(64 128 256))

;; The cases: (name text value kind peak), for each context and kind and each
;; member count whose peak slot count is within 2 of a growth point.
(define (growth-cases)
  (apply append
         (map (lambda (ctx)
                (apply append
                       (map (lambda (kind)
                              (let ((per (if (eq? kind 'array) 1 2)))
                                (filter
                                 values
                                 (map (lambda (n)
                                        (let ((peak (+ (cadr ctx) 1 (* per n))))
                                          (and (exists (lambda (p) (<= (- p 2) peak (+ p 2)))
                                                       growth-points)
                                               (list (string-append (car ctx) " " (symbol->string kind)
                                                                    " n=" (num->s n)
                                                                    " peak=" (num->s peak))
                                                     ((caddr ctx) (inner-text kind n))
                                                     ((cadddr ctx) (inner-value kind n))
                                                     kind
                                                     peak))))
                                      (range 0 270)))))
                            '(array object))))
              contexts)))

(define cases (growth-cases))

;; Each peak from 62 to 66, 126 to 130 and 254 to 258, as an array and as an
;; object.
(test-equal "growth: the cases cover every peak from 62 to 66, 126 to 130 and 254 to 258, as arrays and as objects"
  '()
  (filter values
          (apply append
                 (map (lambda (kind)
                        (map (lambda (peak)
                               (and (not (exists (lambda (c) (and (eq? (cadddr c) kind)
                                                                  (= (car (cddddr c)) peak)))
                                                 cases))
                                    (list kind peak)))
                             (append (range 62 67) (range 126 131) (range 254 259))))
                      '(array object)))))

(test-equal "growth: each document builds its value, whole"
  '()
  (filter values
          (map (lambda (c)
                 (let ((got (build (cadr c) (opts))))
                   (and (not (equal? got (caddr c))) (car c))))
               cases)))

(test-equal "growth: ... in chunks of 5 bytes"
  '()
  (filter values
          (map (lambda (c)
                 (let ((b (make-json-builder (opts))))
                   (for-each (lambda (s) (json-builder-feed! b (car s) (cadr s) (caddr s)))
                             (chunk-schedule (u8 (cadr c)) 5))
                   (json-builder-finish! b)
                   (and (not (equal? (json-builder-value b) (caddr c))) (car c))))
               cases)))

;; Under hashtable, the same documents: objects are hashtables, sorted.
(define (as-ht v)
  (as-hashtables (canonical v)))

(test-equal "growth: ... and under hashtable"
  '()
  (filter values
          (map (lambda (c)
                 (let ((got (canonical (build (cadr c) (opts 'object-mode 'hashtable)))))
                   (and (not (equal? got (as-ht (caddr c)))) (car c))))
               cases)))

;; A tall stack: a long array of arrays and objects, each holding members,
;; the stack growing past 1000 slots with many containers closed on the way.
(define (many n)
  (list (string-append "[" (join (map (lambda (i) (string-append "[" (num->s i) ",{\"k\":" (num->s i) "}]"))
                                      (range 0 n)) ",") "]")
        (list->vector (map (lambda (i) (vector i (list (cons "k" i)))) (range 0 n)))))

(test-equal "growth: 700 members, each a closed array and object"
  (cadr (many 700))
  (build (car (many 700)) (opts)))

(test-equal "growth: a deep pending stack: 300 nested arrays with 3 members each before the next"
  #t
  (let* ((d 300)
         (text (string-append (apply string-append (map (lambda (i) (string-append "[" (num->s i) ",true,")) (range 0 d)))
                              "[]"
                              (apply string-append (map (lambda (i) "]") (range 0 d)))))
         (want (let loop ((i (- d 1)) (v (vector)))
                 (if (< i 0) v (loop (- i 1) (vector i #t v))))))
    (equal? (build text (opts)) want)))

;; --- 4. depth -----------------------------------------------------------------------

;; level-kind : Symbol Integer -> (U 'array 'object)
(define (level-kind shape i)
  (case shape
    ((array) 'array)
    ((object) 'object)
    (else (if (odd? i) 'array 'object))))

(define (nest-text shape d)
  (let loop ((i 1) (open '()) (close '()))
    (if (> i d)
        (let ((inner (if (eq? (level-kind shape d) 'array) "[]" "{}")))
          ;; The innermost level is empty: drop its opener and closer.
          (string-append (apply string-append (reverse (cdr open)))
                         inner
                         (apply string-append (cdr close))))
        (loop (+ i 1)
              (cons (if (eq? (level-kind shape i) 'array) "[" "{\"a\":") open)
              (cons (if (eq? (level-kind shape i) 'array) "]" "}") close)))))

(define (nest-value shape d)
  (let loop ((i (- d 1)) (v (if (eq? (level-kind shape d) 'array) (vector) '())))
    (if (< i 1)
        v
        (loop (- i 1)
              (if (eq? (level-kind shape i) 'array)
                  (vector v)
                  (list (cons "a" v)))))))

(define (parser-error text options)
  (let ((entries (run-parser (whole-schedule (->bv text)) options)))
    (let loop ((es entries))
      (cond ((null? es) 'none)
            ((and (pair? (car es)) (memq (caar es) '(feed finish)) (eq? (cadar es) 'error))
             (list (caddar es) (car (cdddar es))))
            (else (loop (cdr es)))))))

;; builder-error : text options -> (U 'none (Code Offset value-raises))
(define (builder-error text options)
  (let ((b (make-json-builder options)))
    (let ((r1 (json-builder-feed! b (->bv text))))
      (let ((r2 (json-builder-finish! b)))
        (if (eq? (json-result-status r2) 'error)
            (list (json-result-code r2) (json-result-offset r2)
                  (raises (lambda () (json-builder-value b))))
            'none)))))

(for-each
 (lambda (shape)
   (for-each
    (lambda (d)
      (let ((text (nest-text shape d)))
        (test-equal (string-append "depth " (num->s d) ": nested " (symbol->string shape)
                                   " builds its value")
          (nest-value shape d)
          (build text (opts)))))
    '(1 8 64))
   (for-each
    (lambda (d)
      (let ((text (nest-text shape d)))
        (test-equal (string-append "depth " (num->s d) ": nested " (symbol->string shape)
                                   " at the default limit")
          #t
          (equal? (nest-value shape d) (build text (opts))))))
    '(512)))
 '(array object alternating))

(for-each
 (lambda (shape)
   (test-equal (string-append "depth 512 under hashtable: nested " (symbol->string shape))
     #t
     (equal? (as-ht (nest-value shape 512))
             (canonical (build (nest-text shape 512) (opts 'object-mode 'hashtable)))))
   (for-each
    (lambda (d)
      (test-equal (string-append "depth " (num->s d) " under depth-limit 65535: nested "
                                 (symbol->string shape))
        #t
        (equal? (nest-value shape d)
                (build (nest-text shape d) (opts 'depth-limit 65535)))))
    '(65534 65535)))
 '(array object alternating))

(for-each
 (lambda (shape)
   (for-each
    (lambda (spec)
      (let* ((limit (car spec)) (d (cdr spec))
             (o (opts 'depth-limit limit))
             (text (nest-text shape d))
             (want (parser-error text o)))
        (test-equal (string-append "one past depth " (num->s limit) ": nested " (symbol->string shape)
                                   " is nesting-too-deep, as the parser says it")
          (list (list 'nesting-too-deep (cadr want) 'raised) 'nesting-too-deep)
          (list (builder-error text o) (car want)))))
    '((512 . 513) (65535 . 65536) (64 . 65) (8 . 9) (0 . 1))))
 '(array object alternating))

(test-equal "one past the default limit with no options given: the same error, and no value"
  (list 'nesting-too-deep (cadr (parser-error (nest-text 'array 513) (opts))) 'raised)
  (let ((b (make-json-builder)))
    (json-builder-feed! b (u8 (nest-text 'array 513)))
    (let ((r (json-builder-finish! b)))
      (list (json-result-code r) (json-result-offset r)
            (raises (lambda () (json-builder-value b)))))))

;; --- 5. stops --------------------------------------------------------------------------

;; (name options number-text): a number that stops the parse, under options
;; of the suite's own base.
(define stop-kinds
  (list (list 'number-too-long (opts 'digit-limit 5 'null 'nil 'object-mode 'hashtable) "123456")
        (list 'number-too-long (opts 'digit-limit 5 'number-mode 'exact 'null nil-a) "0.12345e1")
        (list 'number-out-of-range (opts 'null 'nil 'object-mode 'hashtable) "1e400")
        (list 'number-out-of-range (opts 'number-mode 'exact 'null nil-a) "1e1001")
        (list 'number-out-of-range (opts 'null 'nil) "-1e400")))

(define positions
  (list (cons "top level" (lambda (n) n))
        (cons "top level before a space" (lambda (n) (string-append n " ")))
        (cons "an array member" (lambda (n) (string-append "[1," n ",2]")))
        (cons "an array member, last" (lambda (n) (string-append "[1," n "]")))
        (cons "an object value" (lambda (n) (string-append "{\"a\":1,\"b\":" n ",\"c\":2}")))
        (cons "five levels deep"
              (lambda (n) (string-append "[{\"a\":[{\"a\":[1," n "]}]}]")))))

;; The error among the results of a run with the two feeds of bv split at i
;; (or 0 for a single feed), and whether the value then raises.
(define (stop-run text options i)
  (let* ((bv (u8 text)) (len (bytevector-length bv))
         (b (make-json-builder options))
         (feeds (if (= i 0) (list (list bv 0 len)) (list (list bv 0 i) (list bv i len))))
         (results
          (let loop ((fs feeds) (acc '()))
            (if (null? fs)
                (reverse (cons (json-builder-finish! b) acc))
                (let ((r (json-builder-feed! b (car (car fs)) (cadr (car fs)) (caddr (car fs)))))
                  (if (eq? (json-result-status r) 'need-input)
                      (loop (cdr fs) (cons r acc))
                      (reverse (cons r acc))))))))
    (let ((last (car (reverse results))))
      (list (json-result-status last) (json-result-code last) (json-result-offset last)
            (raises (lambda () (json-builder-value b)))))))

(define (split-points text) (range 1 (bytevector-length (u8 text))))

(for-each
 (lambda (kind)
   (for-each
    (lambda (pos)
      (let* ((text ((cdr pos) (caddr kind)))
             (whole (stop-run text (cadr kind) 0)))
        (test-equal (string-append (symbol->string (car kind)) " " (caddr kind) " at " (car pos)
                                   ": the code, no value, and the same under every split")
          (list (list 'error (car kind) 'raised) '())
          (list (list (car whole) (cadr whole) (cadddr whole))
                (filter values
                        (map (lambda (i)
                               (let ((got (stop-run text (cadr kind) i)))
                                 (and (not (equal? got whole)) (list i got whole))))
                             (split-points text)))))))
    positions))
 stop-kinds)

;; The offsets themselves, worked out by counting bytes: a number's stop
;; lands at the index of the byte that ends it, or at the input's length if
;; the input ends there.
(test-equal "stop offsets: the stop lands at the index of the byte that ends the number"
  '(5 8 8 10 16 5 8)
  (list (caddr (stop-run "1e400 " (opts) 0))
        (caddr (stop-run "[1,1e400,2]" (opts) 0))
        (caddr (stop-run "[1,1e400]" (opts) 0))
        (caddr (stop-run "{\"a\":1e400}" (opts) 0))
        (caddr (stop-run "{\"a\":1,\"b\":1e400,\"c\":2}" (opts) 0))
        (caddr (stop-run "1e400" (opts) 0))
        (caddr (stop-run "[1,1e400]" (opts 'null 'nil) 0))))

(test-equal "a stop ends the parse, and the stop is not taken for a value"
  (list 'raised 'error 'number-out-of-range)
  (let ((b (make-json-builder (opts 'null nil-a))))
    (let* ((r (json-builder-feed! b (u8 "[1,1e400,2]")))
           (v (raises (lambda () (json-builder-value b)))))
      (list v (json-result-status r) (json-result-code r)))))

;; --- 6. chunking invariance ----------------------------------------------------------------

(define all-kinds-text
  (u8 (j "{'s':'a~u00e9~uD83D~uDE00','n':[1,-0,1.5,1e2,-0.0],'t':true,'f':false,'z':null,'o':{'d':1,'d':2,'e':[[],{}]},'a':[[1,[2,[3]]],{'k':[null]}],'':''}")))

(define all-kinds-flonum
  '(("s" . "a\xe9;\x1f600;")
    ("n" . #(1 0 1.5 100.0 -0.0))
    ("t" . #t)
    ("f" . #f)
    ("z" . nil)
    ("o" . (("d" . 1) ("d" . 2) ("e" . #(#() ()))))
    ("a" . #(#(1 #(2 #(3))) (("k" . #(nil)))))
    ("" . "")))

(define all-kinds-text-ht
  (list 'hashtable
        '("" . "")
        '("a" . #(#((json-number "1") #((json-number "2") #((json-number "3"))))
                  (hashtable ("k" . #(nested-null)))))
        '("f" . #f)
        '("n" . #((json-number "1") (json-number "-0") (json-number "1.5")
                  (json-number "1e2") (json-number "-0.0")))
        '("o" . (hashtable ("d" . (json-number "2")) ("e" . #(#() (hashtable)))))
        '("s" . "a\xe9;\x1f600;")
        '("t" . #t)
        '("z" . nested-null)))

(define (split-in-two bv)
  (let ((len (bytevector-length bv)))
    (map (lambda (i) (list (list bv 0 i) (list bv i len))) (range 0 (+ len 1)))))

(define (split-in-three bv)
  (let ((len (bytevector-length bv)))
    (apply append
           (map (lambda (i)
                  (map (lambda (k) (list (list bv 0 i) (list bv i k) (list bv k len)))
                       (range i (+ len 1))))
                (range 0 (+ len 1))))))

(define (value-under schedule options)
  (let ((b (make-json-builder options)))
    (for-each (lambda (f) (json-builder-feed! b (car f) (cadr f) (caddr f))) schedule)
    (let ((r (json-builder-finish! b)))
      (if (eq? (json-result-status r) 'finished)
          (canonical (json-builder-value b))
          (vector 'failed (json-result-code r) (json-result-offset r))))))

;; The hashtable form's null is the suite's record; put it in place.
(define (with-record v)
  (cond ((eq? v 'nested-null) nil-a)
        ((vector? v) (vector-map with-record v))
        ((pair? v) (cons (with-record (car v)) (with-record (cdr v))))
        (else v)))

(define all-kinds-text-ht-want (with-record all-kinds-text-ht))

(test-equal "invariance: whole, the document builds the value (alist, flonum, nil)"
  all-kinds-flonum
  (value-under (whole-schedule all-kinds-text) (opts 'null 'nil)))

(test-equal "invariance: whole, the document builds the value (hashtable, text, record)"
  all-kinds-text-ht-want
  (value-under (whole-schedule all-kinds-text)
               (opts 'object-mode 'hashtable 'number-mode 'text 'null nil-a)))

(test-equal "invariance: every split into two feeds builds the same value (alist)"
  '()
  (filter values
          (map (lambda (s) (let ((v (value-under s (opts 'null 'nil))))
                             (and (not (equal? v all-kinds-flonum)) (list (cadr (car (cdr s))) v))))
               (split-in-two all-kinds-text))))

(test-equal "invariance: every split into three feeds builds the same value (alist)"
  '()
  (filter values
          (map (lambda (s) (let ((v (value-under s (opts 'null 'nil))))
                             (and (not (equal? v all-kinds-flonum)) (list (cadr (car (cdr s))) v))))
               (split-in-three all-kinds-text))))

(test-equal "invariance: every split into two feeds builds the same value (hashtable, text, record)"
  '()
  (filter values
          (map (lambda (s) (let ((v (value-under s (opts 'object-mode 'hashtable 'number-mode 'text 'null nil-a))))
                             (and (not (equal? v all-kinds-text-ht-want)) (list (cadr (car (cdr s))) v))))
               (split-in-two all-kinds-text))))

(test-equal "invariance: every split into three feeds builds the same value (hashtable, text, record)"
  '()
  (filter values
          (map (lambda (s) (let ((v (value-under s (opts 'object-mode 'hashtable 'number-mode 'text 'null nil-a))))
                             (and (not (equal? v all-kinds-text-ht-want)) (list (cadr (car (cdr s))) v))))
               (split-in-three all-kinds-text))))

(test-equal "invariance: the document is 140 bytes or more, so the splits are many"
  #t
  (>= (bytevector-length all-kinds-text) 140))

(test-end "tree")

(exit (suite-exit-status runner))
