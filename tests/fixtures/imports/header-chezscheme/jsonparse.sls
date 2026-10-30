#!chezscheme
;; The review's library: under Chez's own directive it reads a repeat
;; vector and an fxvector literal, which R6RS lacks, and imports only (rnrs).
(library (jsonparse)
  (export port-size)
  (import (rnrs))
  (define v '#3(0))
  (define fx '#vfx(1 2))
  (define (port-size p) (list (vector-length v) fx)))
