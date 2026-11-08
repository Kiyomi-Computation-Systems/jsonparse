#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site pages)
  (export pages page-file-name)
  (import (rnrs))

  ;; pages : (Listof (Pairof String String))
  ;; The nav's single source of order and labels: each docs/ file and its
  ;; label, the home page first, then the order of its "Read next" list.
  ;; tests/site-check.sps asserts the file set here equals docs/*.md.
  (define pages
    '(("README.md"    . "Home")
      ("easy.md"      . "Whole documents and streams")
      ("tree.md"      . "Building values")
      ("writer.md"    . "Writing JSON")
      ("sequence.md"  . "Streams of values")
      ("parser.md"    . "The push parser")
      ("string.md"    . "Strings and numbers")
      ("reference.md" . "API reference")))

  ;; page-file-name : String -> String
  ;; The file a page is written to: README.md, the home page, as index.html,
  ;; and any other page.md as page.html.  tests/site-check.sps holds every
  ;; relative link to these names.
  (define (page-file-name name)
    (if (string=? name "README.md")
        "index.html"
        (string-append (substring name 0 (- (string-length name) 3)) ".html"))))
