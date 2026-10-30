#!r6rs
;; #! once here,
(library (jsonparse several)
  (export a b)
  (import (rnrs))
  (define a "#!") (define b "#!#!"))
;; and #! again.
