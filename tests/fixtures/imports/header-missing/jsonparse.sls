;; A core library with no header line, otherwise legal: Chez reads a file
;; with no directive with its own syntax.
(library (jsonparse)
  (export)
  (import (rnrs)))
