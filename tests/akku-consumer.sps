#!r6rs
;;; The program tests/check-akku.sh runs inside a consumer project, with
;;; only the library path Akku's activate script sets. It imports what a
;;; user imports, feeds a builder a document in two pieces split inside a
;;; string, writes the value back, and reads a second document with
;;; (jsonparse easy). It prints one line:
;;;
;;;   {"name":"Ada","langs":["en","fr"]} fr
(import (rnrs)
        (jsonparse easy)
        (jsonparse tree)
        (only (jsonparse parser) json-result-status))

(define builder (make-json-builder))

(for-each
 (lambda (piece)
   (let ((status (json-result-status (json-builder-feed! builder (string->utf8 piece)))))
     (unless (eq? status 'need-input)
       (error 'akku-consumer "the builder stopped" status))))
 '("{\"name\": \"A" "da\", \"langs\": [\"en\", \"fr\"]}"))

(let ((status (json-result-status (json-builder-finish! builder))))
  (unless (eq? status 'finished)
    (error 'akku-consumer "the document did not finish" status)))

(display (json->string (json-builder-value builder)))
(display " ")
(display (json-ref (string->json "[\"en\", \"fr\"]") 1))
(newline)
