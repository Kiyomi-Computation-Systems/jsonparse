#!r6rs
;; The header, and then the directive that turns Chez's syntax back on.
#!chezscheme
(library (jsonparse)
  (export v)
  (import (rnrs))
  (define v '#3(0)))
