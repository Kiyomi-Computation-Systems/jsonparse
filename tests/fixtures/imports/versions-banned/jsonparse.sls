#!r6rs
(library (jsonparse)
  (export)
  (import (rnrs)
          (chezscheme (9))
          (srfi :1 (1 0))
          (byte-machine graph (>= 0 8))
          (jsonparse easy (1))
          (rnrs eval (6))))
