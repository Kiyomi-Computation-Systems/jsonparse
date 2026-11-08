#!r6rs
;;; (jsonparse error): &json-error, the condition jsonparse raises when a
;;; value can't be written as JSON, and that the easy layer raises for a
;;; document that isn't JSON (ADR-0010, ADR-0018).
;;;
;;;   reason  a symbol naming what went wrong: one of the low layer's codes,
;;;           such as unexpected-byte, or one of the writer's, such as
;;;           unwritable-number
;;;   offset  where, for a document: characters into a string, bytes into
;;;           a bytevector or a port. #f for a value the writer refused
;;;
;;; &json-error is an &error, not a &violation: the input was wrong, not
;;; the program. A raise adds a who, a message and irritants beside it.
;;;
;;; &json-record-error is a &json-error in a stream of many values
;;; (ADR-0020). It adds:
;;;
;;;   record  the bad record's number, counting from 1. Its offset counts
;;;           bytes from the start of the stream
(library (jsonparse error)
  (export &json-error make-json-error json-error?
          json-error-reason json-error-offset
          &json-record-error make-json-record-error json-record-error?
          json-error-record)
  (import (rnrs))

  ;; make-json-error : Symbol (Option Nonnegative-Integer) -> &json-error
  ;; json-error? : Any -> Boolean
  ;; json-error-reason : &json-error -> Symbol
  ;; json-error-offset : &json-error -> (Option Nonnegative-Integer)
  (define-condition-type &json-error &error
    make-json-error json-error?
    (reason json-error-reason)
    (offset json-error-offset))

  ;; make-json-record-error : Symbol Nonnegative-Integer Positive-Integer -> &json-record-error
  ;; json-record-error? : Any -> Boolean
  ;; json-error-record : &json-record-error -> Positive-Integer
  (define-condition-type &json-record-error &json-error
    make-json-record-error json-record-error?
    (record json-error-record)))
