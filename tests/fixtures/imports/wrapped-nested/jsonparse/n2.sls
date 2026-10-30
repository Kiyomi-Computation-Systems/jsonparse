#!r6rs
(library (jsonparse n2)
  (export)
  (import (rnrs)
          (only (prefix (jsonparse easy) e:) e:string->json)))
