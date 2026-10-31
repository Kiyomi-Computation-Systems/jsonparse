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
;;; The value options and the stream options join this record in their
;;; slices (ADR-0006, ADR-0014).
(library (jsonparse options)
  (export make-json-options json-options? json-options-depth-limit
          json-options-number-mode json-options-digit-limit)
  (import (rnrs))

  (define default-depth-limit 512)
  (define max-depth-limit 65535)
  (define default-number-mode 'flonum)
  (define default-digit-limit 1000)

  ;; json-options? : Any -> Boolean
  ;; json-options-depth-limit : json-options -> Nonnegative-Fixnum
  ;; json-options-number-mode : json-options -> (U 'flonum 'exact 'text)
  ;; json-options-digit-limit : json-options -> Positive-Fixnum
  (define-record-type (json-options new-json-options json-options?)
    (fields (immutable depth-limit json-options-depth-limit)
            (immutable number-mode json-options-number-mode)
            (immutable digit-limit json-options-digit-limit))
    (sealed #t)
    (opaque #t))

  (define (refuse message . irritants)
    (apply assertion-violation 'make-json-options message irritants))

  ;; make-json-options : (Listof Any) -> json-options
  ;; A record from NAME VALUE pairs; a name left out takes its default.
  ;; Raises for an unknown name, a name given twice, a name with no value,
  ;; and a value out of range.
  (define (make-json-options . args)
    (let loop ((xs args) (seen '())
               (depth-limit default-depth-limit)
               (number-mode default-number-mode)
               (digit-limit default-digit-limit))
      (cond
       ((null? xs) (new-json-options depth-limit number-mode digit-limit))
       ((null? (cdr xs)) (refuse "an option has no value" (car xs)))
       ((memq (car xs) seen) (refuse "an option is given twice" (car xs)))
       (else
        (let ((name (car xs)) (value (cadr xs)) (rest (cddr xs)))
          (case name
            ((depth-limit)
             (unless (and (fixnum? value) (fx<=? 0 value max-depth-limit))
               (refuse "depth-limit is not an exact integer from 0 to 65535" value))
             (loop rest (cons name seen) value number-mode digit-limit))
            ((number-mode)
             (unless (memq value '(flonum exact text))
               (refuse "number-mode is not flonum, exact or text" value))
             (loop rest (cons name seen) depth-limit value digit-limit))
            ((digit-limit)
             (unless (and (fixnum? value) (fx>=? value 1))
               (refuse "digit-limit is not an exact integer from 1 to the greatest fixnum" value))
             (loop rest (cons name seen) depth-limit number-mode value))
            (else (refuse "unknown option" name)))))))))
