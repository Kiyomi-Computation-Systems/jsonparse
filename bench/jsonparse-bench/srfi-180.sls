#!r6rs
;;; (jsonparse-bench srfi-180): SRFI 180's reference implementation, as an
;;; R6RS library for bench/chez-peers.sps (ADR-0024). It includes
;;; build/bench/comparators/srfi-180-body.scm, the body of the R7RS library
;;; (srfi 180), which scripts/fetch-bench-files fetches and checks against
;;; bench/comparators.lock, and which is never committed.
;;;
;;; Chez's include tries a relative path first beside the file that
;;; includes it, then under each of source-directories, by default "." (the
;;; current directory); a path starting ./ or ../ is taken from the current
;;; directory alone. So the body is found when this library is compiled
;;; from the repository's root, as make does, and nowhere else.
;;;
;;; Upstream's srfi/180.sld imports (scheme base), (scheme inexact),
;;; (scheme case-lambda), (scheme char), (scheme text), (scheme write),
;;; (check), (srfi 145), (srfi 180 helpers), arithmetic-shift and
;;; bitwise-ior. (rnrs) has most of that; this library gives the body the
;;; rest, as R7RS defines it:
;;;
;;;   define-record-type  R7RS's form, not R6RS's
;;;   error               R7RS's (error message irritant ...)
;;;   make-parameter      Chez's
;;;   write-string        R7RS's (write-string string [port])
;;;   assume              SRFI 145's, checked
;;;   arithmetic-shift    bitwise-arithmetic-shift
;;;   %read-error?        the helpers': an error reading the port, here an
;;;                       i/o read or decoding error
;;;   valid-number?       the helpers', which match a regexp from
;;;                       (chibi regexp); ours checks JSON's number grammar
;;;                       by hand
;;;
;;; The body's (check) is its tests' and (scheme text) gives it nothing it
;;; calls.
;;;
;;; Exported, as SRFI 180 defines them, for bench/chez-peers.sps:
;;;
;;;   json-fold : (Any Any -> Any) (Any -> Any) (Any -> Any) (Any -> Any)
;;;               (Any -> Any) Any [Textual-Input-Port] -> Any
;;;   json-read : [Textual-Input-Port] -> Any
;;;   json-error? : Any -> Boolean
;;;   json-error-reason : Json-Error -> String
;;;
;;; and valid-number?, below.
(library (jsonparse-bench srfi-180)
  (export json-fold json-read json-error? json-error-reason valid-number?)
  (import (except (rnrs) define-record-type error)
          (prefix (only (rnrs) define-record-type error) r6rs:)
          (only (chezscheme) include make-parameter))

  ;; R7RS's define-record-type, for records whose constructor takes every
  ;; field in order and whose fields have no modifier: the body's one
  ;; record is such. Anything else is a syntax violation.
  (define-syntax define-record-type
    (lambda (stx)
      (syntax-case stx ()
        ((_ type (constructor cfield ...) predicate (field accessor) ...)
         (and (= (length #'(cfield ...)) (length #'(field ...)))
              (for-all bound-identifier=? #'(cfield ...) #'(field ...)))
         #'(r6rs:define-record-type (type constructor predicate)
             (fields (immutable field accessor) ...))))))

  ;; error : String Any ... -> !
  ;; R7RS's error, which takes no who. The body also calls it as
  ;; (error 'json message ...), which R6RS's error reads the same way.
  (define (error message . irritants)
    (if (string? message)
        (apply r6rs:error #f message irritants)
        (apply r6rs:error message irritants)))

  ;; write-string : String [Port] -> Void
  (define write-string
    (case-lambda
      ((s) (put-string (current-output-port) s))
      ((s port) (put-string port s))))

  ;; SRFI 145's assume, as its sample implementation does it: EXPR's value,
  ;; or a raise when it is #f.
  (define-syntax assume
    (syntax-rules ()
      ((_ expr message ...)
       (or expr (assertion-violation 'assume "invalid assumption" 'expr message ...)))))

  ;; arithmetic-shift : Integer Integer -> Integer
  (define (arithmetic-shift n amount) (bitwise-arithmetic-shift n amount))

  ;; %read-error? : Any -> Boolean
  ;; Whether reading the port raised X: an i/o read error, or a decoding
  ;; error from a transcoder whose error-handling mode is raise.
  (define (%read-error? x)
    (or (i/o-read-error? x) (i/o-decoding-error? x)))

  ;; valid-number? : String -> Boolean
  ;; Whether S is one number in JSON's grammar, whole:
  ;;   -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
  (define (valid-number? s)
    (let ((n (string-length s)))
      (define (char-at? i c) (and (fx<? i n) (char=? (string-ref s i) c)))
      (define (digit? i) (and (fx<? i n) (char<=? #\0 (string-ref s i) #\9)))
      ;; The index after the digits starting at I.
      (define (digits i) (if (digit? i) (digits (fx+ i 1)) i))
      (define (exponent i)
        (cond ((fx=? i n) #t)
              ((or (char-at? i #\e) (char-at? i #\E))
               (let ((j (if (or (char-at? (fx+ i 1) #\+) (char-at? (fx+ i 1) #\-))
                            (fx+ i 2)
                            (fx+ i 1))))
                 (and (digit? j) (fx=? (digits j) n))))
              (else #f)))
      (define (fraction i)
        (if (char-at? i #\.)
            (and (digit? (fx+ i 1)) (exponent (digits (fx+ i 1))))
            (exponent i)))
      (let ((i (if (char-at? 0 #\-) 1 0)))
        (cond ((not (digit? i)) #f)
              ((char-at? i #\0) (fraction (fx+ i 1)))
              (else (fraction (digits i)))))))

  (include "build/bench/comparators/srfi-180-body.scm"))
