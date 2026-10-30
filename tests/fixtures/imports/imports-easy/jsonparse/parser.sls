#!r6rs
(library (jsonparse parser)
  (export)
  (import (rnrs)
          (only (jsonparse easy) string->json)
          (for (prefix (jsonparse easy (1)) e:) run)))
