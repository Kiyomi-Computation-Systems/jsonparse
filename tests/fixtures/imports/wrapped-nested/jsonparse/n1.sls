#!r6rs
(library (jsonparse n1)
  (export)
  (import (rnrs)
          (only (only (rnrs) car) car)
          (for (rename (prefix (except (only (library (chezscheme)) car cdr) cdr) c:) (c:car kar)) run expand)))
