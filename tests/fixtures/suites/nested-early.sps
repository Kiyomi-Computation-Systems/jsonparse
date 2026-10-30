(import (rnrs))
(define (f) (if #t (exit 2) #f))
(exit (suite-exit-status runner))
