#!r6rs
;;; (jsonparse-grammar) -- the JSON (RFC 8259) machine, for byte-machine 0.8.
;;;
;;; Tooling, not library code: it imports byte-machine's graph and compiler,
;;; so it lives in grammar/, outside src/, and never reaches the Akku package
;;; (ADR-0003). grammar/emit.sps writes its output to
;;; src/generated/jsonparse.sls, and tests/test-generated.sps renders it again
;;; and compares the two byte for byte (ADR-0001). Both call
;;; render-generated, so they cannot render differently.
;;;
;;; The machine is regular plus counters. Nesting, whether the enclosing
;;; container is an object or an array, is answered by the `context` decision
;;; callback from a stack the consumer keeps (ADR-0004). Everything else is in
;;; the verified machine: the number grammar, string scanning, UTF-8
;;; validation, escape decoding, surrogate pairing, the depth limit and
;;; trailing-garbage rejection.
;;;
;;; Callbacks, all optional but `context`:
;;;   object-start object-end array-start array-end          (event)
;;;   key-start key-end string-start string-end              (event)
;;;   chars-data   (span-data)  raw, already-validated UTF-8 between escapes
;;;   escape       (event)      one UTF-16 code unit in field `cp`. A high
;;;                             surrogate's event comes before its low half
;;;                             is read, so the pair is complete only once
;;;                             the low half's event arrives; input that
;;;                             breaks the pair is rejected after it
;;;   number-data / number-end  (span-data / span-complete)  the number's text
;;;   true false null           (event)
;;;   context      (decision)   -> object | array; asked after a value only
;;;                             when depth > 0
;;;
;;; Fields:
;;;   depth       uint16  open containers; zero means top level
;;;   depth-left  uint16, settable, default 512: how many more containers may
;;;               open. An open decrements it and a close increments it; the
;;;               decrement that would go below zero is `nesting-too-deep`
;;;               (ADR-0005). Its width bounds the depth limit at 65535.
;;;   cp          uint16  the escape's code unit
;;;   mode        uint8, settable; bit 0 allows several top-level values
(library (jsonparse-grammar)
  (export jsonparse-graph render-generated
          generated-binding default-depth-limit mode-allow-multiple)
  (import (rnrs) (byte-machine graph) (byte-machine compile))

  ;; default-depth-limit : Integer
  ;; depth-left's declared start, the depth limit a parser gets by default.
  (define default-depth-limit 512)

  ;; mode-allow-multiple : Integer
  ;; The `mode` bit that lets whitespace-separated values follow the first.
  (define mode-allow-multiple 1)

  ;; generated-binding : Symbol
  ;; The one name (generated jsonparse) exports.
  (define generated-binding 'jsonparse-machine)

  ;; --- small builders ---------------------------------------------------------
  (define (b c) (if (char? c) (char->integer c) c))
  (define (byte= c) (make-exact-byte-matcher (b c)))
  (define (one-of . cs) (make-byte-set-matcher (map b cs)))
  (define (range lo hi) (make-byte-range-matcher (b lo) (b hi)))
  (define (adv t) (make-edge t 'advance))
  (define (re t) (make-edge t 'reexecute))
  (define (case* m e) (make-byte-case m e #f))
  (define ws (one-of #\space #\tab #\newline #\return))
  (define digit (range #\0 #\9))
  (define (dispatch name cases fallback . eof)
    (make-byte-dispatch-node name cases fallback (if (null? eof) #f (car eof)) #f))
  (define (cb name callback next)
    (make-callback-node name callback next '() next #f))
  (define (sym . parts)
    (string->symbol
     (apply string-append
            (map (lambda (p) (if (symbol? p) (symbol->string p) p)) parts))))

  ;; --- declarations -------------------------------------------------------------
  (define (event name) (make-callback-declaration name 'event #f '() #f #f))

  (define callbacks
    (append
     (map event '(object-start object-end array-start array-end
                  key-start key-end string-start string-end
                  escape true false null))
     (list (make-callback-declaration 'chars-data 'span-data #f '() #f #f)
           (make-callback-declaration 'number-data 'span-data #f '() #f #f)
           (make-callback-declaration 'number-end 'span-complete #f '() #f #f)
           (make-callback-declaration 'context 'decision #t '(object array) #f #f))))

  (define spans
    (list (make-span-declaration 'chars 'chars-data #f #f)
          (make-span-declaration 'number 'number-data 'number-end #f)))

  (define field-decls
    (list (make-uint-field 'depth 16 0 #f)
          (make-uint-field 'depth-left 16 default-depth-limit #t #f)
          (make-uint-field 'cp 16 0 #f)
          (make-uint-field 'mode 8 0 #t #f)))

  (define errors
    (list (make-error-declaration 'eof 'unexpected-eof "unexpected end of input" #f)
          (make-error-declaration 'unexpected 'unexpected-byte "unexpected byte" #f)
          (make-error-declaration 'bad-number 'invalid-number "malformed number" #f)
          (make-error-declaration 'bad-escape 'invalid-escape "malformed escape" #f)
          (make-error-declaration 'bad-surrogate 'invalid-surrogate "unpaired surrogate" #f)
          (make-error-declaration 'bad-utf8 'invalid-utf8 "invalid UTF-8" #f)
          (make-error-declaration 'control-char 'control-character "unescaped control character" #f)
          (make-error-declaration 'too-deep 'nesting-too-deep "nesting exceeds limit" #f)
          (make-error-declaration 'trailing 'trailing-garbage "data after the top-level value" #f)
          (make-error-declaration 'no-context 'missing-context "context callback answered continue" #f)))

  (define error-nodes
    (list (make-error-node 'e-unexpected 'unexpected #f)
          (make-error-node 'e-number 'bad-number #f)
          (make-error-node 'e-escape 'bad-escape #f)
          (make-error-node 'e-surrogate 'bad-surrogate #f)
          (make-error-node 'e-utf8 'bad-utf8 #f)
          (make-error-node 'e-control 'control-char #f)
          (make-error-node 'e-deep 'too-deep #f)
          (make-error-node 'e-trailing 'trailing #f)
          (make-error-node 'e-context 'no-context #f)
          (make-error-node 'e-eof 'eof #f)))

  ;; --- values -------------------------------------------------------------------
  (define value-nodes
    (list
     (dispatch 'value
       (list (case* ws (adv 'value))
             (case* (byte= #\{) (adv 'obj-open))
             (case* (byte= #\[) (adv 'arr-open))
             (case* (byte= #\") (adv 'str-begin))
             (case* (byte= #\-) (re 'num-begin))
             (case* digit (re 'num-begin))
             (case* (one-of #\t #\f #\n) (re 'literal)))
       (re 'e-unexpected))
     (make-sequence-dispatch-node 'literal
       (list (make-sequence-case (ascii-bytes "true") 'lit-true #f)
             (make-sequence-case (ascii-bytes "false") 'lit-false #f)
             (make-sequence-case (ascii-bytes "null") 'lit-null #f))
       (re 'e-unexpected) #f #f)
     (cb 'lit-true 'true 'after-value)
     (cb 'lit-false 'false 'after-value)
     (cb 'lit-null 'null 'after-value)))

  ;; --- containers -----------------------------------------------------------------
  ;; Open: spend one of depth-left, which fails past the limit; count the
  ;; depth; announce. Close: give it back, uncount, announce. The close's
  ;; checks cannot fail, since a close is reached only inside a container.
  (define (container-nodes kind open-cb close-cb first-node)
    (let ((open (sym kind "-open")) (count (sym kind "-count"))
          (announce (sym kind "-announce")) (close (sym kind "-close"))
          (uncount (sym kind "-uncount")) (closed (sym kind "-closed")))
      (list
       (make-field-action-node open 'decrement '(depth-left) count 'e-deep #f)
       (make-field-action-node count 'increment '(depth) announce 'e-deep #f)
       (cb announce open-cb first-node)
       (make-field-action-node close 'increment '(depth-left) uncount 'e-deep #f)
       (make-field-action-node uncount 'decrement '(depth) closed 'e-deep #f)
       (cb closed close-cb 'after-value))))

  (define object-nodes
    (append
     (container-nodes 'obj 'object-start 'object-end 'obj-first)
     (list
      (dispatch 'obj-first
        (list (case* ws (adv 'obj-first))
              (case* (byte= #\") (adv 'key-begin))
              (case* (byte= #\}) (adv 'obj-close)))
        (re 'e-unexpected))
      (dispatch 'obj-next
        (list (case* ws (adv 'obj-next))
              (case* (byte= #\,) (adv 'obj-key))
              (case* (byte= #\}) (adv 'obj-close)))
        (re 'e-unexpected))
      (dispatch 'obj-key
        (list (case* ws (adv 'obj-key))
              (case* (byte= #\") (adv 'key-begin)))
        (re 'e-unexpected))
      (dispatch 'colon
        (list (case* ws (adv 'colon))
              (case* (byte= #\:) (adv 'value)))
        (re 'e-unexpected)))))

  (define array-nodes
    (append
     (container-nodes 'arr 'array-start 'array-end 'arr-first)
     (list
      (dispatch 'arr-first
        (list (case* ws (adv 'arr-first))
              (case* (byte= #\]) (adv 'arr-close)))
        (re 'value))
      (dispatch 'arr-next
        (list (case* ws (adv 'arr-next))
              (case* (byte= #\,) (adv 'value))
              (case* (byte= #\]) (adv 'arr-close)))
        (re 'e-unexpected)))))

  ;; After any value: at depth 0 we are done; otherwise ask the consumer.
  (define after-value-nodes
    (list
     (make-field-branch-node 'after-value 'zero '(depth) 'top-done 'ask-context #f)
     (make-callback-node 'ask-context 'context 'e-context
                         '((object obj-next) (array arr-next)) 'e-context #f)
     (dispatch 'top-done
       (list (case* ws (adv 'top-done)))
       (re 'top-more) 'done)
     (make-field-branch-node 'top-more 'mask-any (list 'mode mode-allow-multiple)
                             'value 'e-trailing #f)
     (make-finish-node 'done #f)))

  ;; --- strings ----------------------------------------------------------------------
  ;; One sub-machine per role (key / string), generated from the same function:
  ;; the roles differ only in their start/end events and where they go after.
  (define (string-nodes role start-cb end-cb after)
    (define (n . parts) (apply sym role "-" parts))
    (define cont (range #x80 #xBF))
    (define (need k next)                ; k continuation bytes, then `next`
      (dispatch (n "u" (number->string k))
        (list (case* cont (adv (if (= k 1) next (n "u" (number->string (- k 1)))))))
        (re 'e-utf8)))
    (define (simple-escape ch code)
      (list (case* (byte= ch) (adv (n "esc-" (number->string code))))))
    (define escapes
      '((#\" . #x22) (#\\ . #x5C) (#\/ . #x2F) (#\b . #x08)
        (#\f . #x0C) (#\n . #x0A) (#\r . #x0D) (#\t . #x09)))
    (define (hex4 prefix done)          ; four hex digits into `cp`, then `done`
      (let loop ((i 1) (acc '()))
        (if (> i 4)
            (reverse acc)
            (loop (+ i 1)
                  (cons (make-integer-accumulate-node
                         (n prefix (number->string i)) 'cp 16
                         (if (= i 4) done (n prefix (number->string (+ i 1))))
                         (re 'e-escape) 'e-escape #f #f)
                        acc)))))
    (append
     (list
      (cb (n "begin") start-cb (n "run"))
      (make-span-start-node (n "run") 'chars (n "chars") #f)
      ;; the hot loop: ASCII text stays here
      (dispatch (n "chars")
        (list (case* (byte= #\") (re (n "end-run")))
              (case* (byte= #\\) (re (n "esc-run")))
              (case* (range #x00 #x1F) (re 'e-control))
              (case* (range #x20 #x21) (adv (n "chars")))
              (case* (range #x23 #x5B) (adv (n "chars")))
              (case* (range #x5D #x7F) (adv (n "chars")))
              (case* (range #xC2 #xDF) (adv (n "u1")))
              (case* (byte= #xE0) (adv (n "e0")))
              (case* (one-of #xE1 #xE2 #xE3 #xE4 #xE5 #xE6 #xE7 #xE8 #xE9 #xEA #xEB #xEC #xEE #xEF)
                     (adv (n "u2")))
              (case* (byte= #xED) (adv (n "ed")))
              (case* (byte= #xF0) (adv (n "f0")))
              (case* (range #xF1 #xF3) (adv (n "u3")))
              (case* (byte= #xF4) (adv (n "f4"))))
        (re 'e-utf8))
      (need 1 (n "chars")) (need 2 (n "chars")) (need 3 (n "chars"))
      (dispatch (n "e0") (list (case* (range #xA0 #xBF) (adv (n "u1")))) (re 'e-utf8))
      (dispatch (n "ed") (list (case* (range #x80 #x9F) (adv (n "u1")))) (re 'e-utf8))
      (dispatch (n "f0") (list (case* (range #x90 #xBF) (adv (n "u2")))) (re 'e-utf8))
      (dispatch (n "f4") (list (case* (range #x80 #x8F) (adv (n "u2")))) (re 'e-utf8))
      ;; closing quote: close the run, consume the quote, announce
      (make-span-end-node (n "end-run") 'chars (n "quote") #f)
      (dispatch (n "quote") (list (case* (byte= #\") (adv (n "end")))) (re 'e-unexpected))
      (cb (n "end") end-cb after)
      ;; backslash: close the run, consume it, decode the escape
      (make-span-end-node (n "esc-run") 'chars (n "slash") #f)
      (dispatch (n "slash") (list (case* (byte= #\\) (adv (n "esc")))) (re 'e-unexpected))
      (dispatch (n "esc")
        (append (apply append (map (lambda (e) (simple-escape (car e) (cdr e))) escapes))
                (list (case* (byte= #\u) (adv (n "uclear")))))
        (re 'e-escape)))
     ;; simple escapes: store the code unit, announce, resume the run
     (apply append
       (map (lambda (e)
              (let ((code (cdr e)))
                (list (make-field-action-node (n "esc-" (number->string code)) 'store
                                              (list 'cp code) (n "emit") #f #f))))
            escapes))
     (list
      (cb (n "emit") 'escape (n "run"))
      ;; \uXXXX
      (make-field-action-node (n "uclear") 'clear '(cp) (n "h1") #f #f))
     (hex4 "h" (n "classify"))
     (list
      (make-field-branch-node (n "classify") 'range '(cp #xD800 #xDBFF)
                              (n "emit-hi") (n "lone-lo") #f)
      (make-field-branch-node (n "lone-lo") 'range '(cp #xDC00 #xDFFF)
                              'e-surrogate (n "emit") #f)
      ;; a high surrogate must be followed by \u + a low surrogate
      (cb (n "emit-hi") 'escape (n "lo-slash"))
      (dispatch (n "lo-slash") (list (case* (byte= #\\) (adv (n "lo-u")))) (re 'e-surrogate))
      (dispatch (n "lo-u") (list (case* (byte= #\u) (adv (n "lo-clear")))) (re 'e-surrogate))
      (make-field-action-node (n "lo-clear") 'clear '(cp) (n "l1") #f #f))
     (hex4 "l" (n "lo-check"))
     (list
      (make-field-branch-node (n "lo-check") 'range '(cp #xDC00 #xDFFF)
                              (n "emit") 'e-surrogate #f))))

  ;; --- numbers ----------------------------------------------------------------------
  ;; -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?  -- the span carries the text.
  ;; A number can end the document, so its accepting states route EOF through
  ;; the span end and the depth check to `done`.
  (define number-nodes
    (let ((end (re 'num-end)) (bad (re 'e-number)))
      (list
       (make-span-start-node 'num-begin 'number 'num-sign #f)
       (dispatch 'num-sign
         (list (case* (byte= #\-) (adv 'num-lead))
               (case* (byte= #\0) (adv 'num-zero))
               (case* (range #\1 #\9) (adv 'num-int)))
         bad)
       (dispatch 'num-lead
         (list (case* (byte= #\0) (adv 'num-zero))
               (case* (range #\1 #\9) (adv 'num-int)))
         bad)
       (dispatch 'num-zero
         (list (case* (byte= #\.) (adv 'num-frac0))
               (case* (one-of #\e #\E) (adv 'num-exp0))
               (case* digit bad))
         end 'num-eof)
       (dispatch 'num-int
         (list (case* digit (adv 'num-int))
               (case* (byte= #\.) (adv 'num-frac0))
               (case* (one-of #\e #\E) (adv 'num-exp0)))
         end 'num-eof)
       (dispatch 'num-frac0 (list (case* digit (adv 'num-frac))) bad)
       (dispatch 'num-frac
         (list (case* digit (adv 'num-frac))
               (case* (one-of #\e #\E) (adv 'num-exp0)))
         end 'num-eof)
       (dispatch 'num-exp0
         (list (case* (one-of #\+ #\-) (adv 'num-exp1))
               (case* digit (adv 'num-exp)))
         bad)
       (dispatch 'num-exp1 (list (case* digit (adv 'num-exp))) bad)
       (dispatch 'num-exp (list (case* digit (adv 'num-exp))) end 'num-eof)
       (make-span-end-node 'num-end 'number 'after-value #f)
       (make-span-end-node 'num-eof 'number 'num-eof-depth #f)
       (make-field-branch-node 'num-eof-depth 'zero '(depth) 'done 'e-eof #f))))

  ;; jsonparse-graph : Machine
  ;; The machine. Its name, jsonparse, names the generated library
  ;; (generated jsonparse) (ADR-0001).
  (define jsonparse-graph
    (make-machine 'jsonparse 'value field-decls callbacks spans errors
      (append value-nodes object-nodes array-nodes after-value-nodes
              (string-nodes 'key 'key-start 'key-end 'colon)
              (string-nodes 'str 'string-start 'string-end 'after-value)
              number-nodes error-nodes)
      'eof #f))

  ;; render-generated : -> Bytevector
  ;; The bytes of src/generated/jsonparse.sls: the #!r6rs line every library
  ;; under src/ begins with (ADR-0003), then byte-machine's rendering. Raises
  ;; with the verifier's diagnostics if the machine does not verify.
  (define (render-generated)
    (let ((compilation (compile-machine jsonparse-graph '())))
      (unless (compilation-ok? compilation)
        (raise (condition
                (make-error)
                (make-who-condition 'render-generated)
                (make-message-condition "the jsonparse machine does not verify")
                (make-irritants-condition (compilation-diagnostics compilation)))))
      (let ((header (string->utf8 "#!r6rs\n"))
            (body (render-machine compilation generated-binding)))
        (let ((out (make-bytevector (+ (bytevector-length header)
                                       (bytevector-length body)))))
          (bytevector-copy! header 0 out 0 (bytevector-length header))
          (bytevector-copy! body 0 out (bytevector-length header)
                            (bytevector-length body))
          out)))))
