#!r6rs
;;; tests/test-sequence-property.sps: (jsonparse sequence)'s reader checked
;;; against an oracle written here, on generated and mutated streams, under
;;; every way of chunking them (ADR-0020, ADR-0014, ADR-0012).
;;;
;;; Usage: test-sequence-property.sps [SEED [MULTIPLIER]]
;;;
;;; THE ORACLE (ORACLE-LINES, ORACLE-SEQ below) is worked out from ADR-0020
;;; and ADR-0014 and shares no framing code with the library. It splits the
;;; whole stream with plain loops: at every newline for lines, at every RS
;;; for seq. It reads each part with a new builder from (jsonparse tree),
;;; fed the part whole. So it checks the FRAMING (where a record starts and
;;; ends, its number, its offset, blank lines, truncation, what follows a
;;; bad record) and NOT THE PARSING: a part's value or error is the
;;; builder's, for the oracle and the library alike. The parser has its own
;;; suites.
;;;
;;; The log. A run of a reader is a list of events: (value V RECORD) for
;;; each value, (skip CODE RECORD OFFSET) for each bad record skipped, and
;;; the end, (finished OFFSET RECORD) or (error CODE OFFSET RECORD). V is
;;; (canonical ...) of the value. RECORD is json-reader-record, read inside
;;; the procedure for a value, and after the end for the end; finished
;;; answers one past the last record. The tests assert the whole log.
;;;
;;; Properties:
;;; 1. Generated streams against the oracle, under lines, lines with
;;;    blank-lines skip, and seq, each with and without ON-SKIP (seq always
;;;    with). 0 to 20 records: values written by put-json-record, blank
;;;    lines, runs of RS, whitespace around values, CRLF, bad records,
;;;    strings holding \n, \r and U+001E escaped, U+FEFF first and non-ASCII
;;;    characters, and top-level numbers and literals with and without
;;;    whitespace after them. Some streams are read in the other format.
;;; 2. Mutated streams against the oracle: valid streams with 1 to 3 edits
;;;    (insert, delete, replace 1 to 4 bytes) drawn from a pool weighted
;;;    towards \n, \r, RS, space, quotes, brackets, digits, - and bytes of
;;;    128 and above.
;;; 3. Chunking. Every stream of 1 and 2 is also read under three random
;;;    schedules of chunks (fed as ranges of a larger bytevector), and, when
;;;    it is 64 bytes or less, byte by byte and under every split in two. The
;;;    log must equal the oracle's, so equal to one feed's. Counted: how
;;;    many runs used more than one feed, and how many split a stream next
;;;    to a separator.
;;; 4. Round trips under six option sets: lists of generated values written
;;;    by put-json-record in each format and read back.
;;; 5. values against the builder: every JSONTestSuite y_ file read as a
;;;    values stream gives one value, as a builder reads it from the file,
;;;    whole and byte by byte; two files joined by a space give two.
;;; 6. A tally of what the generated streams held, asserted, so the
;;;    generator can't silently stop making blank lines, truncations, bad
;;;    records or RS runs; a failing case is shrunk and printed.
;;;
;;; Octet strings: a stream is built as a string whose characters are bytes
;;; (codes 0 to 255), so a failing case prints as data. No non-ASCII
;;; character is written in this file.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing property)
        (jsonparse-testing tree)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse tree)
        (jsonparse writer)
        (jsonparse sequence))

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

(define default-seed 20261107)
(define parsed (parse-property-arguments (cdr (command-line)) default-seed))
(unless parsed
  (put-string (current-error-port)
              "usage: test-sequence-property.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))
(define run (make-property-run "sequence-property" (car parsed) (cadr parsed)))
(define multiplier (cadr parsed))
(define case-groups 400)

;; --- small helpers --------------------------------------------------------------

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (opts . args) (apply make-json-options args))
(define (no-shrinks k) '())
(define RS 30)
(define (list-head xs k) (if (or (= k 0) (null? xs)) '() (cons (car xs) (list-head (cdr xs) (- k 1)))))
(define (tally-count tally k)
  (let ((p (assq k (tally-counts tally)))) (if p (cdr p) 0)))
(define (without-nth xs i)
  (if (= i 0) (cdr xs) (cons (car xs) (without-nth (cdr xs) (- i 1)))))

;; Octet strings and bytevectors.
(define (os->bv s)
  (let* ((n (string-length s)) (bv (make-bytevector n)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set! bv i (char->integer (string-ref s i)))
        (loop (+ i 1))))
    bv))

(define (bv->os bv)
  (list->string (map integer->char (bytevector->u8-list bv))))

(define (octets . bytes) (list->string (map integer->char bytes)))
(define RS-os (octets RS))

(define (concat-strings xs) (apply string-append xs))

(define (sub-bv bv from to)
  (let ((r (make-bytevector (- to from))))
    (bytevector-copy! bv from r 0 (- to from))
    r))

(test-begin "sequence-property")

;; --- the oracle -----------------------------------------------------------------------

(define (ws-byte? b) (or (= b 32) (= b 9) (= b 10) (= b 13)))
(define (scalar-first? b)
  (or (and (>= b 48) (<= b 57)) (= b 45) (= b 116) (= b 102) (= b 110)))

;; builder-read : Bytevector Nat Nat json-options -> (U (value V) (bad CODE OFFSET))
;; A new builder fed the bytes from S below E whole. OFFSET is the builder's,
;; counted from S.
(define (builder-read bv s e o)
  (let* ((b (make-json-builder o))
         (r (json-builder-feed! b (sub-bv bv s e)))
         (r (if (eq? (json-result-status r) 'error) r (json-builder-finish! b))))
    (if (eq? (json-result-status r) 'finished)
        (list 'value (canonical (json-builder-value b)))
        (list 'bad (json-result-code r) (json-result-offset r)))))

;; The bytes from S below E are all space, tab or CR.
(define (blank-part? bv s e)
  (let loop ((i s))
    (cond ((= i e) #t)
          ((memv (bytevector-u8-ref bv i) '(32 9 13)) (loop (+ i 1)))
          (else #f))))

;; The parts of BV: (START . END) pairs, in order, from a plain scan.
;; Splits at every SEP; the last part counts only if it is not empty.
;; With LEAD? the part before the first SEP counts too when not empty, and
;; every part counts only if not empty (the rule for seq).
(define (split-parts bv sep)
  (let ((n (bytevector-length bv)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (if (< start n) (cons (cons start n) acc) acc)))
            ((= (bytevector-u8-ref bv i) sep) (loop (+ i 1) (+ i 1) (cons (cons start i) acc)))
            (else (loop (+ i 1) start acc))))))

;; A record's outcome in the log: events for it, and whether the stream ends.
;; lines-records : parts as (S . E); seq-records the same, empty parts gone.
(define (oracle-log records classify on-skip? n)
  ;; records: list of (S . E); classify: (S E) -> (U #f (value V) (bad CODE OFFSET))
  ;; #f means the record makes no event.
  (let loop ((rs records) (rec 1) (log '()))
    (if (null? rs)
        (reverse (cons (list 'finished n rec) log))
        (let ((c (classify (caar rs) (cdar rs))))
          (cond
            ((not c) (loop (cdr rs) (+ rec 1) log))
            ((eq? (car c) 'value)
             (loop (cdr rs) (+ rec 1) (cons (list 'value (cadr c) rec) log)))
            (on-skip?
             (loop (cdr rs) (+ rec 1) (cons (list 'skip (cadr c) rec (caddr c)) log)))
            (else (reverse (cons (list 'error (cadr c) (caddr c) rec) log))))))))

(define (oracle-lines bv base-o skip-blank? on-skip?)
  (let ((n (bytevector-length bv)))
    (oracle-log
     (split-parts bv 10)
     (lambda (s e)
       (if (blank-part? bv s e)
           (if skip-blank? #f (list 'bad 'blank-line e))
           (let ((r (builder-read bv s e base-o)))
             (if (eq? (car r) 'value) r (list 'bad (cadr r) (+ s (caddr r)))))))
     on-skip? n)))

(define (oracle-seq bv base-o)
  (let* ((n (bytevector-length bv))
         (parts (split-parts bv RS))
         ;; split-parts' parts: the one before the first RS, then one after
         ;; each RS. The first starts at 0 only when no RS comes first.
         (parts (filter (lambda (p) (< (car p) (cdr p))) parts)))
    (oracle-log
     parts
     (lambda (s e)
       (cond
         ((= s 0) (list 'bad 'unexpected-byte 0))
         (else
          (let ((r (builder-read bv s e base-o)))
            (cond
              ((eq? (car r) 'bad) (list 'bad (cadr r) (+ s (caddr r))))
              ((let first ((i s))
                 (cond ((= i e) #f)
                       ((ws-byte? (bytevector-u8-ref bv i)) (first (+ i 1)))
                       (else (and (scalar-first? (bytevector-u8-ref bv i))
                                  (not (ws-byte? (bytevector-u8-ref bv (- e 1))))))))
               (list 'bad 'truncated e))
              (else r))))))
     #t n)))

;; --- configurations ------------------------------------------------------------------------

;; (NAME STREAM BLANK-SKIP? ON-SKIP?)
(define configs
  (vector '(lines-error lines #f #f)
          '(lines-error-skipping lines #f #t)
          '(lines-blank-skip lines #t #f)
          '(lines-blank-skip-skipping lines #t #t)
          '(seq seq #f #t)))

(define bases
  (vector (list 'null 'nil 'depth-limit 2 'object-mode 'hashtable 'number-mode 'exact 'digit-limit 6)
          (list 'number-mode 'text 'null 'zip 'depth-limit 3)))

(define (cfg-ref i) (vector-ref configs i))
(define (cfg-stream i) (cadr (cfg-ref i)))
(define (cfg-blank-skip? i) (caddr (cfg-ref i)))
(define (cfg-on-skip? i) (cadddr (cfg-ref i)))

(define (reader-options cfg-i base-i)
  (apply make-json-options 'stream (cfg-stream cfg-i)
         (append (if (cfg-blank-skip? cfg-i) '(blank-lines skip) '())
                 (vector-ref bases base-i))))

(define (base-options base-i) (apply make-json-options (vector-ref bases base-i)))

(define (oracle cfg-i base-i bv)
  (let ((bo (base-options base-i)))
    (if (eq? (cfg-stream cfg-i) 'seq)
        (oracle-seq bv bo)
        (oracle-lines bv bo (cfg-blank-skip? cfg-i) (cfg-on-skip? cfg-i)))))

;; --- running the reader ------------------------------------------------------------------------

;; chunks : Nat (Listof Nat) -> (Listof (Pair Nat Nat))
;; The ranges between the cuts, which are in order within 0..N.
(define (chunks n cuts)
  (let loop ((from 0) (cuts cuts) (acc '()))
    (if (null? cuts)
        (reverse (cons (cons from n) acc))
        (loop (car cuts) (cdr cuts) (cons (cons from (car cuts)) acc)))))

;; The range fed from a larger bytevector with other bytes around it.
(define (feed-range! r bv a b)
  (let* ((pre (mod a 3)) (post 1)
         (padded (make-bytevector (+ pre (- b a) post) 30)))
    (let loop ((i 0))
      (when (< i pre) (bytevector-u8-set! padded i (if (even? i) 10 30)) (loop (+ i 1))))
    (bytevector-u8-set! padded (+ pre (- b a)) 10)
    (bytevector-copy! bv a padded pre (- b a))
    (json-reader-feed! r padded pre (+ pre (- b a)))))

(define (result-key res)
  (list (json-result-status res) (json-result-code res) (json-result-offset res)))

;; run-reader : json-options Boolean Bytevector (Listof Nat) -> Log
;; Feeds the chunks, then finishes. Once an error ends the stream, the later
;; chunks and finish are fed too: the answer must stay the same.
(define (run-reader o on-skip? bv cuts)
  (guard (e (#t (list (list 'raised (describe e)))))
    (let* ((log '()) (r #f)
           (push! (lambda (x) (set! log (cons x log))))
           (on-value (lambda (v) (push! (list 'value (canonical v) (json-reader-record r)))))
           (on-skip (and on-skip?
                         (lambda (code rec off)
                           (push! (list 'skip code rec off))
                           (unless (= rec (json-reader-record r))
                             (push! (list 'record-inside-on-skip-is (json-reader-record r)))))))
           (n (bytevector-length bv)))
      (set! r (make-json-reader on-value on-skip o))
      (let ((first-end #f))
        (for-each
         (lambda (c)
           (let ((res (feed-range! r bv (car c) (cdr c))))
             (cond
               ((not first-end)
                (unless (eq? (json-result-status res) 'need-input)
                  (set! first-end (list (result-key res) (json-reader-record r)))))
               ((not (equal? first-end (list (result-key res) (json-reader-record r))))
                (push! (list 'not-sticky (result-key res)))))))
         (chunks n cuts))
        (let* ((fin (json-reader-finish! r))
               (rec (json-reader-record r)))
          (when (and first-end (not (equal? first-end (list (result-key fin) rec))))
            (push! (list 'not-sticky-at-finish (result-key fin))))
          (case (json-result-status fin)
            ((finished) (push! (list 'finished (json-result-offset fin) rec)))
            ((error) (push! (list 'error (json-result-code fin) (json-result-offset fin) rec)))
            (else (push! (list 'unexpected-status (json-result-status fin)))))))
      (reverse log))))

;; --- generators -------------------------------------------------------------------------------------

(define (g-char-range lo hi)
  (lambda (s) (draw* s ((c (g-range lo hi))) (cons (integer->char c) s))))

(define g-text-char
  (g-choose
   (list (cons 10 (g-char-range 32 126))
         (cons 4 (g-pick (list #\newline #\return (integer->char 30) #\tab)))
         (cons 2 (g-pick (list #\" #\\ #\space)))
         (cons 3 (g-pick (list #\xFEFF #\xE9 #\x20AC #\x1F600 #\x80 #\x7FF #\x2028))))))

(define g-str
  (lambda (s)
    (draw* s ((n (g-pick '(0 0 1 2 3 5 9))) (cs (g-list n g-text-char)) (feff (g-chance 1 6)))
      (cons (string-append (if feff "\xFEFF;" "") (list->string cs)) s))))

(define int-pool '(0 1 -1 7 42 -300 65536 1234567 12345678901234567890))
(define flonum-pool '(1.5 -0.25 0.5 2.0 1024.0 3.25))

(define g-int-num
  (g-choose (list (cons 3 (g-pick int-pool)) (cons 3 (g-range -100 100)))))

(define g-any-num
  (g-choose (list (cons 6 g-int-num) (cons 3 (g-pick flonum-pool)))))

(define (unique-keys ms)
  (let loop ((ms ms) (seen '()) (kept '()))
    (cond ((null? ms) (reverse kept))
          ((member (caar ms) seen) (loop (cdr ms) seen kept))
          (else (loop (cdr ms) (cons (caar ms) seen) (cons (car ms) kept))))))

;; A value: strings, numbers, booleans, 'NULLMARK, vectors, alists.
(define (g-val gnum d)
  (define (g-scalar)
    (g-choose (list (cons 4 g-str) (cons 6 gnum) (cons 1 (g-const #t)) (cons 1 (g-const #f))
                    (cons 2 (g-const 'NULLMARK)))))
  (if (= d 0)
      (g-scalar)
      (g-choose
       (list (cons 6 (g-scalar))
             (cons 3 (lambda (s)
                       (draw* s ((n (g-pick '(0 1 2 3))) (xs (g-list n (g-val gnum (- d 1)))))
                         (cons (list->vector xs) s))))
             (cons 3 (lambda (s)
                       (draw* s ((n (g-pick '(0 1 2 3)))
                                 (ms (g-list n (lambda (s) (draw* s ((k g-str) (v (g-val gnum (- d 1))))
                                                              (cons (cons k v) s))))))
                         (cons (unique-keys ms) s))))))))

(define (subst-null v null)
  (cond ((eq? v 'NULLMARK) null)
        ((vector? v) (vector-map (lambda (x) (subst-null x null)) v))
        ((pair? v) (map (lambda (m) (cons (car m) (subst-null (cdr m) null))) v))
        (else v)))

;; --- items: framed pieces of a stream, as octet strings ---------------------------------

(define (put->os proc) (bv->os (call-with-bytevector-output-port proc)))
(define (rec-os fmt indent v)
  (put->os (lambda (p) (put-json-record p (subst-null v 'null) (opts 'stream fmt 'indent indent)))))
(define (bare-os v) (put->os (lambda (p) (put-json p (subst-null v 'null)))))

(define scalar-pool '("0" "-0" "12" "-7" "3.25" "1e5" "2E-3" "true" "false" "null" "1234567"))
(define bad-pool
  (list "{" "]" "tru" "@" "\"abc" "[1,]" "1 2" "nul" "01" "-" "1." "\"\\x\"" "[[[1]]]" "{\"a\":}"
        (octets 239 191) (octets 239 187 191 49) (octets 34 97 10 98 34) (octets 34 97 30 98 34)
        "[1] x" "-]" "\"\\u12\""))
(define pads '("" "" " " "\t" "  " "\r"))
(define blank-lines-pool '("\n" "\n" " \n" "\t\n" "\r\n" "  \r\n" "\r\n"))

(define (g-rs-run) (g-pick (list RS-os RS-os RS-os RS-os RS-os (string-append RS-os RS-os)
                                 (string-append RS-os RS-os RS-os RS-os))))

;; g-item : Symbol Boolean -> Gen String
;; One framed item of a stream in FMT, lines or seq. CLEAN? leaves out bad
;; records and blank ones.
(define (g-item fmt clean?)
  (define g-value (g-val g-any-num 3))
  (define (kinds . weighted)
    (g-choose (map (lambda (p) (cons (car p) (cdr p))) weighted)))
  (define g-pad (g-pick pads))
  (define g-term-lines (g-pick '("\n" "\n" "\n" "\r\n" " \n")))
  (define g-term-seq (g-pick '("" "" " " "\n" "\r\n" "\t")))
  (define g-term-clean (g-pick '("\n" " " "\r\n" "\t")))
  (if (eq? fmt 'lines)
      (kinds
       (cons 12 (lambda (s) (draw* s ((v g-value)) (cons (rec-os 'lines 0 v) s))))
       (cons 4 (lambda (s) (draw* s ((v g-value) (a g-pad) (b g-pad))
                             (cons (string-append a (bare-os v) b "\n") s))))
       (cons 3 (lambda (s) (draw* s ((v g-value)) (cons (string-append (bare-os v) "\r\n") s))))
       (cons 5 (lambda (s) (draw* s ((t (g-pick scalar-pool)) (term (if clean? (g-pick '("\n" "\r\n")) g-term-lines)))
                             (cons (string-append t term) s))))
       (cons (if clean? 0 5) (lambda (s) (draw* s ((b (g-pick blank-lines-pool))) (cons b s))))
       (cons (if clean? 0 4) (lambda (s) (draw* s ((b (g-pick bad-pool)) (term g-term-lines))
                                           (cons (string-append b term) s)))))
      (kinds
       (cons 10 (lambda (s) (draw* s ((v g-value) (run (g-rs-run)) (ind (g-pick '(0 0 2))))
                              (cons (string-append (substring run 1 (string-length run))
                                                   (rec-os 'seq ind v)) s))))
       (cons 4 (lambda (s) (draw* s ((v g-value) (a g-pad) (b g-pad) (run (g-rs-run)) (term (if clean? g-term-clean g-term-seq)))
                             (cons (string-append run a (bare-os v) b term) s))))
       (cons 8 (lambda (s) (draw* s ((t (g-pick scalar-pool)) (run (g-rs-run)) (term (if clean? g-term-clean g-term-seq)))
                             (cons (string-append run t term) s))))
       (cons (if clean? 0 3) (lambda (s) (draw* s ((run (g-rs-run)) (w (g-pick '("" " " "\n" "\r\n"))))
                                           (cons (string-append run w) s))))
       (cons (if clean? 0 4) (lambda (s) (draw* s ((run (g-rs-run)) (b (g-pick bad-pool)) (term g-term-seq))
                                           (cons (string-append run b term) s)))))))

(define (strip-last-newline items)
  (if (null? items)
      items
      (let* ((last (car (reverse items))) (n (string-length last)))
        (append (reverse (cdr (reverse items)))
                (list (if (and (> n 0) (char=? (string-ref last (- n 1)) #\newline))
                          (substring last 0 (- n 1))
                          last))))))

(define (g-items fmt clean?)
  (lambda (s)
    (draw* s ((cnt (g-pick '(0 0 1 1 2 2 3 3 4 5 6 8 12 20)))
              (items (g-list cnt (g-item fmt clean?)))
              (strip (g-chance 1 3)))
      (cons (if strip (strip-last-newline items) items) s))))

(define g-prefix (g-pick (list "" "" "" "" "\n" " " (octets 239 187 191) "x" "1" "\r\n")))

;; A schedule: three lists of cut draws.
(define g-sched
  (lambda (s)
    (draw* s ((k (g-pick '(1 2 3 3 4 6))) (a (g-list k (g-int 32768)))
              (j (g-pick '(1 2 4))) (b (g-list j (g-int 32768)))
              (c (g-list 1 (g-int 32768))))
      (cons (list a b c) s))))

;; A case: (CFG BASE FMT PREFIX ITEMS EDITS SCHED).
(define (g-stream-case clean? edits?)
  (lambda (s)
    (draw* s ((cfg (g-int (vector-length configs)))
              (base (g-int (vector-length bases)))
              (cross (g-chance 1 5))
              (items-lines (g-items 'lines clean?))
              (items-seq (g-items 'seq clean?))
              (prefix g-prefix)
              (edits (if edits? g-edits (g-const '())))
              (sched g-sched))
      (let* ((fmt (if (eq? (cfg-stream cfg) 'seq)
                      (if cross 'lines 'seq)
                      (if cross 'seq 'lines)))
             (items (if (eq? fmt 'lines) items-lines items-seq)))
        (cons (list cfg base fmt (if (eq? fmt 'seq) prefix "") items edits sched) s)))))

;; An edit: (KIND R BYTES), BYTES an octet string of 1 to 4.
(define byte-pool
  (g-choose
   (list (cons 4 (g-const 10)) (cons 3 (g-const 13)) (cons 4 (g-const RS)) (cons 2 (g-const 32))
         (cons 1 (g-const 9)) (cons 3 (g-const 34))
         (cons 4 (g-pick (map char->integer (string->list "[]{}"))))
         (cons 3 (g-range 48 57)) (cons 2 (g-const 45)) (cons 3 (g-range 128 255))
         (cons 2 (g-pick (map char->integer (string->list "tfnu,:.eE\\/"))))
         (cons 1 (g-const 0)))))

(define g-edit
  (lambda (s)
    (draw* s ((kind (g-pick '(insert delete replace))) (r (g-int 32768))
              (k (g-range 1 4)) (bs (g-list k byte-pool)))
      (cons (list kind r (apply octets bs)) s))))

(define g-edits
  (lambda (s)
    (draw* s ((k (g-range 1 3)) (es (g-list k g-edit))) (cons es s))))

(define (apply-edit str edit)
  (let* ((kind (car edit)) (r (cadr edit)) (bs (caddr edit)) (n (string-length str)))
    (case kind
      ((insert)
       (let ((at (mod r (+ n 1))))
         (string-append (substring str 0 at) bs (substring str at n))))
      (else
       (if (= n 0)
           str
           (let* ((at (mod r n))
                  (len (min (string-length bs) (- n at))))
             (string-append (substring str 0 at)
                            (if (eq? kind 'replace) (substring bs 0 len) "")
                            (substring str (+ at len) n))))))))

(define (case-stream k)
  (fold-left apply-edit
             (string-append (list-ref k 3) (concat-strings (list-ref k 4)))
             (list-ref k 5)))

(define (shrinks-stream k)
  (let ((edits (list-ref k 5)) (items (list-ref k 4)) (sched (list-ref k 6)))
    (define (with-edits e) (list (car k) (cadr k) (caddr k) (list-ref k 3) items e sched))
    (define (with-items i) (list (car k) (cadr k) (caddr k) (list-ref k 3) i edits sched))
    (append
     (map (lambda (i) (with-edits (without-nth edits i))) (iota (length edits)))
     (map (lambda (i) (with-items (without-nth items i))) (iota (length items)))
     (if (string=? (list-ref k 3) "") '()
         (list (list (car k) (cadr k) (caddr k) "" items edits sched)))
     (if (equal? sched '(() () ())) '()
         (list (list (car k) (cadr k) (caddr k) (list-ref k 3) items edits '(() () ())))))))

;; --- the stream check -----------------------------------------------------------------------

(define (sort-nums xs) (list-sort < xs))

(define (separator-near? bv c)
  (let ((n (bytevector-length bv)))
    (and (< 0 c) (< c n)
         (or (memv (bytevector-u8-ref bv (- c 1)) (list 10 RS))
             (memv (bytevector-u8-ref bv c) (list 10 RS)))
         #t)))

(define (count-where pred xs) (length (filter pred xs)))

;; The streams' stats from the bytes alone: blank lines, RS runs, CRLF.
(define (has-blank-line? bv)
  (let ((n (bytevector-length bv)))
    (let loop ((start 0) (i 0))
      (cond ((= i n) (and (< start n) (blank-part? bv start n)))
            ((= (bytevector-u8-ref bv i) 10)
             (or (blank-part? bv start i) (loop (+ i 1) (+ i 1))))
            (else (loop start (+ i 1)))))))

(define (has-rs-run? bv)
  (let loop ((i 1))
    (and (< i (bytevector-length bv))
         (or (and (= (bytevector-u8-ref bv i) RS) (= (bytevector-u8-ref bv (- i 1)) RS))
             (loop (+ i 1))))))

(define (has-rs-run-of? bv len)
  (let loop ((i 0) (run 0))
    (and (< i (bytevector-length bv))
         (let ((run (if (= (bytevector-u8-ref bv i) RS) (+ run 1) 0)))
           (or (>= run len) (loop (+ i 1) run))))))

(define (has-crlf? bv)
  (let loop ((i 1))
    (and (< i (bytevector-length bv))
         (or (and (= (bytevector-u8-ref bv i) 10) (= (bytevector-u8-ref bv (- i 1)) 13))
             (loop (+ i 1))))))

(define (has-high-byte? bv)
  (let loop ((i 0))
    (and (< i (bytevector-length bv))
         (or (> (bytevector-u8-ref bv i) 127) (loop (+ i 1))))))

(define (tally-stream! tally k bv want)
  (tally! tally 'streams)
  (when (= (bytevector-length bv) 0) (tally! tally 'empty))
  (when (and (eq? (caddr k) 'lines) (has-blank-line? bv)) (tally! tally 'blank-line-streams))
  (when (has-rs-run? bv) (tally! tally 'rs-runs))
  (when (has-crlf? bv) (tally! tally (if (eq? (caddr k) 'lines) 'crlf-lines 'crlf-seq)))
  (when (has-rs-run-of? bv 4) (tally! tally 'rs-run-4))
  (when (has-high-byte? bv) (tally! tally 'high-bytes))
  (when (exists (lambda (e) (eq? (car e) 'value)) want) (tally! tally 'with-values))
  (when (exists (lambda (e) (and (eq? (car e) 'skip) (eq? (cadr e) 'truncated))) want)
    (tally! tally 'truncated))
  (when (exists (lambda (e) (and (eq? (car e) 'skip) (eq? (cadr e) 'blank-line))) want)
    (tally! tally 'blank-skipped))
  (when (exists (lambda (e) (and (eq? (car e) 'skip) (not (memq (cadr e) '(truncated blank-line nesting-too-deep number-too-long))))) want)
    (tally! tally 'bad-skipped)
    (when (eq? (caddr k) (cfg-stream (car k)))
      (tally! tally (if (eq? (caddr k) 'lines) 'bad-skipped-lines 'bad-skipped-seq))))
  (when (exists (lambda (e) (and (eq? (car e) 'skip) (memq (cadr e) '(nesting-too-deep number-too-long)))) want)
    (tally! tally 'limit-errors))
  (when (eq? (caddr k) (cfg-stream (car k)))
    (for-each (lambda (e)
                (when (memq (car e) '(skip error))
                  (tally! tally (string->symbol (string-append (symbol->string (caddr k)) "-code-" (symbol->string (if (eq? (car e) 'skip) (cadr e) (cadr e))))))))
              want))
  (when (exists (lambda (e) (eq? (car e) 'error)) want) (tally! tally 'stopped)))

;; stream-check : Tally -> Case -> (U #f Evidence)
(define (stream-check tally)
  (lambda (k)
    (let* ((cfg (car k)) (base (cadr k))
           (bv (os->bv (case-stream k)))
           (n (bytevector-length bv))
           (o (reader-options cfg base))
           (on-skip? (cfg-on-skip? cfg))
           (want (oracle cfg base bv))
           (bad #f))
      (tally-stream! tally k bv want)
      (let try ((schedules
                 (append
                  (list '())
                  (map (lambda (draws) (sort-nums (map (lambda (r) (mod r (+ n 1))) draws)))
                       (list-ref k 6))
                  (if (<= n 64)
                      (begin (tally! tally 'exhaustive)
                             (cons (iota-from 1 n)
                                   (map list (iota (+ n 1)))))
                      '()))))
        (cond
          ((null? schedules) bad)
          (else
           (let* ((cuts (car schedules))
                  (got (run-reader o on-skip? bv cuts)))
             (tally! tally 'runs)
             (when (> (length (chunks n cuts)) 1) (tally! tally 'multi-feed))
             (when (> n 64) (tally! tally 'long-runs))
             (when (and (> n 64) (> (length (chunks n cuts)) 1)) (tally! tally 'long-multi-feed))
             (when (exists (lambda (c) (separator-near? bv c)) cuts) (tally! tally 'near-separator))
             (if (equal? got want)
                 (try (cdr schedules))
                 (list 'mismatch 'config (car (cfg-ref cfg)) 'base base
                       'stream (bv->os bv) 'cuts cuts 'got got 'want want)))))))))

;; The cuts of byte-by-byte feeding: 1 to N-1... here every position 1..N.
(define (iota-from lo hi)
  (let loop ((i hi) (acc '())) (if (< i lo) acc (loop (- i 1) (cons i acc)))))

;; --- hand-worked logs: the oracle and the library both ---------------------------------------

(define (hand-check name cfg-i base-i stream-os want)
  (let ((bv (os->bv stream-os)))
    (test-equal (string-append "oracle, " name)
      want (oracle cfg-i base-i bv))
    (test-equal (string-append "reader, whole, " name)
      want (run-reader (reader-options cfg-i base-i) (cfg-on-skip? cfg-i) bv '()))
    (test-equal (string-append "reader, byte by byte, " name)
      want (run-reader (reader-options cfg-i base-i) (cfg-on-skip? cfg-i) bv
                       (iota-from 1 (bytevector-length bv))))))

;; Base 0 reads integers as exact, null as nil, objects as hashtables, at
;; most 2 containers deep, at most 6 digits.
;; lines "1\n\n[2]" skipping: blank line 2 is the "\n" at 2.
(hand-check "lines: a blank line is a bad record at its newline, and records count it"
            1 0 "1\n\n[2]"
            '((value 1 1) (skip blank-line 2 2) (value #(2) 3) (finished 6 4)))
(hand-check "lines, blank-lines skip: a blank line is passed over but numbered"
            3 0 "1\n \t\r\n[2]"
            '((value 1 1) (value #(2) 3) (finished 9 4)))
(hand-check "lines: the last line, blank and with no newline, is blank-line at the end"
            1 0 "1\n  "
            '((value 1 1) (skip blank-line 2 4) (finished 4 3)))
(hand-check "lines with no ON-SKIP: the stream ends at the first bad record; its offset is the line's start plus the builder's"
            0 0 "1\n[1,]\n3"
            '((value 1 1) (error unexpected-byte 5 2)))
(hand-check "lines with no ON-SKIP: a blank line ends the stream"
            0 0 "7\n\n8\n"
            '((value 7 1) (error blank-line 2 2)))
(hand-check "lines: a record found bad is skipped to its newline, and the next one is read"
            1 0 "[1,]5\n9\n"
            '((skip unexpected-byte 1 3) (value 9 2) (finished 8 3)))
(hand-check "lines: no trailing newline, CRLF, and whitespace around the value"
            1 0 " 12 \r\n34"
            '((value 12 1) (value 34 2) (finished 8 3)))
(hand-check "lines: a raw RS is not a separator"
            1 0 (string-append "1" RS-os "2\n")
            '((skip trailing-garbage 1 1) (finished 4 2)))
(hand-check "lines: the depth limit applies to each record, and the digit limit too"
            1 0 "[[[1]]]\n1234567\n[[1]]\n"
            '((skip nesting-too-deep 1 3) (skip number-too-long 2 15) (value #(#(1)) 3) (finished 22 4)))
;; seq: x RS RS [1] LF RS 2 SP
(hand-check "seq: bytes before the first RS are a bad record at their first; repeated RSs make no record; whitespace after a number is enough"
            4 0 (string-append "x" RS-os RS-os "[1]\n" RS-os "2 ")
            '((skip unexpected-byte 1 0) (value #(1) 2) (value 2 3) (finished 10 4)))
(hand-check "seq: a number with nothing after it is truncated, at the record's end"
            4 0 (string-append RS-os "1")
            '((skip truncated 1 2) (finished 2 2)))
(hand-check "seq: a literal, and a number cut short before an RS, are truncated at their ends; a string is not"
            4 0 (string-append RS-os "true" RS-os "12" RS-os "\"a\"" RS-os "null\n")
            '((skip truncated 1 5) (skip truncated 2 8) (value "a" 3) (value nil 4) (finished 18 5)))
(hand-check "seq: a record that fails to parse keeps its parser's code, and an empty record after an RS is nothing"
            4 0 (string-append RS-os "[1,]" RS-os RS-os " " RS-os "3\n")
            '((skip unexpected-byte 1 4) (skip unexpected-eof 2 8) (value 3 3) (finished 11 4)))
(hand-check "seq: a leading newline is a bad record"
            4 0 (string-append "\n" RS-os "5\n")
            '((skip unexpected-byte 1 0) (value 5 2) (finished 4 3)))
(hand-check "seq: a stream of no records"
            4 0 ""
            '((finished 0 1)))
(hand-check "seq, text numbers: a number record reads as its text"
            4 1 (string-append RS-os "10\n" RS-os "-0.5e3 ")
            '((value (json-number "10") 1) (value (json-number "-0.5e3") 2) (finished 12 3)))

;; --- 1. generated streams ----------------------------------------------------------------------

(define tally-1 (make-tally))
(test-equal "generated streams: the reader's log is the oracle's, in one feed, in random chunks, and in every split of a short stream"
  '()
  (property-failures run 'generated 41 case-groups (lambda (s) (car ((g-list 10 (g-stream-case #f #f)) s)))
                     (stream-check tally-1) shrinks-stream tally-1))

;; --- 2. mutated streams ----------------------------------------------------------------------------

(define tally-2 (make-tally))
(test-equal "mutated streams: the reader's log is the oracle's, in one feed, in random chunks, and in every split of a short stream"
  '()
  (property-failures run 'mutated 42 case-groups (lambda (s) (car ((g-list 10 (g-stream-case #t #t)) s)))
                     (stream-check tally-2) shrinks-stream tally-2))

;; --- 3. chunking, counted ---------------------------------------------------------------------------

(define (check-counts name tally)
  (let ((streams (tally-count tally 'streams)) (runs (tally-count tally 'runs)))
    (test-equal (string-append name ": the streams and runs ran, most runs used several feeds, and some split next to a separator")
      '(#t #t #t #t #t #t #t)
      (list (>= streams (* 10 case-groups multiplier))
            (> runs (* 4 streams))
            (> (tally-count tally 'multi-feed) (div (* 3 runs) 4))
            (> (tally-count tally 'near-separator) (div runs 10))
            (> (tally-count tally 'exhaustive) (* 100 multiplier))
            (> (tally-count tally 'long-runs) (* 300 multiplier))
            (> (tally-count tally 'long-multi-feed) (div (* 2 (tally-count tally 'long-runs)) 3))))))

(check-counts "generated" tally-1)
(check-counts "mutated" tally-2)

;; --- 6. the tally of what the generated streams held ------------------------------------------------------

(test-equal "generated streams held blank lines, RS runs, CRLF in both formats, truncations, bad records in both formats, blank-line records, stopped streams, values, empty streams and bytes of 128 and above"
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t)
  (let ((m multiplier))
    (list (> (tally-count tally-1 'blank-line-streams) (* 350 m))
          (> (tally-count tally-1 'rs-runs) (* 250 m))
          (> (tally-count tally-1 'crlf-lines) (* 400 m))
          (> (tally-count tally-1 'crlf-seq) (* 150 m))
          (> (tally-count tally-1 'rs-run-4) (* 150 m))
          (> (tally-count tally-1 'truncated) (* 60 m))
          (> (tally-count tally-1 'bad-skipped-lines) (* 150 m))
          (> (tally-count tally-1 'bad-skipped-seq) (* 150 m))
          (> (tally-count tally-1 'blank-skipped) (* 90 m))
          (> (tally-count tally-1 'stopped) (* 300 m))
          (> (tally-count tally-1 'with-values) (* 800 m))
          (> (tally-count tally-1 'empty) (* 150 m))
          (> (tally-count tally-1 'high-bytes) (* 600 m)))))

(define bad-codes
  '(control-character invalid-escape invalid-number nesting-too-deep number-too-long
    trailing-garbage unexpected-byte unexpected-eof))

(define (code-key fmt code) (string->symbol (string-append (symbol->string fmt) "-code-" (symbol->string code))))

(test-equal "generated streams gave every kind of bad record the pool makes, in both formats, and blank-line and truncated ones"
  '(() () #t #t)
  (let ((m multiplier))
    (list (filter (lambda (c) (<= (tally-count tally-1 (code-key 'lines c)) (* 10 m))) bad-codes)
          (filter (lambda (c) (<= (tally-count tally-1 (code-key 'seq c)) (* 10 m))) bad-codes)
          (> (tally-count tally-1 (code-key 'lines 'blank-line)) (* 200 m))
          (> (tally-count tally-1 (code-key 'seq 'truncated)) (* 100 m)))))

(test-equal "mutated streams held both good and bad records, truncations, and stopped streams"
  '(#t #t #t #t)
  (let ((m multiplier))
    (list (> (tally-count tally-2 'with-values) (* 700 m))
          (> (tally-count tally-2 'truncated) (* 20 m))
          (> (tally-count tally-2 'bad-skipped) (* 700 m))
          (> (tally-count tally-2 'stopped) (* 450 m)))))

;; The shrinker, on a case made to fail: it drops what it can and keeps the failure.
(test-equal "shrink: a case that fails for one item shrinks to that item alone"
  '(0 0 lines "" ("BAD") () (() () ()))
  (shrink (list 0 0 'lines "x" '("a" "b" "BAD" "c") '((insert 3 "q")) '((1 2) (3) (4)))
          (lambda (k) (and (member "BAD" (list-ref k 4)) 'fails))
          shrinks-stream))

;; --- 4. round trips ----------------------------------------------------------------------------------------

;; (NAME WRITER-OPTIONS READER-OPTIONS ON-SKIP? NUMBERS NULL MODE OBJECTS)
(define rt-sets
  (list (list 'defaults (opts) (opts) #f g-any-num 'null 'flonum 'alist)
        (list 'lines-blank-skip-hashtable-zip
              (opts 'null 'zip)
              (opts 'blank-lines 'skip 'object-mode 'hashtable 'null 'zip)
              #f g-any-num 'zip 'flonum 'hashtable)
        (list 'seq-indent-2
              (opts 'stream 'seq 'indent 2) (opts 'stream 'seq) #t g-any-num 'null 'flonum 'alist)
        (list 'seq-text-hashtable-nil-indent-3
              (opts 'stream 'seq 'indent 3 'null 'nil)
              (opts 'stream 'seq 'number-mode 'text 'object-mode 'hashtable 'null 'nil)
              #t g-int-num 'nil 'text 'hashtable)
        (list 'values-exact-indent-1
              (opts 'stream 'values 'indent 1)
              (opts 'stream 'values 'number-mode 'exact) #f g-any-num 'null 'exact 'alist)
        (list 'values-text-hashtable-zip
              (opts 'stream 'values 'null 'zip)
              (opts 'stream 'values 'number-mode 'text 'object-mode 'hashtable 'null 'zip)
              #f g-int-num 'zip 'text 'hashtable)))

(define (rt-ref i k) (list-ref (list-ref rt-sets i) k))

;; What a written value must read as: numbers by the mode, null as the
;; options' null, objects as alists; a hashtable set goes through
;; as-hashtables after.
(define (expected-read v mode null)
  (cond ((eq? v 'NULLMARK) null)
        ((number? v)
         (case mode
           ((flonum) v)
           ((exact) (if (exact? v) v (exact v)))
           (else (list 'json-number (number->string v)))))
        ((vector? v) (vector-map (lambda (x) (expected-read x mode null)) v))
        ((pair? v) (map (lambda (m) (cons (car m) (expected-read (cdr m) mode null))) v))
        (else v)))

(define (rt-expected i values)
  (let ((mode (rt-ref i 6)) (null (rt-ref i 5)))
    (map (lambda (v)
           (let ((e (expected-read v mode null)))
             (if (eq? (rt-ref i 7) 'hashtable) (as-hashtables e) e)))
         values)))

(define (rt-log i values)
  (let loop ((vs (rt-expected i values)) (rec 1) (acc '()))
    (if (null? vs)
        (reverse (cons (list 'finished
                             (bytevector-length (rt-bytes i values))
                             rec)
                       acc))
        (loop (cdr vs) (+ rec 1) (cons (list 'value (car vs) rec) acc)))))

(define (rt-bytes i values)
  (call-with-bytevector-output-port
   (lambda (p)
     (for-each (lambda (v) (put-json-record p (subst-null v (rt-ref i 5)) (rt-ref i 1)))
               values))))

(define g-rt-case
  (lambda (s)
    (draw* s ((i (g-int (length rt-sets))) (cnt (g-pick '(0 1 1 2 3 5 8)))
              (vs (g-list cnt (g-val (rt-ref i 4) 3))) (sched g-sched))
      (cons (list i vs sched) s))))

(define rt-tally (make-tally))

(define (rt-check k)
  (let* ((i (car k)) (values (cadr k))
         (bv (rt-bytes i values))
         (n (bytevector-length bv))
         (want (rt-log i values)))
    (tally! rt-tally (car (list-ref rt-sets i)))
    (let try ((schedules (cons '()
                               (map (lambda (draws) (sort-nums (map (lambda (r) (mod r (+ n 1))) draws)))
                                    (caddr k)))))
      (if (null? schedules)
          #f
          (let ((got (run-reader (rt-ref i 2) (rt-ref i 3) bv (car schedules))))
            (if (equal? got want)
                (try (cdr schedules))
                (list 'mismatch (car (list-ref rt-sets i)) 'bytes (bv->os bv)
                      'cuts (car schedules) 'got got 'want want)))))))

(define (rt-shrinks k)
  (map (lambda (j) (list (car k) (without-nth (cadr k) j) (caddr k)))
       (iota (length (cadr k)))))

(test-equal "round trips: values written by put-json-record in each format are read back, under six option sets"
  '()
  (property-failures run 'round-trip 43 100 (lambda (s) (car ((g-list 10 g-rt-case) s)))
                     rt-check rt-shrinks rt-tally))

(test-equal "round trips: every option set ran many times"
  #t
  (for-all (lambda (e) (> (tally-count rt-tally (car e)) (* 20 multiplier))) rt-sets))

;; --- 5. values against the builder ---------------------------------------------------------------------

(define y-dir "tests/corpus/jsontestsuite/test_parsing")
(define y-files
  (filter (lambda (n) (and (> (string-length n) 2) (string=? (substring n 0 2) "y_")))
          (corpus-files y-dir ".json")))
(define y-bytes (map (lambda (n) (file-bytes (string-append y-dir "/" n))) y-files))

(define values-opts (opts 'stream 'values))

(define (builder-canon bv)
  (let* ((b (make-json-builder (opts)))
         (r (json-builder-feed! b bv))
         (r (if (eq? (json-result-status r) 'error) r (json-builder-finish! b))))
    (if (eq? (json-result-status r) 'finished)
        (canonical (json-builder-value b))
        (list 'builder-failed (json-result-code r)))))

(define (bv-join a b)
  (let ((r (make-bytevector (+ (bytevector-length a) 1 (bytevector-length b)) 32)))
    (bytevector-copy! a 0 r 0 (bytevector-length a))
    (bytevector-copy! b 0 r (+ (bytevector-length a) 1) (bytevector-length b))
    r))

(define y-bad '())
(define y-ran 0)
(for-each
 (lambda (name bv)
   (let ((want (list (list 'value (builder-canon bv) 1)
                     (list 'finished (bytevector-length bv) 2))))
     (set! y-ran (+ y-ran 1))
     (let ((got (run-reader values-opts #f bv '()))
           (bytewise (run-reader values-opts #f bv (iota-from 1 (bytevector-length bv)))))
       (unless (and (equal? got want) (equal? bytewise want))
         (set! y-bad (cons (list name 'got got 'bytewise bytewise 'want want) y-bad))))))
 y-files y-bytes)

(test-equal "values: every JSONTestSuite y_ file is one value, as a builder reads it, whole and byte by byte"
  '() (reverse y-bad))

(test-equal "values: 95 y_ files ran, and none is empty or starts with a byte order mark"
  '(95 #t)
  (list y-ran
        (for-all (lambda (bv)
                   (and (> (bytevector-length bv) 0)
                        (not (and (>= (bytevector-length bv) 3)
                                  (= (bytevector-u8-ref bv 0) 239)
                                  (= (bytevector-u8-ref bv 1) 187)))))
                 y-bytes)))

(define y-pairs-bad '())
(define y-pairs 0)
(let loop ((as y-bytes) (bs (if (null? y-bytes) '() (cdr y-bytes))) (ns y-files))
  (unless (null? bs)
    (let* ((a (car as)) (b (car bs)) (bv (bv-join a b))
           (want (list (list 'value (builder-canon a) 1)
                       (list 'value (builder-canon b) 2)
                       (list 'finished (bytevector-length bv) 3))))
      (set! y-pairs (+ y-pairs 1))
      (let ((got (run-reader values-opts #f bv '()))
            (split (run-reader values-opts #f bv (list (bytevector-length a)
                                                       (+ 1 (bytevector-length a))))))
        (unless (and (equal? got want) (equal? split want))
          (set! y-pairs-bad (cons (list (car ns) (cadr ns) 'got got 'split split 'want want)
                                  y-pairs-bad)))))
    (loop (cdr as) (cdr bs) (cdr ns))))

(test-equal "values: two y_ files joined by a space are two values"
  '() (reverse y-pairs-bad))
(test-equal "values: 94 pairs ran"
  94 y-pairs)

(test-end "sequence-property")

(exit (suite-exit-status runner))
