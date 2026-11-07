#!r6rs
;;; (jsonparse-testing tree): runs (jsonparse tree)'s builder, and works out
;;; what it should build from (jsonparse-testing string)'s trace, for the
;;; suites that test the builder.
;;;
;;;   run-builder    every result of one schedule, then the value
;;;   reference-run  the same, from run-assembler's trace: its results, then
;;;                  a value folded from its entries by recursive descent
;;;   canonical      a value with its hashtables and json-numbers made
;;;                  comparable by equal?
;;;   as-hashtables  a canonical value of alists, as object-mode hashtable
;;;                  would build it: the last duplicate wins
;;;
;;; The builder keeps a stack and builds each container at its end; the
;;; reference descends through a list of entries and builds as it returns,
;;; and works out the last duplicate on its own. The two share only the
;;; assembler, which slice 3's suites test.
;;;
;;; Schedules are (jsonparse-testing machine)'s: lists of (bytevector start
;;; end) feeds.
;;;
;;; Test-only: it lives in tests/, on make test's library path.
(library (jsonparse-testing tree)
  (export run-builder reference-run canonical as-hashtables)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse string)
          (jsonparse tree)
          (jsonparse-testing string))

  ;; canonical : Any -> Any
  ;; V with each hashtable as (hashtable (KEY . VALUE) ...), its members
  ;; sorted by key, and each json-number as (json-number TEXT), all the way
  ;; down. Vectors, alists and everything else keep their shape. Neither
  ;; form can be an alist, whose first element is a pair.
  (define (canonical v)
    (cond ((vector? v) (vector-map canonical v))
          ((hashtable? v)
           (let-values (((keys values) (hashtable-entries v)))
             (cons 'hashtable
                   (sorted (map (lambda (k x) (cons k (canonical x)))
                                (vector->list keys) (vector->list values))))))
          ((json-number? v) (list 'json-number (json-number-text v)))
          ((or (pair? v) (null? v))
           (map (lambda (m) (cons (car m) (canonical (cdr m)))) v))
          (else v)))

  (define (sorted members)
    (list-sort (lambda (a b) (string<? (car a) (car b))) members))

  ;; as-hashtables : Any -> Any
  ;; V, canonical and built with alists, as canonical would give it had it
  ;; been built with hashtables: each object keeps, for each key, the value
  ;; of its last member with that key.
  (define (as-hashtables v)
    (cond ((vector? v) (vector-map as-hashtables v))
          ((and (pair? v) (eq? (car v) 'json-number)) v)
          ((or (pair? v) (null? v))
           (cons 'hashtable
                 (sorted (last-of-each
                          (map (lambda (m) (cons (car m) (as-hashtables (cdr m)))) v)))))
          (else v)))

  ;; The members of an alist whose key no later member has, in order.
  (define (last-of-each members)
    (let loop ((ms (reverse members)) (seen '()) (kept '()))
      (cond ((null? ms) kept)
            ((member (caar ms) seen) (loop (cdr ms) seen kept))
            (else (loop (cdr ms) (cons (caar ms) seen) (cons (car ms) kept))))))

  ;; The value the entries of a trace, without its results, make, by
  ;; recursive descent. NULL stands for null; objects are alists.
  (define (fold-entries entries null)
    (define (value es)
      (let ((e (car es)))
        (cond ((eq? e 'null) (values null (cdr es)))
              ((eq? e 'array-start) (elements (cdr es) '()))
              ((eq? e 'object-start) (members (cdr es) '()))
              ((not (pair? e)) (assertion-violation 'reference-run "not a value entry" e))
              ((memq (car e) '(boolean string number)) (values (cadr e) (cdr es)))
              ((eq? (car e) 'json-number) (values (make-json-number (cadr e)) (cdr es)))
              (else (assertion-violation 'reference-run "not a value entry" e)))))
    (define (elements es acc)
      (if (eq? (car es) 'array-end)
          (values (list->vector (reverse acc)) (cdr es))
          (let-values (((v rest) (value es)))
            (elements rest (cons v acc)))))
    (define (members es acc)
      (cond ((eq? (car es) 'object-end) (values (reverse acc) (cdr es)))
            ((and (pair? (car es)) (eq? (caar es) 'key))
             (let-values (((v rest) (value (cdr es))))
               (members rest (cons (cons (cadar es) v) acc))))
            (else (assertion-violation 'reference-run "not a key entry" (car es)))))
    (let-values (((v rest) (value entries)))
      (unless (null? rest)
        (assertion-violation 'reference-run "entries after the value" rest))
      v))

  (define (result? e) (and (pair? e) (memq (car e) '(feed finish))))

  (define (finished? results)
    (eq? (cadr (car (reverse results))) 'finished))

  ;; reference-run : Schedule json-options -> (Listof Entry)
  ;; run-assembler's results under SCHEDULE and OPTIONS, in order, as
  ;;
  ;;   (feed STATUS CODE OFFSET)
  ;;   (finish STATUS CODE OFFSET)
  ;;
  ;; and, if the last is finished, then (value V): V the canonical value
  ;; its entries make under OPTIONS' null and object-mode.
  (define (reference-run schedule options)
    (let* ((trace (run-assembler schedule options))
           (results (filter result? trace)))
      (if (finished? results)
          (let ((v (canonical (fold-entries (remp result? trace)
                                            (json-options-null options)))))
            (append results
                    (list (list 'value
                                (if (eq? (json-options-object-mode options) 'hashtable)
                                    (as-hashtables v)
                                    v)))))
          results)))

  (define (result-entry tag r)
    (list tag (json-result-status r) (json-result-code r) (json-result-offset r)))

  ;; run-builder : Schedule json-options -> (Listof Entry)
  ;; Makes a builder under OPTIONS, feeds it SCHEDULE in order, and
  ;; finishes unless a feed answered other than need-input, as
  ;; run-assembler does. The entries are reference-run's: each result, and
  ;; the canonical value if the last result is finished.
  (define (run-builder schedule options)
    (let ((b (make-json-builder options)))
      (let loop ((feeds schedule) (acc '()))
        (define (done acc)
          (let ((results (reverse acc)))
            (if (finished? results)
                (append results (list (list 'value (canonical (json-builder-value b)))))
                results)))
        (if (null? feeds)
            (done (cons (result-entry 'finish (json-builder-finish! b)) acc))
            (let* ((f (car feeds))
                   (r (json-builder-feed! b (car f) (cadr f) (caddr f)))
                   (acc (cons (result-entry 'feed r) acc)))
              (if (eq? (json-result-status r) 'need-input)
                  (loop (cdr feeds) acc)
                  (done acc))))))))
