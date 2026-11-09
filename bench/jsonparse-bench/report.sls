#!r6rs
;;; (jsonparse-bench report): checks the two harnesses' results against each
;;; other, then writes them as Markdown (ADR-0013, ADR-0023).
;;;
;;; A harness writes a runtime form, then a result form per file and lane:
;;;
;;;   (runtime (parser P) (version V) ... (rounds R) (round-bytes B))
;;;   (result (file F) (bytes N) (parser P) (lane L) (iterations I)
;;;           (round-ns NS ...) (counts (NAME . COUNT) ...) (passes K)
;;;           [(timed-counts (NAME . COUNT) ...)] [(allocated BYTES) (gc-ns NS)])
;;;
;;; yajl gives the parse and events lanes; jsonparse every lane, with
;;; allocated and gc-ns. A result's counts are one pass's, taken outside
;;; the timing: the events lane's, the walk's, composition's for scan, and
;;; none for the rest. passes counts every pass the timed thunk finished,
;;; the warm-up round's included, and timed-counts sums what those passes
;;; counted, for each lane with counts.
(library (jsonparse-bench report)
  (export read-machine cross-check method-text target-line report-text
          fixed group-digits)
  (import (rnrs)
          (only (jsonparse-bench) count-names mb/s median iterations-for))

  ;; --- reading results -------------------------------------------------------

  (define (field r key)
    (let ((f (assq key (cdr r))))
      (unless f (error 'report "a form lacks a field" key r))
      (cadr f)))

  (define (field-list r key)
    (let ((f (assq key (cdr r))))
      (unless f (error 'report "a form lacks a field" key r))
      (cdr f)))

  (define (runtime-of runtimes parser)
    (find (lambda (rt) (eq? (field rt 'parser) parser)) runtimes))

  (define (runtimes-of runtimes parser)
    (length (filter (lambda (rt) (eq? (field rt 'parser) parser)) runtimes)))

  ;; Every lane each parser must give for each file, in the report's order.
  (define required
    '((yajl . parse) (yajl . events)
      (jsonparse . parse) (jsonparse . events) (jsonparse . tree)
      (jsonparse . tree+walk) (jsonparse . scan)))

  ;; The lanes whose passes count something.
  (define counted
    '((yajl . events) (jsonparse . events) (jsonparse . tree+walk) (jsonparse . scan)))

  (define (results-of results file parser lane)
    (filter (lambda (r) (and (equal? (field r 'file) file)
                             (eq? (field r 'parser) parser)
                             (eq? (field r 'lane) lane)))
            results))

  (define (the results file parser lane)
    (car (results-of results file parser lane)))

  ;; The files the results name, sorted.
  (define (files-of results)
    (let loop ((l (list-sort string<? (map (lambda (r) (field r 'file)) results))) (acc '()))
      (cond ((null? l) (reverse acc))
            ((and (pair? acc) (string=? (car l) (car acc))) (loop (cdr l) acc))
            (else (loop (cdr l) (cons (car l) acc))))))

  (define (count alist name)
    (let ((p (assq name alist))) (and p (cdr p))))

  ;; read-machine : String -> (Listof (Pair Symbol String))
  ;; Lines of KEY: VALUE, blank lines skipped.
  (define (read-machine text)
    (let loop ((lines (split-lines text)) (acc '()))
      (cond ((null? lines) (reverse acc))
            ((string=? (car lines) "") (loop (cdr lines) acc))
            (else
             (let ((i (search (car lines) ": ")))
               (unless i (error 'read-machine "not KEY: VALUE" (car lines)))
               (loop (cdr lines)
                     (cons (cons (string->symbol (substring (car lines) 0 i))
                                 (substring (car lines) (+ i 2) (string-length (car lines))))
                           acc)))))))

  (define (split-lines text)
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i (string-length text))
             (reverse (if (< start i) (cons (substring text start i) acc) acc)))
            ((char=? (string-ref text i) #\newline)
             (loop (+ i 1) (+ i 1) (cons (substring text start i) acc)))
            (else (loop (+ i 1) start acc)))))

  (define (search s pattern)
    (let ((n (string-length s)) (m (string-length pattern)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) pattern) i)
              (else (loop (+ i 1)))))))

  ;; --- the cross-check -------------------------------------------------------

  (define (show x)
    (cond ((not x) "none")
          ((number? x) (number->string x))
          ((symbol? x) (symbol->string x))
          (else x)))

  (define (say . parts) (apply string-append (map show parts)))

  ;; cross-check : (Listof String) (Listof Runtime) (Listof Result) -> (Listof String)
  ;; What makes the results unfit to report, or '(): both runtimes, once
  ;; each, with the same rounds and round bytes; results for exactly FILES,
  ;; the lock's; then, for each file, every lane of each parser once, with
  ;; its runtime's rounds; one size for the file; iterations-for's passes a
  ;; round, and that many in every round, the warm-up's included; yajl's
  ;; events counts equal to jsonparse's; the walk's counts equal to the
  ;; events'; the scan covering the file, with the events' number bytes;
  ;; and in each counted lane, the timed passes' counts one pass's times the
  ;; passes run.
  (define (cross-check files runtimes results)
    (let ((jp (runtime-of runtimes 'jsonparse))
          (yj (runtime-of runtimes 'yajl)))
      (cond ((not jp) '("no jsonparse runtime"))
            ((not yj) '("no yajl runtime"))
            ((exists (lambda (p) (> (runtimes-of runtimes p) 1)) '(jsonparse yajl))
             (map (lambda (p) (say p " has " (runtimes-of runtimes p) " runtimes"))
                  (filter (lambda (p) (> (runtimes-of runtimes p) 1)) '(jsonparse yajl))))
            ((not (and (= (field yj 'rounds) (field jp 'rounds))
                       (= (field yj 'round-bytes) (field jp 'round-bytes))))
             (list (say "yajl ran " (field yj 'rounds) " rounds of " (field yj 'round-bytes)
                        " bytes, jsonparse " (field jp 'rounds) " of " (field jp 'round-bytes))))
            (else
             (let ((named (files-of results)))
               (append
                (map (lambda (file) (say file ": no results"))
                     (filter (lambda (file) (not (member file named))) files))
                (map (lambda (file) (say file ": not in the lock"))
                     (filter (lambda (file) (not (member file files))) named))
                (apply append
                       (map (lambda (file)
                              (check-file results file (field jp 'rounds) (field jp 'round-bytes)))
                            named))))))))

  (define (check-file results file rounds round-bytes)
    (let ((presence
           (apply append
                  (map (lambda (pl)
                         (let ((rs (results-of results file (car pl) (cdr pl))))
                           (cond ((null? rs) (list (say file ": no " (car pl) " " (cdr pl) " result")))
                                 ((pair? (cdr rs)) (list (say file ": " (car pl) " " (cdr pl) " given twice")))
                                 (else '()))))
                       required))))
      (if (pair? presence)
          presence
          (let* ((rs (map (lambda (pl) (the results file (car pl) (cdr pl))) required))
                 (size (field (find (lambda (r) (equal? (field r 'file) file)) results) 'bytes)))
            (append
             (apply append
                    (map (lambda (pl r)
                           (let ((k (length (field-list r 'round-ns))))
                             (if (= k rounds)
                                 '()
                                 (list (say file ": " (car pl) " " (cdr pl) " has " k " rounds, not " rounds)))))
                         required rs))
             (apply append
                    (map (lambda (pl r)
                           (if (= (field r 'bytes) size)
                               '()
                               (list (say file ": " (car pl) " " (cdr pl) " read " (field r 'bytes)
                                          " bytes, not " size))))
                         required rs))
             (let ((iterations (iterations-for size round-bytes)))
               (apply append
                      (map (lambda (pl r)
                             (append
                              (if (= (field r 'iterations) iterations)
                                  '()
                                  (list (say file ": " (car pl) " " (cdr pl) " ran " (field r 'iterations)
                                             " passes a round, not " iterations)))
                              (if (= (field r 'passes) (* (+ rounds 1) iterations))
                                  '()
                                  (list (say file ": " (car pl) " " (cdr pl) " ran " (field r 'passes)
                                             " passes, not " (* (+ rounds 1) iterations))))))
                           required rs)))
             (check-counts file
                           (field-list (the results file 'yajl 'events) 'counts)
                           (field-list (the results file 'jsonparse 'events) 'counts)
                           (field-list (the results file 'jsonparse 'tree+walk) 'counts)
                           (the results file 'jsonparse 'scan))
             (apply append
                    (map (lambda (pl)
                           (check-timed file (car pl) (cdr pl) (the results file (car pl) (cdr pl))))
                         counted)))))))

  ;; The timed passes' counts, against one pass's counts times the passes.
  (define (check-timed file parser lane r)
    (let ((once (field-list r 'counts))
          (timed (let ((f (assq 'timed-counts (cdr r)))) (and f (cdr f))))
          (passes (field r 'passes)))
      (if (not timed)
          (list (say file ": " parser " " lane " has no timed counts"))
          (apply append
             (map (lambda (p)
                    (let ((want (* passes (cdr p))) (got (count timed (car p))))
                      (if (eqv? got want) '()
                          (list (say file ": " parser " " lane " timed passes counted "
                                     (car p) " " got ", not " want)))))
                  once)))))

  (define (check-counts file yajl events walk scan-result)
    (let ((scan (field-list scan-result 'counts)))
      (append
       (apply append
              (map (lambda (name)
                     (let ((a (count yajl name)) (b (count events name)))
                       (if (and a (eqv? a b)) '()
                           (list (say file ": events " name ": yajl " a ", jsonparse " b)))))
                   count-names))
       (apply append
              (map (lambda (name)
                     (let ((a (count events name)) (b (count walk name)))
                       (if (and a (eqv? a b)) '()
                           (list (say file ": tree+walk " name ": events " a ", tree+walk " b)))))
                   (filter (lambda (name) (not (eq? name 'number-bytes))) count-names)))
       (let ((a (count events 'number-bytes)) (b (count scan 'number)))
         (if (and a (eqv? a b)) '()
             (list (say file ": scan number: events " a ", scan " b))))
       (let ((total (apply + (map (lambda (name) (or (count scan name) 0))
                                  '(string number whitespace other))))
             (bytes (field scan-result 'bytes)))
         (if (= total bytes) '()
             (list (say file ": scan covers " total " bytes of " bytes)))))))

  ;; --- writing numbers -------------------------------------------------------

  ;; fixed : Real Nat -> String, X rounded to DIGITS decimals
  (define (fixed x digits)
    (let* ((scale (expt 10 digits))
           (n (round (* (exact x) scale)))
           (sign (if (< n 0) "-" ""))
           (n (abs n))
           (frac (number->string (mod n scale))))
      (string-append sign (number->string (div n scale))
                     (if (= digits 0)
                         ""
                         (string-append "." (make-string (- digits (string-length frac)) #\0) frac)))))

  ;; group-digits : Nat -> String, with a comma every three digits
  (define (group-digits n)
    (let loop ((s (number->string n)) (acc ""))
      (if (<= (string-length s) 3)
          (string-append s acc)
          (loop (substring s 0 (- (string-length s) 3))
                (string-append "," (substring s (- (string-length s) 3) (string-length s)) acc)))))

  ;; --- the report ------------------------------------------------------------

  ;; method-text : Nat Nat -> String
  (define (method-text rounds round-bytes)
    (string-append "a warm-up round, then " (number->string rounds)
                   " timed rounds of at least " (group-digits round-bytes) " bytes each"
                   (if (< rounds 9)
                       ": fewer than ADR-0013's 9, so not a measurement to record."
                       " (ADR-0013).")))

  ;; The M3 targets (plan M3, ADR-0013): the events lane's gap on two files.
  (define targets '(("records-2k.json" . 2) ("escaped-string.json" . 4)))

  ;; target-line : String Nat (Option Real) -> String
  (define (target-line file target gap)
    (string-append "- **" file ", events:** "
                   (if gap
                       (string-append (fixed gap 1) "x behind yajl; the target is "
                                      (number->string target) "x, "
                                      (if (<= gap target) "met." "not met."))
                       (string-append "not measured; the target is " (number->string target) "x."))))

  ;; report-text : (Listof (Pair Symbol String)) (Listof Runtime) (Listof Result) -> String
  ;; The report, for results that cross-check clean.
  (define (report-text machine runtimes results)
    (let* ((jp (runtime-of runtimes 'jsonparse))
           (yj (runtime-of runtimes 'yajl))
           (files (files-of results)))
      (define (m key) (cdr (assq key machine)))
      (define (get file parser lane) (the results file parser lane))
      (define (ns r) (field-list r 'round-ns))
      (define (scale r) (* (field r 'bytes) (field r 'iterations) 1000))
      (define (rates r)
        (string-append (fixed (mb/s (field r 'bytes) (field r 'iterations) (apply min (ns r))) 1)
                       " / "
                       (fixed (mb/s (field r 'bytes) (field r 'iterations) (median (ns r))) 1)))
      ;; yajl's median rate over jsonparse's, exactly.
      (define (gap file lane)
        (let ((y (get file 'yajl lane)) (j (get file 'jsonparse lane)))
          (/ (/ (scale y) (median (ns y))) (/ (scale j) (median (ns j))))))
      (define (row . cells)
        (string-append "| " (fold-left (lambda (acc c) (string-append acc " | " c)) (car cells) (cdr cells)) " |\n"))
      (define (pct part whole) (string-append (fixed (* 100 (/ part whole)) 1) "%"))
      (define (alloc r)
        (let ((input (* (length (ns r)) (field r 'iterations) (field r 'bytes))))
          (string-append (fixed (/ (field r 'allocated) input) 2) ", "
                         (pct (field r 'gc-ns) (apply + (ns r))))))
      (string-append
       "# jsonparse benchmarks\n"
       "\n"
       "- **Date (UTC):** " (m 'date) "\n"
       "- **Machine:** " (m 'cpu) ", " (m 'arch) ", " (m 'os) "\n"
       "- **jsonparse:** " (field jp 'version) " (" (field jp 'machine-type)
       "), libraries compiled ahead of time at optimize-level "
       (number->string (field jp 'optimize-level)) "\n"
       "- **yajl:** " (field yj 'version) "; its harness built by " (field yj 'compiler)
       " with " (field yj 'flags) "\n"
       "- **Pinned:** " (m 'pin) "\n"
       "- **Method:** " (method-text (field jp 'rounds) (field jp 'round-bytes))
       " Rates are MB/s, where 1 MB is 10^6 bytes: the best round, then the median."
       " A gap is yajl's median over jsonparse's.\n"
       "\n"
       "## The files\n"
       "\n"
       "What each file is made of, in bytes: inside strings (quotes and escapes included),"
       " number text, whitespace, and the rest.\n"
       "\n"
       "| File | Bytes | Strings | Numbers | Whitespace | Other |\n"
       "|:--|--:|--:|--:|--:|--:|\n"
       (apply string-append
              (map (lambda (file)
                     (let* ((r (get file 'jsonparse 'scan))
                            (c (field-list r 'counts))
                            (bytes (field r 'bytes)))
                       (row file (group-digits bytes)
                            (pct (count c 'string) bytes) (pct (count c 'number) bytes)
                            (pct (count c 'whitespace) bytes) (pct (count c 'other) bytes))))
                   files))
       "\n"
       "## jsonparse against yajl\n"
       "\n"
       "`parse` listens to nothing. `events` counts each value by kind, and the bytes"
       " of every number's and string's text.\n"
       "\n"
       "| File | parse: yajl | jsonparse | gap | events: yajl | jsonparse | gap |\n"
       "|:--|--:|--:|--:|--:|--:|--:|\n"
       (apply string-append
              (map (lambda (file)
                     (row file
                          (rates (get file 'yajl 'parse)) (rates (get file 'jsonparse 'parse))
                          (string-append (fixed (gap file 'parse) 1) "x")
                          (rates (get file 'yajl 'events)) (rates (get file 'jsonparse 'events))
                          (string-append (fixed (gap file 'events) 1) "x")))
                   files))
       "\n"
       "## The M3 targets\n"
       "\n"
       (apply string-append
              (map (lambda (t)
                     (string-append
                      (target-line (car t) (cdr t)
                                   (and (member (car t) files) (gap (car t) 'events)))
                      "\n"))
                   targets))
       "\n"
       "## jsonparse's own lanes\n"
       "\n"
       "`tree` builds the value with `bytevector->json`, and `tree+walk` then counts it"
       " as `events` does. `scan` only sorts each byte as The files does: the least a"
       " Scheme loop reading a byte at a time does.\n"
       "\n"
       "| File | tree | tree+walk | scan |\n"
       "|:--|--:|--:|--:|\n"
       (apply string-append
              (map (lambda (file)
                     (row file
                          (rates (get file 'jsonparse 'tree))
                          (rates (get file 'jsonparse 'tree+walk))
                          (rates (get file 'jsonparse 'scan))))
                   files))
       "\n"
       "## Allocation and collection\n"
       "\n"
       "Bytes allocated per input byte, and the share of the timed rounds spent collecting.\n"
       "\n"
       "| File | parse | events | tree | tree+walk | scan |\n"
       "|:--|--:|--:|--:|--:|--:|\n"
       (apply string-append
              (map (lambda (file)
                     (apply row file
                            (map (lambda (lane) (alloc (get file 'jsonparse lane)))
                                 '(parse events tree tree+walk scan))))
                   files))))))
