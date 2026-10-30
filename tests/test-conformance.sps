;;; tests/test-conformance.sps: the JSONTestSuite gate (ADR-0012 §2).
;;;
;;;   (a) the corpus is all here: 95 y_, 188 n_ and 35 i_ files
;;;   (b) every y_ is accepted and every n_ rejected, in one feed
;;;   (c) every file's answer is the one in tests/golden/jsontestsuite.txt:
;;;       the i_ files' verdicts, and the code and offset of each n_ rejection
;;;   (d) chunking changes nothing: trace-content under chunk sizes 1 to 31
;;;       is that of one feed; a file over 4 KB gets chunks of 1, 7 and 31
;;;       and 5 random schedules from a fixed seed instead
;;;   (e) the differential: the generated and the interpreted machine give
;;;       equal raw traces in one feed and in chunks of 1; a file over 4 KB
;;;       gets one feed only
;;;
;;;   (f) every file of at most 64 bytes under every schedule byte-machine's
;;;       schedules-for gives (every split, every pair of splits, whole,
;;;       empties, a sub-slice, a padded buffer, 4 random multi-splits; PRNG
;;;       state 1 for the first file, then the state each call returns):
;;;       trace-content is that of one feed, and the generated and
;;;       interpreted raw traces are equal
;;;
;;; The golden file is one line per file, sorted by name: NAME accepted, or
;;; NAME rejected CODE OFFSET. To rewrite it, deliberately, when the
;;; grammar's answers are meant to change, run the program that wrote it,
;;; and read the diff before committing:
;;;
;;;   scripts/guix-env sh -c 'make deps >/dev/null && $CHEZ --libdirs \
;;;     src:vendor/byte-machine/src:build/scheme-libs:tests:grammar:vendor/byte-machine/test/support/harness \
;;;     --program tests/write-golden.sps tests/golden/jsontestsuite.txt'
;;;
;;; A failing check names the files and prints each differing golden line.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing property)
        (jsonparse-testing machine)
        (only (byte-machine test property-driver) schedules-for)
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

;; --- the corpus -----------------------------------------------------------------

(define dir "tests/corpus/jsontestsuite/test_parsing")
(define golden-path "tests/golden/jsontestsuite.txt")
(define seed 20261030)
(define small-limit 4096)

;; answer : (-> Any) -> Any
;; THUNK's value, or (raised TEXT).
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? p (substring s 0 (string-length p)))))

(define names (corpus-files dir ".json"))

(define (named p) (filter (lambda (n) (prefix? p n)) names))

(define (path name) (string-append dir "/" name))

;; files : (Listof (Pair String Bytevector))
(define files (map (lambda (n) (cons n (file-bytes (path n)))) names))

(define (outcome-of bv)
  (trace-outcome (run-machine generated-machine (whole-schedule bv) '())))

;; outcomes : (Listof (Pair String Outcome)), the generated machine in one feed
(define outcomes (map (lambda (f) (cons (car f) (outcome-of (cdr f)))) files))

(define (small? f) (<= (bytevector-length (cdr f)) small-limit))

;; --- (a) the corpus is all here ---------------------------------------------------

(test-begin "conformance")

(test-equal "(a) the corpus has 95 y_, 188 n_ and 35 i_ files, and no others"
  '(95 188 35 318)
  (list (length (named "y_")) (length (named "n_")) (length (named "i_"))
        (length names)))

;; --- (b) every y_ is accepted, every n_ rejected ------------------------------------

(define (wrong-verdicts prefix want)
  (filter (lambda (n) (not (eq? (car (cdr (assoc n outcomes))) want)))
          (named prefix)))

(test-equal "(b) every y_ file is accepted"
  '()
  (wrong-verdicts "y_" 'accepted))

(test-equal "(b) every n_ file is rejected"
  '()
  (wrong-verdicts "n_" 'rejected))

;; --- (c) the golden file ------------------------------------------------------------

(define (split-lines text)
  (let loop ((cs (string->list text)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc))))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

(define (line-name line)
  (let loop ((i 0))
    (if (or (= i (string-length line)) (char=? (string-ref line i) #\space))
        (substring line 0 i)
        (loop (+ i 1)))))

;; The lines the machine gives now: golden-line, per file, sorted by name.
(define actual-lines
  (map (lambda (f) (golden-line (car f) (cdr f))) files))

(define golden-lines
  (answer (lambda ()
            (split-lines (utf8->string (file-bytes golden-path))))))

;; differing-lines : (Listof String) (Listof String) -> (Listof (List String String))
;; Each name whose golden line and actual line differ or are missing, as
;; (golden-line actual-line), "-" for a missing one; and each golden line
;; written to stdout.
(define (differing-lines golden actual)
  (let* ((table (lambda (lines) (map (lambda (l) (cons (line-name l) l)) lines)))
         (g (table golden)) (a (table actual))
         (all (list-sort string<? (let loop ((ns (append (map car g) (map car a))) (seen '()))
                                    (cond ((null? ns) seen)
                                          ((member (car ns) seen) (loop (cdr ns) seen))
                                          (else (loop (cdr ns) (cons (car ns) seen))))))))
    (filter (lambda (d) d)
            (map (lambda (n)
                   (let ((gl (assoc n g)) (al (assoc n a)))
                     (let ((gs (if gl (cdr gl) "-")) (as (if al (cdr al) "-")))
                       (and (not (string=? gs as))
                            (begin
                              (display (string-append "golden:  " gs "\nactual:  " as "\n"))
                              (list gs as))))))
                 all))))

(test-equal "(c) every file's answer is its line in tests/golden/jsontestsuite.txt"
  '()
  (if (string? (and (pair? golden-lines) (car golden-lines)))
      (differing-lines golden-lines actual-lines)
      golden-lines))

(test-equal "(c) the golden file is sorted, one line for each of 318 files"
  '(318 #t)
  (list (length golden-lines)
        (equal? golden-lines (list-sort string<? golden-lines))))

(define (split-words line)
  (let loop ((cs (string->list line)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc))))
          ((char=? (car cs) #\space) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

(test-equal "(c) the golden file says what the verdict was: 11 i_ accepted, 24 i_ rejected"
  '(11 24)
  (list (length (filter (lambda (l) (and (prefix? "i_" l) (= 2 (length (split-words l)))))
                        golden-lines))
        (length (filter (lambda (l) (and (prefix? "i_" l) (= 4 (length (split-words l)))))
                        golden-lines))))

;; --- (d) chunking changes nothing ---------------------------------------------------

(define (content-of bv schedule)
  (trace-content (run-machine generated-machine schedule '())))

(define sizes (let loop ((k 31) (acc '())) (if (= k 0) acc (loop (- k 1) (cons k acc)))))

;; chunk-failures : Pair -> (Listof (List String Any))
;; For one file, each schedule (named by a chunk size or by "random N")
;; whose trace-content is not that of one feed.
(define (chunk-failures f state)
  (let* ((bv (cdr f))
         (want (content-of bv (whole-schedule bv)))
         (bad (lambda (label schedule)
                (and (not (equal? (content-of bv schedule) want))
                     (list (car f) label)))))
    (if (small? f)
        (cons (filter (lambda (x) x)
                      (map (lambda (k) (bad k (chunk-schedule bv k))) sizes))
              state)
        (let loop ((i 0) (s state) (acc '()))
          (if (= i 5)
              (cons (filter (lambda (x) x)
                            (append (map (lambda (k) (bad k (chunk-schedule bv k))) '(1 7 31))
                                    acc))
                    s)
              (let* ((p (random-schedule bv s))
                     (b (bad (list 'random i) (car p))))
                (loop (+ i 1) (cdr p) (if b (cons b acc) acc))))))))

(test-equal "(d) trace-content of chunks of 1 to 31 bytes (big files: 1, 7, 31 and 5 random) is that of one feed"
  '()
  (let loop ((fs files) (state seed) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let ((r (chunk-failures (car fs) state)))
          (loop (cdr fs) (cdr r) (append (reverse (car r)) acc))))))

;; --- (e) the differential -----------------------------------------------------------

(define (raw machine schedule) (run-machine machine schedule '()))

(test-equal "(e) generated and interpreted machines give equal raw traces: one feed, and chunks of 1 up to 4 KB"
  '()
  (filter (lambda (x) x)
          (map (lambda (f)
                 (let ((bv (cdr f)))
                   (and (not (and (equal? (raw generated-machine (whole-schedule bv))
                                          (raw interpreted-machine (whole-schedule bv)))
                                  (or (not (small? f))
                                      (equal? (raw generated-machine (chunk-schedule bv 1))
                                              (raw interpreted-machine (chunk-schedule bv 1))))))
                        (car f))))
               files)))

;; --- (f) small files under every schedule --------------------------------------------

(define tiny-limit 64)

;; tiny-failures : Pair State -> (Pair (Listof (List String Nat)) State)
;; For one file, each schedule (by place) that changes the content, or on
;; which the machines differ; and the PRNG state after.
(define (tiny-failures f state)
  (let ((bv (cdr f)))
    (let-values (((schedules next) (schedules-for bv state)))
      (let ((want (content-of bv (whole-schedule bv))))
        (cons (let check ((ss schedules) (i 0) (bad '()))
                (cond
                 ((null? ss) (reverse bad))
                 ((let ((g (raw generated-machine (car ss))))
                    (and (equal? (trace-content g) want)
                         (equal? g (raw interpreted-machine (car ss)))))
                  (check (cdr ss) (+ i 1) bad))
                 (else (check (cdr ss) (+ i 1) (cons (list (car f) i) bad)))))
              next)))))

(test-equal "(f) files of at most 64 bytes: every schedule gives one feed's content, and both machines agree"
  '()
  (let loop ((fs (filter (lambda (f) (<= (bytevector-length (cdr f)) tiny-limit)) files))
             (state (make-prng 1)) (bad '()))
    (if (null? fs)
        (reverse bad)
        (let ((r (tiny-failures (car fs) state)))
          (loop (cdr fs) (cdr r) (append (reverse (car r)) bad))))))

(test-end "conformance")

(exit (suite-exit-status runner))
