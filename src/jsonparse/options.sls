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
;;; A bad option is a mistake in the calling code, not in the input, so it
;;; raises an R6RS assertion violation whose who is make-json-options.
;;;
;;; The number mode, the digit limit, the value options and the stream
;;; options join this record in their slices (ADR-0006, ADR-0011, ADR-0014).
(library (jsonparse options)
  (export make-json-options json-options? json-options-depth-limit)
  (import (rnrs))

  (define default-depth-limit 512)
  (define max-depth-limit 65535)

  ;; json-options? : Any -> Boolean
  ;; json-options-depth-limit : json-options -> Nonnegative-Fixnum
  (define-record-type (json-options new-json-options json-options?)
    (fields (immutable depth-limit json-options-depth-limit))
    (sealed #t)
    (opaque #t))

  (define (refuse message . irritants)
    (apply assertion-violation 'make-json-options message irritants))

  ;; make-json-options : (Listof Any) -> json-options
  ;; A record from NAME VALUE pairs; a name left out takes its default.
  ;; Raises for an unknown name, a name given twice, a name with no value,
  ;; and a value out of range.
  (define (make-json-options . args)
    (let loop ((xs args) (seen '()) (depth-limit default-depth-limit))
      (cond
       ((null? xs) (new-json-options depth-limit))
       ((null? (cdr xs)) (refuse "an option has no value" (car xs)))
       ((memq (car xs) seen) (refuse "an option is given twice" (car xs)))
       (else
        (let ((name (car xs)) (value (cadr xs)) (rest (cddr xs)))
          (case name
            ((depth-limit)
             (unless (and (fixnum? value) (fx<=? 0 value max-depth-limit))
               (refuse "depth-limit is not an exact integer from 0 to 65535" value))
             (loop rest (cons name seen) value))
            (else (refuse "unknown option" name)))))))))
