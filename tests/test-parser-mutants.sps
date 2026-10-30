;;; tests/test-parser-mutants.sps: does tests/test-parser-stack.sps notice a
;;; broken stack? (ADR-0004)
;;;
;;; Each mutant below is src/jsonparse/parser.sls with one piece of text
;;; replaced. It is written to build/mutants/NAME/jsonparse/parser.sls, and
;;; the stack suite is run on it in a fresh Chez with build/mutants/NAME
;;; ahead of the suite's own library path. A mutant is caught when the suite
;;; exits 1 and prints a FAIL line. Any other exit, a load or compile error
;;; included, means the mutant is broken, and fails here with its stderr.
;;;
;;; The old text of a mutant must occur in the source exactly once, or the
;;; check fails, naming the mutant as no longer applying. A control, the
;;; source unchanged, must pass the suite: it shows the copy is loaded
;;; from build/mutants and the suite runs there.
;;;
;;; make test runs it from the repository root with CHEZ exported.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (chezscheme) getenv library-directories file-directory? mkdir
              current-directory))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(define chez (getenv "CHEZ"))

(define source "src/jsonparse/parser.sls")
(define suite "tests/test-parser-stack.sps")
(define mutants-root "build/mutants")

;; --- the mutants ------------------------------------------------------------------

;; (NAME (OLD NEW) ...): each OLD, found once in the source, becomes NEW.
(define mutants
  (list
   (list "context-swapped"
         (list "        'object\n        'array))"
               "        'array\n        'object))"))
   (list "push-skipped"
         (list "    (bytevector-u8-set! (state-stack s) (state-depth s) entry)\n    (state-depth-set! s (fx+ (state-depth s) 1)))"
               "    #f)"))
   (list "pop-skipped"
         (list "    (state-depth-set! s (fx- (state-depth s) 1)))"
               "    #f)"))
   (list "one-entry-kind"
         (list "(list 'array-start (opener array-entry (h 'array-start)))"
               "(list 'array-start (opener object-entry (h 'array-start)))"))
   (list "other-entry-kind"
         (list "(list 'object-start (opener object-entry (h 'object-start)))"
               "(list 'object-start (opener array-entry (h 'object-start)))"))
   (list "stack-one-short"
         (list "(make-bytevector limit 0)"
               "(make-bytevector (max 0 (- limit 1)) 0)"))
   (list "reset-keeps-depth"
         (list "(state-depth-set! (json-parser-state parser) 0)"
               "#f"))
   (list "push-by-two"
         (list "(state-depth-set! s (fx+ (state-depth s) 1))"
               "(state-depth-set! s (fx+ (state-depth s) 2))"))
   (list "pop-by-two"
         (list "(state-depth-set! s (fx- (state-depth s) 1)))"
               "(state-depth-set! s (fx- (state-depth s) 2)))"))
   (list "context-reads-second"
         (list "(bytevector-u8-ref (state-stack s) (fx- (state-depth s) 1))"
               "(bytevector-u8-ref (state-stack s) (fx- (state-depth s) 2))"))
   (list "bare-opener-skips-push"
         (list "(lambda (p s) (push! s entry) callback-continue)"
               "(lambda (p s) callback-continue)"))
   (list "bare-closer-skips-pop"
         (list "(lambda (p s) (pop! s) callback-continue)"
               "(lambda (p s) callback-continue)"))
   ;; The stack as a ring: depth taken modulo 8, or 64, in both places.
   (list "stack-ring-8"
         (list "(bytevector-u8-set! (state-stack s) (state-depth s) entry)"
               "(bytevector-u8-set! (state-stack s) (fxand (state-depth s) 7) entry)")
         (list "(bytevector-u8-ref (state-stack s) (fx- (state-depth s) 1))"
               "(bytevector-u8-ref (state-stack s) (fxand (fx- (state-depth s) 1) 7))"))
   (list "stack-ring-64"
         (list "(bytevector-u8-set! (state-stack s) (state-depth s) entry)"
               "(bytevector-u8-set! (state-stack s) (fxand (state-depth s) 63) entry)")
         (list "(bytevector-u8-ref (state-stack s) (fx- (state-depth s) 1))"
               "(bytevector-u8-ref (state-stack s) (fxand (fx- (state-depth s) 1) 63))"))
   ;; One stack bytevector for every parser, the depth still each one's own.
   (list "stack-shared-global"
         (list "  (define object-entry 0)"
               "  (define shared-stack (make-bytevector 65535 0))\n  (define object-entry 0)")
         (list "(make-state (make-bytevector limit 0) 0 0 context)"
               "(make-state shared-stack 0 0 context)"))
   ;; The high half of a surrogate pair in a library-level variable.
   (list "high-shared-global"
         (list "  (define object-entry 0)"
               "  (define shared-high 0)\n  (define object-entry 0)")
         (list "(state-high-set! s unit)"
               "(set! shared-high unit)")
         (list "(fx- (state-high s) #xD800)"
               "(fx- shared-high #xD800)"))))

;; apply-edits : String (Listof (List String String)) -> String
(define (apply-edits text edits)
  (fold-left (lambda (t e) (replace-once t (car e) (cadr e))) text edits))

;; --- files ------------------------------------------------------------------------

(define (read-text path)
  (let ((p (open-file-input-port path (file-options) (buffer-mode block)
                                 (make-transcoder (utf-8-codec)))))
    (let ((text (get-string-all p)))
      (close-port p)
      text)))

;; write-text : String String -> Unit
;; Replaces the file at PATH: it is deleted first, then written.
(define (write-text path text)
  (when (file-exists? path) (delete-file path))
  (let ((p (open-file-output-port path (file-options) (buffer-mode block)
                                  (make-transcoder (utf-8-codec)))))
    (put-string p text)
    (close-port p)))

(define (ensure-directory path)
  (unless (file-directory? path) (mkdir path #o755)))

;; occurrences : String String -> Nat
;; How many times NEEDLE starts in TEXT, overlaps counted.
(define (occurrences text needle)
  (let ((n (string-length needle)) (len (string-length text)))
    (let loop ((i 0) (count 0))
      (cond ((> (+ i n) len) count)
            ((string=? (substring text i (+ i n)) needle) (loop (+ i 1) (+ count 1)))
            (else (loop (+ i 1) count))))))

;; replace-once : String String String -> String
(define (replace-once text old new)
  (let loop ((i 0))
    (if (string=? (substring text i (+ i (string-length old))) old)
        (string-append (substring text 0 i) new
                       (substring text (+ i (string-length old)) (string-length text)))
        (loop (+ i 1)))))

(define (absolute path)
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (current-directory) "/" path)))

;; libdirs : String
;; This suite's library path, as --libdirs takes it.
(define libdirs
  (let ((dirs (map (lambda (d) (absolute (if (pair? d) (car d) d))) (library-directories))))
    (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs))))

;; install! : String String -> String
;; Writes TEXT as the parser library of the mutant NAME; its library root.
(define (install! name text)
  (let* ((root (absolute (string-append mutants-root "/" name))))
    (ensure-directory (absolute mutants-root))
    (ensure-directory root)
    (ensure-directory (string-append root "/jsonparse"))
    (write-text (string-append root "/jsonparse/parser.sls") text)
    root))

;; run-suite : String -> (List Integer String String)
(define (run-suite root)
  (capture-command (list chez "--libdirs" (string-append root ":" libdirs)
                         "--program" suite)))

;; has-fail-line? : String -> Boolean
(define (has-fail-line? out)
  (or (and (>= (string-length out) 5) (string=? (substring out 0 5) "FAIL "))
      (> (occurrences out "\nFAIL ") 0)))

;; --- the checks -------------------------------------------------------------------

(test-begin "parser-mutants")

(test-equal "CHEZ names the Chez to spawn"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

(unless (and chez (not (string=? chez "")))
  (exit 1))

(define original (read-text source))

(let ((r (run-suite (install! "control" original))))
  (test-equal "control: the unmodified copy passes the stack suite, exit 0, no stderr"
    (list 0 "")
    (list (car r) (caddr r))))

(for-each
 (lambda (m)
   (let* ((name (car m)) (edits (cdr m))
          (counts (map (lambda (e) (occurrences original (car e))) edits)))
     (test-equal (string-append name ": each old text occurs in " source " exactly once; else the mutant no longer applies")
       (map (lambda (e) 1) edits) counts)
     (when (for-all (lambda (c) (= c 1)) counts)
       (let ((r (run-suite (install! name (apply-edits original edits)))))
         (test-equal (string-append name ": the stack suite exits 1 with a FAIL line (255 or a load error is a broken mutant)")
           (list 1 #t "")
           (list (car r) (has-fail-line? (cadr r))
                 (if (= (car r) 1) "" (caddr r))))))))
 mutants)

(test-end "parser-mutants")

(exit (suite-exit-status runner))
