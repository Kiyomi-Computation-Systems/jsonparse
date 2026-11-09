#!r6rs
;;; (jsonparse-bench callbacks): where the callback path's time goes
;;; (ADR-0025), for bench/callbacks.sps and `make bench-callbacks`.
;;;
;;; Eight lanes, each making a new parser a pass, as the events lane does:
;;;
;;;   parse     jsonparse with a handler of no procedures: byte-machine's
;;;             callbacks are bound for the stack alone
;;;   m-events  byte-machine's own parser on jsonparse-machine, with the
;;;             stack's callbacks, and the counted callbacks that carry no
;;;             bytes bound to procedures that do nothing
;;;   m-spans   the same, with the two that carry bytes instead
;;;   m-noop    the same, with every counted callback
;;;   m-count   the same, each counting as the events lane does
;;;   m-all     the same as m-noop, with string-start and key-start too:
;;;             every callback jsonparse can bind
;;;   j-noop    jsonparse with all fourteen procedures doing nothing
;;;   events    jsonparse with the events lane's counting handler
;;;
;;; The counted callbacks are the ones (jsonparse parser) binds for the
;;; events lane's counting handler, beside the stack's. That list is kept in
;;; step with parser.sls by hand. The m- lanes keep their stack as
;;; jsonparse does and hand the caller's context to every callback as it
;;; does. So m-noop less parse is byte-machine delivering the counted
;;; callbacks to procedures, m-count less m-noop is the counting, and events
;;; less m-count is jsonparse's binding around the same counting. A pass's
;;; set-up differs between lanes, by a constant: under 0.5 microseconds.
;;;
;;; A no-op escape still reads the escaped code unit, as any procedure
;;; bound to escape must.
(library (jsonparse-bench callbacks)
  (export callback-lanes counted-names machine-bound json-bound
          machine-counts machine-calls value-count
          callback-lane-thunk check-tally measure-interleaved
          callback-split callbacks-text)
  (import (rnrs)
          (only (chezscheme) collect collect-maximum-generation current-time time-difference)
          (byte-machine runtime)
          (generated jsonparse)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse-bench)
          (only (jsonparse-bench report) fixed group-digits))

  ;; callback-lanes : (Listof Symbol), in the report's order
  (define callback-lanes '(parse m-events m-spans m-noop m-count m-all j-noop events))

  (define counting-lanes '(m-count events))

  ;; counted-names : (Listof Symbol)
  ;; byte-machine's callbacks that (jsonparse parser) binds for the events
  ;; lane's counting handler, beside the stack's, in the order it binds them.
  (define counted-names
    '(null true false number-data number-end chars-data escape string-end key-end))

  (define byte-names '(number-data chars-data))
  (define uncounted-names '(string-start key-start))

  ;; --- the machine, bound directly ----------------------------------------------

  ;; The stack, as (jsonparse parser) keeps it, and a surrogate's high half.
  (define-record-type mstate
    (fields (immutable stack) (mutable depth) (mutable high)))

  (define depth-limit (json-options-depth-limit (make-json-options)))

  (define (push! s entry)
    (bytevector-u8-set! (mstate-stack s) (mstate-depth s) entry)
    (mstate-depth-set! s (fx+ (mstate-depth s) 1)))

  (define (pop! s) (mstate-depth-set! s (fx- (mstate-depth s) 1)))

  (define (add! v k n) (vector-set! v k (fx+ (vector-ref v k) n)))

  (define (stack-bindings s count?)
    (list (list 'object-start
                (if count?
                    (lambda (p u) (push! s 0) (add! u 6 1) callback-continue)
                    (lambda (p u) (push! s 0) callback-continue)))
          (list 'object-end (lambda (p u) (pop! s) callback-continue))
          (list 'array-start
                (if count?
                    (lambda (p u) (push! s 1) (add! u 7 1) callback-continue)
                    (lambda (p u) (push! s 1) callback-continue)))
          (list 'array-end (lambda (p u) (pop! s) callback-continue))
          (list 'context
                (lambda (p u)
                  (if (fx=? (bytevector-u8-ref (mstate-stack s) (fx- (mstate-depth s) 1)) 0)
                      'object
                      'array)))))

  (define (noop name)
    (case name
      ((number-data chars-data) (lambda (p u bv start end) callback-continue))
      ((escape) (lambda (p u) (parser-field-ref p 'cp) callback-continue))
      (else (lambda (p u) callback-continue))))

  ;; The counting handler's work, in byte-machine's shapes. The context is
  ;; a vector from make-counts.
  (define (counting name s)
    (case name
      ((null) (lambda (p u) (add! u 0 1) callback-continue))
      ((true) (lambda (p u) (add! u 1 1) callback-continue))
      ((false) (lambda (p u) (add! u 2 1) callback-continue))
      ((number-data) (lambda (p u bv start end) (add! u 8 (fx- end start)) callback-continue))
      ((number-end) (lambda (p u) (add! u 3 1) callback-continue))
      ((chars-data) (lambda (p u bv start end) (add! u 9 (fx- end start)) callback-continue))
      ;; The machine has checked that a high half is followed by a low half.
      ((escape)
       (lambda (p u)
         (let ((unit (parser-field-ref p 'cp)))
           (cond ((fx<=? #xD800 unit #xDBFF) (mstate-high-set! s unit))
                 ((fx<=? #xDC00 unit #xDFFF) (add! u 9 4))
                 (else (add! u 9 (utf8-length/scalar unit)))))
         callback-continue))
      ((string-end) (lambda (p u) (add! u 4 1) callback-continue))
      ((key-end) (lambda (p u) (add! u 5 1) callback-continue))))

  ;; Each counted callback adds one to the context's first slot.
  (define (calling name)
    (if (memq name byte-names)
        (lambda (p u bv start end) (add! u 0 1) callback-continue)
        (lambda (p u) (add! u 0 1) callback-continue)))

  (define (bound names make)
    (map (lambda (n) (list n (make n))) names))

  (define (without names gone) (filter (lambda (n) (not (memq n gone))) names))
  (define (keep names kept) (filter (lambda (n) (memq n kept)) names))

  (define (machine-bindings who lane s)
    (case lane
      ((m-events) (append (stack-bindings s #f) (bound (without counted-names byte-names) noop)))
      ((m-spans) (append (stack-bindings s #f) (bound (keep counted-names byte-names) noop)))
      ((m-noop) (append (stack-bindings s #f) (bound counted-names noop)))
      ((m-count) (append (stack-bindings s #t) (bound counted-names (lambda (n) (counting n s)))))
      ((m-all) (append (stack-bindings s #f) (bound (append counted-names uncounted-names) noop)))
      ((m-calls) (append (stack-bindings s #f) (bound counted-names calling)))
      (else (assertion-violation who "not one of the machine's lanes" lane))))

  ;; machine-bound : Symbol -> (Listof Symbol)
  ;; The callbacks the m- lane LANE binds, in the order it binds them.
  ;; Raises for any other lane.
  (define (machine-bound lane)
    (unless (memq lane callback-lanes)
      (assertion-violation 'machine-bound "not one of the machine's lanes" lane))
    (map car (machine-bindings 'machine-bound lane (make-mstate (make-bytevector 1 0) 0 0))))

  (define overrides (list (cons 'depth-left depth-limit) (cons 'mode 0)))

  ;; One pass of the machine's lane LANE over BV, with the context COUNTS.
  (define (machine-pass who lane counts bv)
    (let* ((s (make-mstate (make-bytevector depth-limit 0) 0 0))
           (p (make-parser jsonparse-machine (machine-bindings who lane s) counts overrides)))
      (parser-feed! p bv 0 (bytevector-length bv))
      (let ((r (parser-finish! p)))
        (unless (eq? (parser-result-status r) 'finished)
          (error who "the parse did not finish" lane (parser-result-status r))))))

  ;; machine-counts : Bytevector -> (Listof (Pair Symbol Fixnum))
  ;; m-count's counts for BV, parsed whole, as events-counts gives them.
  ;; Raises unless BV is one JSON document.
  (define (machine-counts bv)
    (let ((counts (make-counts)))
      (machine-pass 'machine-counts 'm-count counts bv)
      (counts->alist counts)))

  ;; machine-calls : Bytevector -> Nat
  ;; How many times byte-machine calls the counted callbacks in a pass over
  ;; BV, parsed whole: what m-noop delivers and parse doesn't. Raises unless
  ;; BV is one JSON document.
  (define (machine-calls bv)
    (let ((counts (make-counts)))
      (machine-pass 'machine-calls 'm-calls counts bv)
      (vector-ref counts 0)))

  ;; value-count : (Listof (Pair Symbol Nat)) -> Nat
  ;; The values among COUNTS, keys included: all but the two byte counts.
  (define (value-count counts)
    (fold-left (lambda (n c) (if (memq (car c) '(number-bytes text-bytes)) n (+ n (cdr c))))
               0 counts))

  ;; --- jsonparse --------------------------------------------------------------------

  (define handler-names
    '(null boolean number-chars number-end string-start chars escape string-end
      object-start key-start key-end object-end array-start array-end))

  ;; json-bound : Symbol -> (Listof Symbol)
  ;; The procedures the parse or j-noop lane's handler has, in the order it
  ;; is made with them. Raises for any other lane.
  (define (json-bound lane)
    (case lane
      ((parse) '())
      ((j-noop) handler-names)
      (else (assertion-violation 'json-bound "not parse or j-noop" lane))))

  (define (noop-procedure name)
    (case name
      ((number-chars chars) (lambda (c bv start end) #f))
      ((boolean escape) (lambda (c x) #f))
      (else (lambda (c) #f))))

  (define (handler-for lane)
    (apply make-json-handler
           (apply append (map (lambda (n) (list n (noop-procedure n))) (json-bound lane)))))

  (define empty-handler (handler-for 'parse))
  (define noop-handler (handler-for 'j-noop))

  (define (json-pass who lane handler counts bv)
    (let ((p (make-json-parser handler counts)))
      (json-parser-feed! p bv)
      (let ((r (json-parser-finish! p)))
        (unless (eq? (json-result-status r) 'finished)
          (error who "the parse did not finish" lane (json-result-status r))))))

  ;; --- the lanes ----------------------------------------------------------------------

  ;; callback-lane-thunk : Symbol Bytevector
  ;;                       -> (Values (-> Any) (-> (Pair Nat (Listof (Pair Symbol Nat)))))
  ;; A thunk running LANE once on BV, and a tally: the passes the thunk has
  ;; finished, and, for m-count and events, what they counted, summed. Each
  ;; pass raises unless BV is one JSON document.
  (define (callback-lane-thunk lane bv)
    (define who 'callback-lane-thunk)
    (unless (memq lane callback-lanes)
      (assertion-violation who "not a lane" lane))
    (let ((passes 0) (counts (make-counts)))
      (define (pass)
        (case lane
          ((parse) (json-pass who lane empty-handler #f bv))
          ((j-noop) (json-pass who lane noop-handler #f bv))
          ((events) (json-pass who lane counting-handler counts bv))
          (else (machine-pass who lane counts bv))))
      (values (lambda () (pass) (set! passes (+ passes 1)))
              (lambda ()
                (cons passes (if (memq lane counting-lanes) (counts->alist counts) '()))))))

  ;; check-tally : Symbol (Listof (Pair Symbol Nat)) Nat (Pair Nat (Listof (Pair Symbol Nat))) -> 'ok
  ;; 'ok when TALLY, LANE's after its passes, shows PASSES passes and, for a
  ;; counting lane, COUNTS times PASSES; a lane that counts nothing must show
  ;; no counts. Raises otherwise.
  (define (check-tally lane counts passes tally)
    (define (scaled n) (map (lambda (c) (cons (car c) (* n (cdr c)))) counts))
    (unless (eqv? (car tally) passes)
      (assertion-violation 'check-tally "the lane ran other passes than the method's" lane (car tally) passes))
    (unless (equal? (cdr tally) (if (memq lane counting-lanes) (scaled passes) '()))
      (assertion-violation 'check-tally "the lane counted other than its passes' counts" lane (cdr tally)))
    'ok)

  ;; measure-interleaved : (Listof (-> Any)) Nat Nat -> (Listof (Listof Nat))
  ;; ADR-0023's method, the lanes taking turns: each thunk runs ITERATIONS
  ;; times a round, a warm-up round of each first, then ROUNDS turns in which
  ;; each has one timed round. Turn K starts at thunk K, modulo their number,
  ;; so no thunk always runs first or after the same one. A full collection
  ;; precedes every round, outside its time. Returns each thunk's timed
  ;; rounds' nanoseconds, in turn order.
  (define (measure-interleaved thunks iterations rounds)
    (define n (length thunks))
    (define tv (list->vector thunks))
    (define (round! i)
      (let ((thunk (vector-ref tv i)))
        (collect (collect-maximum-generation))
        (let ((t0 (current-time 'time-monotonic)))
          (do ((k 0 (fx+ k 1))) ((fx=? k iterations)) (thunk))
          (duration->ns (time-difference (current-time 'time-monotonic) t0)))))
    (do ((i 0 (+ i 1))) ((= i n)) (round! i))
    (let ((times (make-vector n '())))
      (do ((turn 0 (+ turn 1))) ((= turn rounds))
        (do ((j 0 (+ j 1))) ((= j n))
          (let ((i (mod (+ turn j) n)))
            (vector-set! times i (cons (round! i) (vector-ref times i))))))
      (map reverse (vector->list times))))

  ;; --- the split ----------------------------------------------------------------------

  (define splits
    '((byte-machine m-noop parse) (its-events m-events parse) (its-spans m-spans parse)
      (counting m-count m-noop) (jsonparse events m-count) (jsonparse-all j-noop m-all)
      (all events parse)))

  ;; callback-split : Nat (Listof (Pair Symbol (Listof Real))) -> (Listof (List Symbol Real Real Real))
  ;; From VALUE-N, a file's value count, and each lane's nanoseconds a pass
  ;; round by round, the rounds paired by turn: each split's nanoseconds a
  ;; value, as the median of its turns' differences, then the least and the
  ;; most of the middle half of them. The splits: byte-machine (m-noop less
  ;; parse), its-events (m-events less parse), its-spans (m-spans less
  ;; parse), counting (m-count less m-noop), jsonparse (events less
  ;; m-count), jsonparse-all (j-noop less m-all) and all (events less parse).
  ;; Raises when a lane is missing, or two have different numbers of rounds.
  (define (callback-split value-n rounds)
    (define (r lane)
      (let ((x (assq lane rounds)))
        (unless x (assertion-violation 'callback-split "no rounds for a lane" lane))
        (cdr x)))
    (map (lambda (s)
           (let ((a (r (cadr s))) (b (r (caddr s))))
             (unless (= (length a) (length b))
               (assertion-violation 'callback-split "lanes of different rounds" (cadr s) (caddr s)))
             (let* ((d (list-sort < (map (lambda (x y) (/ (- x y) value-n)) a b)))
                    (q (div (length d) 4)))
               (list (car s) (median d) (list-ref d q) (list-ref d (- (length d) 1 q))))))
         splits))

  ;; The fewest values a file needs for its split to be shown.
  (define split-floor 1000)

  ;; callbacks-text : (Listof (Pair Symbol String)) String Nat Nat
  ;;                  (Listof (List String Nat Nat Nat (Listof (Pair Symbol (Listof Real))))) -> String
  ;; The report: MACHINE as (jsonparse-bench report)'s read-machine gives it,
  ;; RUNTIME naming jsonparse's Chez, the method's ROUNDS and ROUND-BYTES,
  ;; and a row per file: its name, bytes, values, machine-calls, and each
  ;; lane's nanoseconds a pass, round by round.
  (define (callbacks-text machine runtime rounds round-bytes rows)
    (define (m key) (cdr (assq key machine)))
    (define (cells xs) (apply string-append (map (lambda (x) (string-append " " x " |")) xs)))
    (define (row-name row) (list-ref row 0))
    (define (row-values row) (list-ref row 2))
    (define (row-rounds row) (list-ref row 4))
    (define (lane-row row)
      (string-append "| " (row-name row) " | " (group-digits (list-ref row 1))
                     " | " (group-digits (row-values row)) " |"
                     (cells (map (lambda (lane) (fixed (/ (median (cdr (assq lane (row-rounds row)))) 1000) 1))
                                 callback-lanes))
                     "\n"))
    (define (split-row row)
      (string-append
       "| " (row-name row) " |"
       (if (< (row-values row) split-floor)
           (cells (map (lambda (x) "-") (cons 'calls splits)))
           (cells (cons (fixed (/ (list-ref row 3) (row-values row)) 1)
                        (map (lambda (x)
                               (string-append (fixed (cadr x) 1)
                                              " [" (fixed (caddr x) 1) ", " (fixed (cadddr x) 1) "]"))
                             (callback-split (row-values row) (row-rounds row))))))
       "\n"))
    (string-append
     "# jsonparse's callback path\n"
     "\n"
     "- **Date (UTC):** " (m 'date) "\n"
     "- **Machine:** " (m 'cpu) ", " (m 'arch) ", " (m 'os) "\n"
     "- **Pinned:** " (m 'pin) "\n"
     "- **jsonparse:** " runtime "\n"
     "- **Method:** a warm-up round of each lane, then " (number->string rounds)
     " turns in which each lane has a timed round of at least " (group-digits round-bytes)
     " bytes, a new parser a pass (ADR-0023, ADR-0025). Each turn starts one lane later.\n"
     "\n"
     "## The lanes\n"
     "\n"
     "Microseconds a pass, the median round. `parse` binds byte-machine's callbacks for the stack alone. `m-events`, `m-spans` and `m-noop` bind, beside the stack's, the callbacks jsonparse binds for `events`: those that carry no bytes, the two that do, or both, to procedures that do nothing; `m-count` counts in them as `events` does, and `m-all` adds `string-start` and `key-start` to `m-noop`. `j-noop` binds jsonparse's fourteen procedures, doing nothing, and `events` is the events lane.\n"
     "\n"
     "| File | Bytes | Values |" (cells (map symbol->string callback-lanes)) "\n"
     "|:--|--:|--:|" (apply string-append (map (lambda (lane) "--:|") callback-lanes)) "\n"
     (apply string-append (map lane-row rows))
     "\n"
     "## Per value\n"
     "\n"
     "Nanoseconds a value, keys included: the median of the turns' differences between two lanes, then the least and most of their middle half. `calls` is how many callbacks `m-noop` delivers a value that `parse` doesn't. `byte-machine` is `m-noop` less `parse`, and `its events` and `its spans` are `m-events` and `m-spans` less `parse`; `counting` is `m-count` less `m-noop`; `jsonparse` is `events` less `m-count`, and `all fourteen` is `j-noop` less `m-all`; `all` is `events` less `parse`. A file of fewer than " (group-digits split-floor) " values gets none.\n"
     "\n"
     "| File | calls | byte-machine | its events | its spans | counting | jsonparse | all fourteen | all |\n"
     "|:--|--:|--:|--:|--:|--:|--:|--:|--:|\n"
     (apply string-append (map split-row rows)))))
