#!r6rs
(library (jsonparse parser (1 0))
  (export)
  (import (rnrs (6))
          (generated jsonparse)
          (only (byte-machine runtime (0 8)) make-parser)
          (prefix (byte-machine runtime) bm:)))
