#!r6rs
;;; (jsonparse-bench report): checks the harnesses' results against the plan
;;; and each other, then writes them as Markdown (ADR-0013, ADR-0023,
;;; ADR-0024).
;;;
;;; The Makefile writes the plan: the rounds, the round bytes, and each
;;; parser it runs with the bytes of that parser's rounds.
;;;
;;;   (plan (rounds R) (round-bytes B) (parsers (P BYTES) ...))
;;;
;;; A harness writes a runtime form, then a result, a failure or a
;;; too-slow form per file and lane:
;;;
;;;   (runtime (parser P) ... (rounds R) (round-bytes B))
;;;   (result (file F) (bytes N) (parser P) (lane L) (iterations I)
;;;           (round-ns NS ...) (counts (NAME . COUNT) ...) (passes K)
;;;           [(timed-counts (NAME . COUNT) ...)] [(allocated BYTES) (gc-ns NS)])
;;;   (failure (file F) (parser P) (lane L) (reason "TEXT"))
;;;   (too-slow (file F) (bytes N) (parser P) (lane L) (pass-ns NS)
;;;             (limit-ns NS) (counts (NAME . COUNT) ...))
;;;
;;; jsonparse's runtime names its version, machine-type and optimize-level;
;;; yajl's its version, compiler and flags; a comparator's its version and
;;; how it ran. A result's counts are one pass's, taken outside the timing,
;;; under the names the table of parsers gives its lane; a lane that counts
;;; nothing has none. passes counts every pass the timed thunk finished,
;;; the warm-up round's included, and timed-counts sums what those passes
;;; counted, for each lane that counts. Only jsonparse gives allocated and
;;; gc-ns. A too-slow form is a lane its harness didn't time, as its first
;;; pass took longer than the harness's limit: it gives that pass's time,
;;; the limit, and what the pass counted.
;;;
;;; A comparator's lane that fails, counts otherwise than jsonparse's
;;; events, or is too slow to time gets no rate. Anything else amiss stops
;;; the report.
(library (jsonparse-bench report)
  (export read-machine read-plan cross-check voided-cells
          method-text target-line report-text
          fixed rate-text group-digits prose-list)
  (import (rnrs)
          (only (jsonparse-bench) count-names mb/s median iterations-for))

  ;; --- the parsers -------------------------------------------------------------

  ;; What a walk of a built value counts: the events lane's names but
  ;; number-bytes, which no tree keeps.
  (define walk-names (filter (lambda (name) (not (eq? name 'number-bytes))) count-names))

  ;; Each parser the report knows, in the report's order: its symbol, its
  ;; title, and each of its lanes with the names it counts, none for a lane
  ;; that counts nothing (ADR-0024 Decisions 1 and 4). SRFI 180's fold
  ;; hands over numbers converted, so its events count no number text.
  ;; chez-json reads null and [] alike, so its walk counts the two as one
  ;; name, null+array.
  (define parsers
    `((jsonparse "jsonparse" ((parse) (events ,@count-names) (tree) (tree+walk ,@walk-names)
                              (scan string number whitespace other)))
      (yajl "yajl" ((parse) (events ,@count-names)))
      (rapidjson "RapidJSON" ((parse) (events ,@count-names)))
      (jackson "Jackson" ((parse) (events ,@count-names)))
      (srfi-180 "SRFI 180" ((events ,@walk-names) (tree) (tree+walk ,@walk-names)))
      (racket "Racket" ((tree) (tree+walk ,@walk-names)))
      (guile-json "guile-json" ((tree) (tree+walk ,@walk-names)))
      (gambit "Gambit" ((tree) (tree+walk ,@walk-names)))
      (gerbil "Gerbil" ((tree) (tree+walk ,@walk-names)))
      (chibi "Chibi" ((tree) (tree+walk ,@walk-names)))
      (chez-json "chez-json"
                 ((tree) (tree+walk null+array true false number string key object text-bytes)))
      (simdjson "simdjson" ((tree) (tree+walk ,@walk-names)))
      (yyjson "yyjson" ((tree) (tree+walk ,@walk-names)))))

  ;; The parsers that hold M3's targets. Every other is a comparator.
  (define target-parsers '(jsonparse yajl))

  (define (comparator? parser) (not (memq parser target-parsers)))

  ;; Who stands beside jsonparse in each of the comparators' tables.
  (define event-peers '(yajl rapidjson jackson srfi-180))
  (define parse-peers '(yajl rapidjson jackson))
  (define tree-peers '(racket guile-json gambit gerbil chibi srfi-180 chez-json))
  (define ceilings '(simdjson yyjson))

  (define (title parser) (cadr (assq parser parsers)))

  ;; Each lane of PARSER, with the names it counts.
  (define (lanes-of parser) (caddr (assq parser parsers)))

  ;; What jsonparse's events count for NAME: null+array is null and array
  ;; together.
  (define (expected events name)
    (if (eq? name 'null+array)
        (+ (count events 'null) (count events 'array))
        (count events name)))

  ;; --- reading results ---------------------------------------------------------

  (define (field r key)
    (let ((f (assq key (cdr r))))
      (unless f (error 'report "a form lacks a field" key r))
      (cadr f)))

  (define (field-list r key)
    (let ((f (assq key (cdr r))))
      (unless f (error 'report "a form lacks a field" key r))
      (cdr f)))

  (define (failure? r) (eq? (car r) 'failure))
  (define (too-slow? r) (eq? (car r) 'too-slow))

  (define (runtime-of runtimes parser)
    (find (lambda (rt) (eq? (field rt 'parser) parser)) runtimes))

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

  ;; L without repeats, each where it first comes.
  (define (distinct l)
    (reverse (fold-left (lambda (acc x) (if (member x acc) acc (cons x acc))) '() l)))

  (define (occurrences x l) (length (filter (lambda (y) (equal? x y)) l)))

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

  ;; read-plan : String -> Any
  ;; The one datum TEXT holds, which cross-check holds to a plan's shape.
  ;; Raises unless TEXT holds exactly one.
  (define (read-plan text)
    (let* ((port (open-string-input-port text))
           (plan (get-datum port)))
      (when (eof-object? plan) (error 'read-plan "the plan's file holds no form"))
      (unless (eof-object? (get-datum port))
        (error 'read-plan "the plan's file holds more than one form"))
      plan))

  ;; --- the plan ----------------------------------------------------------------

  (define (whole? x) (and (integer? x) (exact? x)))
  (define (positive-whole? x) (and (whole? x) (> x 0)))

  ;; (KEY VALUE), VALUE passing OK?
  (define (setting? x key ok?)
    (and (list? x) (= (length x) 2) (eq? (car x) key) (ok? (cadr x))))

  (define (plan-shape? plan)
    (and (list? plan) (= (length plan) 4) (eq? (car plan) 'plan)
         (setting? (cadr plan) 'rounds positive-whole?)
         (setting? (caddr plan) 'round-bytes positive-whole?)
         (let ((ps (cadddr plan)))
           (and (list? ps) (pair? ps) (eq? (car ps) 'parsers)
                (for-all (lambda (entry)
                           (and (list? entry) (= (length entry) 2)
                                (symbol? (car entry)) (whole? (cadr entry))))
                         (cdr ps))))))

  (define (plan-rounds plan) (cadr (cadr plan)))
  (define (plan-round-bytes plan) (cadr (caddr plan)))
  (define (plan-entries plan) (cdr (cadddr plan)))
  (define (plan-names plan) (map car (plan-entries plan)))
  (define (plan-bytes plan parser) (cadr (assq parser (plan-entries plan))))

  ;; The plan's parsers, in the report's order.
  (define (planned plan)
    (filter (lambda (p) (memq p (plan-names plan))) (map car parsers)))

  ;; The plan's problems: its shape, then the parsers it names.
  (define (check-plan plan)
    (if (not (plan-shape? plan))
        (list "the plan is not (plan (rounds R) (round-bytes B) (parsers (PARSER BYTES) ...))")
        (let ((names (plan-names plan)) (b (plan-round-bytes plan)))
          (append
           (map (lambda (p) (say "the plan names no " p))
                (filter (lambda (p) (not (memq p names))) target-parsers))
           (map (lambda (p) (say "the plan names " p ", a parser the report doesn't know"))
                (distinct (filter (lambda (p) (not (assq p parsers))) names)))
           (map (lambda (p) (say "the plan names " p " " (occurrences p names) " times"))
                (distinct (filter (lambda (p) (> (occurrences p names) 1)) names)))
           (apply append
                  (map (lambda (entry)
                         (let ((p (car entry)) (n (cadr entry)))
                           (cond ((memq p target-parsers)
                                  (if (= n b) '()
                                      (list (say "the plan gives " p " rounds of " n " bytes, not " b))))
                                 ((<= 1 n b) '())
                                 (else (list (say "the plan gives " p " rounds of " n
                                                  " bytes, not 1 to " b))))))
                       (plan-entries plan)))))))

  ;; --- the cross-check ---------------------------------------------------------

  (define (show x)
    (cond ((not x) "none")
          ((number? x) (number->string x))
          ((symbol? x) (symbol->string x))
          ((string? x) x)
          (else (call-with-string-output-port (lambda (port) (write x port))))))

  (define (say . parts) (apply string-append (map show parts)))

  ;; cross-check : (Listof String) Any (Listof Runtime)
  ;;               (Listof (U Result Failure Too-Slow)) -> (Listof String)
  ;; What makes the results unfit to report, or '(). First the plan: its
  ;; shape; jsonparse and yajl, at its round bytes; every other parser
  ;; known, named once, and at 1 to its round bytes. If the plan is sound:
  ;; one runtime for each parser it names and none other, with its rounds
  ;; and that parser's round bytes; results, failures and too-slow forms
  ;; of its parsers alone, for exactly FILES, the lock's; for each file,
  ;; one of them for every lane of each parser, and for no other lane; no
  ;; failure or too-slow form of jsonparse's or yajl's; each too-slow form
  ;; with the size jsonparse's scan read, a whole pass past a whole limit,
  ;; and its lane's names counted; every result with the plan's rounds,
  ;; the size jsonparse's scan read, iterations-for's passes a round for its
  ;; parser's round bytes, and that many in every round, the warm-up's
  ;; included; each counting lane counting its names once each, and its
  ;; timed passes one pass's counts times the passes; each other lane
  ;; counting nothing; yajl's events counts equal to jsonparse's; the
  ;; walk's equal to the events'; and the scan covering the file, with the
  ;; events' number bytes. A comparator's counts may disagree with
  ;; jsonparse's, it may fail, and it may be too slow to time: voided-cells
  ;; says where.
  (define (cross-check files plan runtimes results)
    (let ((problems (check-plan plan)))
      (if (pair? problems)
          problems
          (append (check-runtimes plan runtimes)
                  (check-results files plan results)))))

  (define (check-runtimes plan runtimes)
    (let ((names (plan-names plan)) (rounds (plan-rounds plan)))
      (append
       (apply append
              (map (lambda (p)
                     (let ((rts (filter (lambda (rt) (eq? (field rt 'parser) p)) runtimes))
                           (b (plan-bytes plan p)))
                       (cond ((null? rts) (list (say "no " p " runtime")))
                             ((pair? (cdr rts)) (list (say p " has " (length rts) " runtimes")))
                             ((and (eqv? (field (car rts) 'rounds) rounds)
                                   (eqv? (field (car rts) 'round-bytes) b))
                              '())
                             (else (list (say p " ran " (field (car rts) 'rounds) " rounds of "
                                              (field (car rts) 'round-bytes) " bytes; the plan says "
                                              rounds " of " b))))))
                   names))
       (map (lambda (p) (say p " has a runtime, but the plan doesn't name it"))
            (distinct (filter (lambda (p) (not (memq p names)))
                              (map (lambda (rt) (field rt 'parser)) runtimes)))))))

  (define (check-results files plan results)
    (let ((names (plan-names plan)) (named (files-of results)))
      (append
       (map (lambda (p) (say p " has results, but the plan doesn't name it"))
            (distinct (filter (lambda (p) (not (memq p names)))
                              (map (lambda (r) (field r 'parser)) results))))
       (map (lambda (file) (say file ": no results"))
            (filter (lambda (file) (not (member file named))) files))
       (map (lambda (file) (say file ": not in the lock"))
            (filter (lambda (file) (not (member file files))) named))
       (apply append (map (lambda (file) (check-file plan results file)) named)))))

  ;; Every lane of each parser the plan names, as (PARSER LANE NAME ...),
  ;; in the report's order.
  (define (cells-of plan)
    (apply append
           (map (lambda (p) (map (lambda (lane) (cons p lane)) (lanes-of p)))
                (planned plan))))

  ;; FILE's problems: first what is missing, doubled, stray, or failed or
  ;; too slow in a target, and only if nothing is, each result and the
  ;; counts.
  (define (check-file plan results file)
    (let* ((here (filter (lambda (r) (and (equal? (field r 'file) file)
                                          (memq (field r 'parser) (plan-names plan))))
                         results))
           (cells (cells-of plan))
           (presence
            (apply append
                   (map (lambda (cell)
                          (let ((n (length (results-of here file (car cell) (cadr cell)))))
                            (cond ((= n 0) (list (say file ": no " (car cell) " " (cadr cell) " result")))
                                  ((> n 1) (list (say file ": " (car cell) " " (cadr cell) " given twice")))
                                  (else '()))))
                        cells)))
           (strays
            (map (lambda (pl) (say file ": " (car pl) " has no " (cdr pl) " lane"))
                 (distinct (filter (lambda (pl)
                                     (not (exists (lambda (cell) (and (eq? (car cell) (car pl))
                                                                      (eq? (cadr cell) (cdr pl))))
                                                  cells)))
                                   (map (lambda (r) (cons (field r 'parser) (field r 'lane))) here)))))
           (failed
            (map (lambda (f) (say file ": " (field f 'parser) " " (field f 'lane) " fails: " (field f 'reason)))
                 (filter (lambda (r) (and (failure? r) (memq (field r 'parser) target-parsers))) here)))
           (slow
            (map (lambda (f) (say file ": " (field f 'parser) " " (field f 'lane) " was too slow to time"))
                 (filter (lambda (r) (and (too-slow? r) (memq (field r 'parser) target-parsers))) here)))
           (problems (append presence strays failed slow)))
      (if (pair? problems)
          problems
          (let ((size (field (the here file 'jsonparse 'scan) 'bytes))
                (rounds (plan-rounds plan)))
            (append
             (apply append
                    (map (lambda (cell)
                           (let ((r (the here file (car cell) (cadr cell))))
                             (cond ((failure? r) '())
                                   ((too-slow? r) (check-too-slow file r (car cell) (cadr cell) (cddr cell) size))
                                   (else (check-result file r (car cell) (cadr cell) (cddr cell)
                                                       rounds size (plan-bytes plan (car cell)))))))
                         cells))
             (check-counts file
                           (field-list (the here file 'yajl 'events) 'counts)
                           (field-list (the here file 'jsonparse 'events) 'counts)
                           (field-list (the here file 'jsonparse 'tree+walk) 'counts)
                           (the here file 'jsonparse 'scan)))))))

  ;; One result's problems: its rounds, size and passes, then its counts.
  (define (check-result file r parser lane names rounds size round-bytes)
    (let ((iterations (iterations-for size round-bytes))
          (k (length (field-list r 'round-ns))))
      (define (problem . parts) (list (apply say file ": " parser " " lane " " parts)))
      (append
       (if (= k rounds) '() (problem "has " k " rounds, not " rounds))
       (let ((bad (find (lambda (ns) (not (positive-whole? ns))) (field-list r 'round-ns))))
         (if bad (problem "has a round of " bad " ns, not a positive whole number") '()))
       (if (eqv? (field r 'bytes) size) '() (problem "read " (field r 'bytes) " bytes, not " size))
       (if (eqv? (field r 'iterations) iterations)
           '()
           (problem "ran " (field r 'iterations) " passes a round, not " iterations))
       (if (eqv? (field r 'passes) (* (+ rounds 1) iterations))
           '()
           (problem "ran " (field r 'passes) " passes, not " (* (+ rounds 1) iterations)))
       (check-tally r names problem))))

  ;; The method's limit on a lane's first pass, past which its harness
  ;; times it no more (ADR-0024).
  (define pass-limit-ns 10000000000)

  ;; A too-slow form's problems: its size, its limit the method's, its pass
  ;; past it, and the names it counted, as a result's.
  (define (check-too-slow file r parser lane names size)
    (let ((pass (field r 'pass-ns)) (limit (field r 'limit-ns)))
      (define (problem . parts) (list (apply say file ": " parser " " lane " " parts)))
      (append
       (if (eqv? (field r 'bytes) size) '() (problem "read " (field r 'bytes) " bytes, not " size))
       (if (eqv? limit pass-limit-ns)
           '()
           (problem "had a limit of " limit " ns, not the method's " pass-limit-ns " ns"))
       (if (and (positive-whole? pass) (> pass pass-limit-ns))
           '()
           (problem "took " pass " ns a pass, not past the method's limit of " pass-limit-ns " ns"))
       (let ((counts (field-list r 'counts)))
         (cond ((null? names)
                (if (null? counts) '() (problem "has counts, for a lane that counts nothing")))
               ((names? counts names) '())
               (else (problem "counts " (names-text counts) ", not " (names-text names))))))))

  ;; A counting lane names NAMES once each in its counts and its timed
  ;; counts, and its timed passes counted one pass's counts times the
  ;; passes. Any other lane counts nothing.
  (define (check-tally r names problem)
    (let ((counts (field-list r 'counts))
          (timed (let ((f (assq 'timed-counts (cdr r)))) (and f (cdr f)))))
      (if (null? names)
          (append (if (null? counts) '() (problem "has counts, for a lane that counts nothing"))
                  (if timed (problem "has timed counts, for a lane that counts nothing") '()))
          (let ((counts-named (names? counts names))
                (timed-named (and timed (names? timed names))))
            (append
             (if counts-named '() (problem "counts " (names-text counts) ", not " (names-text names)))
             (cond ((not timed) (problem "has no timed counts"))
                   ((not timed-named)
                    (problem "timed counts " (names-text timed) ", not " (names-text names)))
                   (else '()))
             (if (and counts-named timed-named)
                 (let ((passes (field r 'passes)))
                   (apply append
                          (map (lambda (name)
                                 (let ((want (* passes (count counts name))) (got (count timed name)))
                                   (if (eqv? got want)
                                       '()
                                       (problem "timed passes counted " name " " got ", not " want))))
                               names)))
                 '()))))))

  ;; Whether ALIST names exactly NAMES, once each: as many entries as
  ;; names, and every name among them.
  (define (names? alist names)
    (and (= (length alist) (length names))
         (for-all (lambda (name) (assq name alist)) names)))

  (define (names-text alist-or-names)
    (show (map (lambda (x) (if (pair? x) (car x) x)) alist-or-names)))

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
                   walk-names))
       (let ((a (count events 'number-bytes)) (b (count scan 'number)))
         (if (and a (eqv? a b)) '()
             (list (say file ": scan number: events " a ", scan " b))))
       (let ((total (apply + (map (lambda (name) (or (count scan name) 0))
                                  '(string number whitespace other))))
             (bytes (field scan-result 'bytes)))
         (if (= total bytes) '()
             (list (say file ": scan covers " total " bytes of " bytes)))))))

  ;; --- the voided cells --------------------------------------------------------

  ;; voided-cells : (Listof (U Result Failure Too-Slow))
  ;;                -> (Listof (List String Symbol Symbol (U 'fails 'disagrees 'too-slow) String))
  ;; Each comparator's lane that gets no rate, by file, then in the report's
  ;; order of parsers and lanes: its file, parser and lane, then fails and
  ;; the harness's reason; disagrees and each name the lane counts
  ;; otherwise than jsonparse's events, with both counts, too slow or not;
  ;; or too-slow and its pass's time and rate, and the limit. A lane that
  ;; counts nothing is checked only by the lane that counts what the same
  ;; parser read: the walk is the only check of the value a tree builder
  ;; built, and events of what parse read. So a tree or parse that didn't
  ;; fail itself follows its tree+walk or events on the same file when that
  ;; fails or disagrees, saying so. A lane too slow to time still counted,
  ;; so it leaves the other alone. For results that cross-check clean.
  (define (voided-cells results)
    (apply append
           (map (lambda (file)
                  (let ((events (field-list (the results file 'jsonparse 'events) 'counts)))
                    (apply append
                           (map (lambda (p)
                                  (let ((voids (lane-voids results events file p)))
                                    (define (void-of lane) (find (lambda (v) (eq? (caddr v) lane)) voids))
                                    (apply append
                                           (map (lambda (lane)
                                                  (let* ((void (void-of (car lane)))
                                                         (checker (assq (car lane) checked-by))
                                                         (check (and checker (void-of (cdr checker)))))
                                                    (cond ((and check (memq (cadddr check) '(fails disagrees))
                                                                (not (and void (eq? (cadddr void) 'fails))))
                                                           (list (list file p (car lane) (cadddr check)
                                                                       (say "its " (cdr checker) " " (cadddr check)))))
                                                          (void (list void))
                                                          (else '()))))
                                                (lanes-of p)))))
                                (filter comparator? (map car parsers))))))
                (files-of results))))

;; Each lane that counts nothing, and the lane that checks what it read.
  (define checked-by '((tree . tree+walk) (parse . events)))

  ;; PARSER's lanes on FILE that fail, count otherwise than EVENTS,
  ;; jsonparse's events there, or were too slow to time.
  (define (lane-voids results events file parser)
    (apply append
           (map (lambda (lane)
                  (let ((rs (results-of results file parser (car lane))))
                    (cond ((null? rs) '())
                          ((failure? (car rs))
                           (list (list file parser (car lane) 'fails (field (car rs) 'reason))))
                          (else
                           (let ((wrong (disagreement file parser lane (car rs) events)))
                             (if (and (null? wrong) (too-slow? (car rs)))
                                 (list (list file parser (car lane) 'too-slow (slow-reason (car rs))))
                                 wrong))))))
                (lanes-of parser))))

  ;; Why a lane too slow to time has no rate: its one pass's time and rate,
  ;; and the limit.
  (define (slow-reason r)
    (let ((pass (field r 'pass-ns)) (limit (field r 'limit-ns)))
      (string-append "one pass took " (fixed (/ pass 1000000000) 1) " s, "
                     (rate-text (mb/s (field r 'bytes) 1 pass)) " MB/s; the limit is "
                     (fixed (/ limit 1000000000) 1) " s")))

  (define (disagreement file parser lane r events)
    (let* ((counts (field-list r 'counts))
           (wrong (filter (lambda (name) (not (eqv? (count counts name) (expected events name))))
                          (cdr lane))))
      (if (null? wrong)
          '()
          (list (list file parser (car lane) 'disagrees
                      (join "; " (map (lambda (name)
                                        (say name " " (count counts name)
                                             ", jsonparse " (expected events name)))
                                      wrong)))))))

  ;; --- writing numbers and words -----------------------------------------------

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

  ;; rate-text : Real -> String
  ;; A rate in MB/s, to one decimal, or below 1 MB/s to as many as show two
  ;; significant digits: 0.079, not 0.1. Zero, which no rate is, gets one.
  (define (rate-text x)
    (let loop ((digits 1))
      (if (or (<= x 0) (>= (round (* (exact x) (expt 10 digits))) 10))
          (fixed x digits)
          (loop (+ digits 1)))))

  ;; group-digits : Nat -> String, with a comma every three digits
  (define (group-digits n)
    (let loop ((s (number->string n)) (acc ""))
      (if (<= (string-length s) 3)
          (string-append s acc)
          (loop (substring s 0 (- (string-length s) 3))
                (string-append "," (substring s (- (string-length s) 3) (string-length s)) acc)))))

  ;; prose-list : (Listof String) -> String
  ;; The strings as a sentence lists them: "A", "A and B", "A, B, and C".
  (define (prose-list l)
    (cond ((null? l) "")
          ((null? (cdr l)) (car l))
          ((null? (cddr l)) (string-append (car l) " and " (cadr l)))
          (else (string-append (join ", " (reverse (cdr (reverse l))))
                               ", and " (car (reverse l))))))

  (define (join sep l)
    (if (null? l)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car l) (cdr l))))

  ;; S with each line break and tab a space, to fit on a line of Markdown.
  (define (one-line s)
    (list->string (map (lambda (c) (if (memv c '(#\newline #\return #\tab)) #\space c))
                       (string->list s))))

  ;; --- the report --------------------------------------------------------------

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

  ;; What a cell with no rate reads.
  (define (void-text kind) (if (eq? kind 'too-slow) "too slow" (symbol->string kind)))

  ;; report-text : (Listof (Pair Symbol String)) Plan (Listof Runtime)
  ;;               (Listof (U Result Failure Too-Slow)) -> String
  ;; The report, for results that cross-check clean against PLAN. Each
  ;; comparators' section shows only when the plan names a parser of its
  ;; kind, and only the plan's parsers' columns.
  (define (report-text machine plan runtimes results)
    (let* ((jp (runtime-of runtimes 'jsonparse))
           (yj (runtime-of runtimes 'yajl))
           (files (files-of results))
           (in (planned plan))
           (voids (voided-cells results)))
      (define (m key) (cdr (assq key machine)))
      (define (get file parser lane) (the results file parser lane))
      (define (ns r) (field-list r 'round-ns))
      (define (scale r) (* (field r 'bytes) (field r 'iterations) 1000))
      (define (rate r t) (rate-text (mb/s (field r 'bytes) (field r 'iterations) t)))
      (define (rates r)
        (string-append (rate r (apply min (ns r))) " / " (rate r (median (ns r)))))
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
      ;; The median, or why the cell has none.
      (define (median-cell file parser lane)
        (let ((void (find (lambda (v) (and (equal? (car v) file) (eq? (cadr v) parser)
                                           (eq? (caddr v) lane)))
                          voids)))
          (if void
              (void-text (cadddr void))
              (let ((r (get file parser lane))) (rate r (median (ns r)))))))
      ;; A table of medians: for each of LANES, a column for each of PARSERS.
      (define (medians lanes columns)
        (string-append
         (apply row "File"
                (apply append
                       (map (lambda (lane)
                              (cons (string-append (symbol->string lane) ": " (title (car columns)))
                                    (map title (cdr columns))))
                            lanes)))
         "|:--" (apply string-append (map (lambda (x) "|--:") (apply append (map (lambda (lane) columns) lanes))))
         "|\n"
         (apply string-append
                (map (lambda (file)
                       (apply row file
                              (apply append
                                     (map (lambda (lane) (map (lambda (p) (median-cell file p lane)) columns))
                                          lanes))))
                     files))))
      (define (among peers) (filter (lambda (p) (memq p in)) peers))
      (define smaller
        (filter (lambda (p) (< (plan-bytes plan p) (plan-round-bytes plan))) in))
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
       (apply string-append
              (map (lambda (p)
                     (let ((rt (runtime-of runtimes p)))
                       (say "- **" (title p) ":** " (field rt 'version) "; " (field rt 'how) "\n")))
                   (filter comparator? in)))
       "- **Pinned:** " (m 'pin) "\n"
       "- **Method:** " (method-text (plan-rounds plan) (plan-round-bytes plan))
       (if (null? smaller)
           ""
           (string-append " Slow comparators read smaller rounds: "
                          (prose-list (map (lambda (p)
                                             (string-append (title p) " " (group-digits (plan-bytes plan p))
                                                            " bytes"))
                                           smaller))
                          "."))
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
       " as `events` does. `scan` only sorts each byte, as the table of files does: the least a"
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
                   files))
       (if (exists comparator? (among event-peers))
           (string-append
            "\n"
            "## Event parsers\n"
            "\n"
            "Parsers that hand over each value as they read it: each one's median rate, in MB/s.\n"
            "\n"
            (medians '(events) (cons 'jsonparse (among event-peers)))
            (if (exists comparator? (among parse-peers))
                (string-append "\n" (medians '(parse) (cons 'jsonparse (among parse-peers))))
                ""))
           "")
       (if (null? (among tree-peers))
           ""
           (string-append
            "\n"
            "## Tree builders\n"
            "\n"
            "Parsers that build the whole value: each one's median rate, in MB/s."
            " `tree+walk` then counts the value as `events` does.\n"
            "\n"
            (medians '(tree) (cons 'jsonparse (among tree-peers)))
            "\n"
            (medians '(tree+walk) (cons 'jsonparse (among tree-peers)))))
       (if (null? (among ceilings))
           ""
           (string-append
            "\n"
            "## Ceilings\n"
            "\n"
            "Parsers built for speed in C and C++: a ceiling, not a target."
            " Each one's median rate, in MB/s.\n"
            "\n"
            (medians '(tree tree+walk) (cons 'jsonparse (among ceilings)))))
       (if (null? voids)
           ""
           (string-append
            "\n"
            "## Cells with no rate\n"
            "\n"
            "A comparator's lane has no rate when it rejected the file (`fails`), counted"
            " other values than jsonparse's `events` (`disagrees`), or its first pass ran"
            " past its harness's time limit (`too slow`).\n"
            "\n"
            (apply string-append
                   (map (lambda (v)
                          (say "- **" (car v) ", " (title (cadr v)) ", " (caddr v) ":** "
                               (void-text (cadddr v)) ": " (one-line (show (list-ref v 4))) "\n"))
                        voids))))))))
