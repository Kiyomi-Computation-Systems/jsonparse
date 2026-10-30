(import (rnrs))
(when (null? (command-line)) (exit #t))
(exit (suite-exit-status runner))
