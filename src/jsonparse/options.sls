#!r6rs
;;; (jsonparse options): the options record both layers take (ADR-0010).
;;;
;;; A record is checked when it is made and never changes, so a parser made
;;; from one cannot be refused later. Options are given by name, any order:
;;;
;;;   (make-json-options)                     every default
;;;   (make-json-options 'depth-limit 64)     at most 64 containers open at once
;;;
;;; depth-limit is how many objects and arrays may be open at once: an
;;; exact integer from 0 to 65535, default 512 (ADR-0005). At 0 only a
;;; top-level scalar parses. 65535 is the most the machine's 16-bit field
;;; holds.
;;;
;;; number-mode is how (jsonparse string) converts a number (ADR-0011):
;;;
;;;   flonum  the default. A number with no fraction and no exponent is an
;;;           exact integer; any other is the nearest flonum
;;;   exact   every number is exact: 1.5 is 3/2
;;;   text    a json-number record holding the number's text
;;;
;;; digit-limit is how many digits a number may have in flonum and exact
;;; modes, its fraction and exponent included: an exact integer from 1 to
;;; the greatest fixnum, default 1000 (ADR-0011). The parser ignores both.
;;;
;;; A bad option is a mistake in the calling code, not in the input, so it
;;; raises an R6RS assertion violation whose who is make-json-options.
;;;
;;; object-mode is how (jsonparse tree) builds an object (ADR-0006):
;;;
;;;   alist      the default. An alist of (key . value) pairs in document
;;;              order, every duplicate kept
;;;   hashtable  an R6RS hashtable keyed by string; the last duplicate wins
;;;
;;; null is what (jsonparse tree) builds for null: a symbol, default the
;;; symbol null, or a record (R6RS record?) that is not a hashtable
;;; (ADR-0017). Anything else is refused, '() included, so null can't be
;;; taken for another value under any options. A json-number is opaque, so
;;; record? refuses it, and so it refuses any opaque record.
;;;
;;; indent is how (jsonparse writer) lays a value out (ADR-0018): 0, the
;;; default, writes it compact, on one line with no spaces. Any more puts
;;; each member of an array or object on its own line, indented that many
;;; spaces a level, and a space after each key's colon. An exact integer
;;; from 0 to 10, the most JavaScript's JSON.stringify indents by.
;;;
;;; stream is how a stream of many values is framed (ADR-0014, ADR-0020):
;;;
;;;   lines   the default. JSON Lines and NDJSON: one value a line, each
;;;           line ended by a newline, the last one's optional
;;;   seq     RFC 7464: each value after an RS byte (#x1E)
;;;   values  values one after another, whitespace between them where it
;;;           is needed
;;;
;;; A parser reads one value unless stream is values, when it reads any
;;; number of them, none included. (jsonparse sequence) reads every format.
;;;
;;; blank-lines is what (jsonparse sequence) does with a blank or
;;; whitespace-only line under stream lines: error, the default, makes it
;;; a bad record; skip passes over it. Giving it under any other stream
;;; raises, since only lines has lines.
(library (jsonparse options)
  (export make-json-options json-options? json-options-depth-limit
          json-options-number-mode json-options-digit-limit
          json-options-object-mode json-options-null json-options-indent
          json-options-stream json-options-blank-lines)
  (import (rnrs))

  (define default-depth-limit 512)
  (define max-depth-limit 65535)
  (define default-number-mode 'flonum)
  (define default-digit-limit 1000)
  (define default-object-mode 'alist)
  (define default-null 'null)
  (define default-indent 0)
  (define max-indent 10)
  (define default-stream 'lines)
  (define default-blank-lines 'error)

  ;; json-options? : Any -> Boolean
  ;; json-options-depth-limit : json-options -> Nonnegative-Fixnum
  ;; json-options-number-mode : json-options -> (U 'flonum 'exact 'text)
  ;; json-options-digit-limit : json-options -> Positive-Fixnum
  ;; json-options-object-mode : json-options -> (U 'alist 'hashtable)
  ;; json-options-null : json-options -> (U Symbol Record)
  ;; json-options-indent : json-options -> Nonnegative-Fixnum, at most 10
  ;; json-options-stream : json-options -> (U 'lines 'seq 'values)
  ;; json-options-blank-lines : json-options -> (U 'error 'skip)
  (define-record-type (json-options new-json-options json-options?)
    (fields (immutable depth-limit json-options-depth-limit)
            (immutable number-mode json-options-number-mode)
            (immutable digit-limit json-options-digit-limit)
            (immutable object-mode json-options-object-mode)
            (immutable null json-options-null)
            (immutable indent json-options-indent)
            (immutable stream json-options-stream)
            (immutable blank-lines json-options-blank-lines))
    (sealed #t)
    (opaque #t))

  (define (refuse message . irritants)
    (apply assertion-violation 'make-json-options message irritants))

  ;; make-json-options : (Listof Any) -> json-options
  ;; A record from NAME VALUE pairs; a name left out takes its default.
  ;; Raises for an unknown name, a name given twice, a name with no value,
  ;; a value out of range, and blank-lines under a stream other than lines.
  (define (make-json-options . args)
    (let loop ((xs args) (seen '())
               (depth-limit default-depth-limit)
               (number-mode default-number-mode)
               (digit-limit default-digit-limit)
               (object-mode default-object-mode)
               (null default-null)
               (indent default-indent)
               (stream default-stream)
               (blank-lines default-blank-lines))
      (cond
       ((null? xs)
        (when (and (memq 'blank-lines seen) (not (eq? stream 'lines)))
          (refuse "blank-lines applies only under stream lines" stream))
        (new-json-options depth-limit number-mode digit-limit object-mode null indent
                          stream blank-lines))
       ((null? (cdr xs)) (refuse "an option has no value" (car xs)))
       ((memq (car xs) seen) (refuse "an option is given twice" (car xs)))
       (else
        (let ((name (car xs)) (value (cadr xs)) (rest (cddr xs)))
          (define (next . changed)
            (apply loop rest (cons name seen) changed))
          (case name
            ((depth-limit)
             (unless (and (fixnum? value) (fx<=? 0 value max-depth-limit))
               (refuse "depth-limit is not an exact integer from 0 to 65535" value))
             (next value number-mode digit-limit object-mode null indent
                   stream blank-lines))
            ((number-mode)
             (unless (memq value '(flonum exact text))
               (refuse "number-mode is not flonum, exact or text" value))
             (next depth-limit value digit-limit object-mode null indent
                   stream blank-lines))
            ((digit-limit)
             (unless (and (fixnum? value) (fx>=? value 1))
               (refuse "digit-limit is not an exact integer from 1 to the greatest fixnum" value))
             (next depth-limit number-mode value object-mode null indent
                   stream blank-lines))
            ((object-mode)
             (unless (memq value '(alist hashtable))
               (refuse "object-mode is not alist or hashtable" value))
             (next depth-limit number-mode digit-limit value null indent
                   stream blank-lines))
            ((null)
             (unless (or (symbol? value) (and (record? value) (not (hashtable? value))))
               (refuse "null is not a symbol, or a record that is not a hashtable" value))
             (next depth-limit number-mode digit-limit object-mode value indent
                   stream blank-lines))
            ((indent)
             (unless (and (fixnum? value) (fx<=? 0 value max-indent))
               (refuse "indent is not an exact integer from 0 to 10" value))
             (next depth-limit number-mode digit-limit object-mode null value
                   stream blank-lines))
            ((stream)
             (unless (memq value '(lines seq values))
               (refuse "stream is not lines, seq or values" value))
             (next depth-limit number-mode digit-limit object-mode null indent
                   value blank-lines))
            ((blank-lines)
             (unless (memq value '(error skip))
               (refuse "blank-lines is not error or skip" value))
             (next depth-limit number-mode digit-limit object-mode null indent
                   stream value))
            (else (refuse "unknown option" name)))))))))
