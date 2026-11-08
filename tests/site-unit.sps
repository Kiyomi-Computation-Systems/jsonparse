#!r6rs
;;; The docs site generator's pure libraries: slugs, the serializer, the
;;; heading pass, the link rewrite, page names and the page template.  Not
;;; named test-*.sps, so `make test` does not run it; `make check-site` does,
;;; with no chez-cmark-gfm on the library path, so a pure library that starts
;;; importing (cmark gfm) fails here at import.  From the repository root:
;;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs chez --program tests/site-unit.sps
(import (rnrs) (srfi :64) (jsonparse-testing)
        (site slug) (site serializer) (site transform)
        (site links) (site template) (site pages))

;; string-contains-sub? : String String -> Boolean
(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; index-of : String String Integer -> (U Integer #f)
;; The first offset at or after START where NEEDLE begins in HAY.
(define (index-of hay needle start)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i start))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) i)
            (else (loop (+ i 1)))))))

;; offsets-of : String String -> (Listof Integer)
;; Every offset where NEEDLE begins in HAY, in order.
(define (offsets-of hay needle)
  (let loop ((i (index-of hay needle 0)) (acc '()))
    (if i
        (loop (index-of hay needle (+ i 1)) (cons i acc))
        (reverse acc))))

;; script-of : String -> String
;; The text of the first <script> element in HTML; raises if there is none.
(define (script-of html)
  (let* ((open (index-of html "<script>" 0))
         (start (+ open (string-length "<script>"))))
    (substring html start (index-of html "</script>" start))))

;; unguarded-storage : String -> (Listof Integer)
;; The offset of each `localStorage` in SCRIPT that no try block holds: no
;; `try{` comes before it, or a `}` closes something between the last `try{`
;; and it.
(define (unguarded-storage script)
  (filter (lambda (at)
            (let ((tries (filter (lambda (t) (< t at)) (offsets-of script "try{"))))
              (or (null? tries)
                  (let ((last (apply max tries)))
                    (index-of (substring script last at) "}" 0)))))
          (offsets-of script "localStorage")))

(define reg '(("README.md" . ("five-ideas-to-keep-in-mind"))
              ("handlers.md" . ("reading-a-request"))
              ("bodies.md" . ("streaming-a-download"))))

;; rw : SXML String -> SXML
(define (rw body page)
  (let-values (((b d) (rewrite-links body reg page "main"))) b))
;; link : String -> SXML
(define (link href) `(*TOP* (p (a (^ (href ,href)) "x"))))
;; dangling : String String -> (Listof (Pairof String String))
(define (dangling href page)
  (let-values (((b d) (rewrite-links (link href) reg page "main"))) d))

(define doc-out
  (page->document '(("README.md" . "Home") ("handlers.md" . "Handlers")
                    ("bodies.md" . "Bodies and streaming"))
                  "handlers.md" "Handlers"
                  '(*TOP* (h2 (^ (id "reading-a-request")) "Reading a request"))
                  '((2 "Reading a request" "reading-a-request"))
                  '("README.md" . "Home") '("bodies.md" . "Bodies and streaming")))
(define doc-html (sxml->html doc-out))

;; (heading . anchor) rows, each anchor the one GitHub gave that heading on a
;; page it rendered: chez-http-server's docs and repositories, circuit's and
;; jsonparse's, a Hindi
;; README, and github-slugger's fixtures, which it made from GitHub's
;; rendering. No two rows share a slug, so each stands as if alone on its
;; page.
(define github-anchors
  '(("Bodies and streaming" . "bodies-and-streaming")
    ("Keep strings, not the request" . "keep-strings-not-the-request")
    ("A file server, like Python's" . "a-file-server-like-pythons")
    ("Testing: (http-server testing)" . "testing-http-server-testing")
    ("&http-server-error, http-server-error?"
     . "http-server-error-http-server-error")
    ("1. Answer every request" . "1-answer-every-request")
    ("0.10.0 - 2026-10-30" . "0100---2026-10-30")
    ("Is the abandoned iteration's UV_EOF lost, or merely deferred?"
     . "is-the-abandoned-iterations-uv_eof-lost-or-merely-deferred")
    ("Q1 — THE GATE: C→Scheme re-entry from inside a blocking uv_run, under GC pressure"
     . "q1--the-gate-cscheme-re-entry-from-inside-a-blocking-uv_run-under-gc-pressure")
    ("8.1 Read side (peer → handler)" . "81-read-side-peer--handler")
    ("§4 — reentrancy-test.sps" . "4--reentrancy-testsps")
    ("① (uri query)" . "-uri-query")
    ("Decisions to record (Slice ⓪)" . "decisions-to-record-slice-")
    ("स\x94D;थ\x93E;पन\x93E; करन\x93E;"
     . "स\x94D;थ\x93E;पन\x93E;-करन\x93E;")
    ("heading with an _ underscore" . "heading-with-an-_-underscore")
    ("I ♥ unicode" . "i--unicode")
    ("Привет non-latin 你好" . "привет-non-latin-你好")
    ("a_ ‿ ⁀ ⁔ ︳ ︴ ﹍ ﹎ ﹏ ＿b" . "a_-‿-⁀-⁔-︳-︴-﹍-﹎-﹏-＿b")
    ("a\x488; \x489; \x1ABE; \x20DD; \x20DE; \x20DF; \x20E0; \x20E2; \x20E3; \x20E4; \xA670; \xA671; \xA672;b"
     . "a\x488;-\x489;-\x1ABE;-\x20DD;-\x20DE;-\x20DF;-\x20E0;-\x20E2;-\x20E3;-\x20E4;-\xA670;-\xA671;-\xA672;b")
    ;; jsonparse's docs/reference.md, as GitHub rendered it on 2026-11-08
    ("string->json (procedure)" . "string-json-procedure")
    ("&json-error (condition type)" . "json-error-condition-type")
    ("json-error? (predicate)" . "json-error-predicate")
    ("json-reader-reset! (procedure)" . "json-reader-reset-procedure")))

;; github-slugger's fixture rows on repeated headings, in their page order;
;; the headings between them on that page share none of these slugs.
(define github-repeats
  '(("echo" . "echo") ("echo" . "echo-1") ("echo 1" . "echo-1-1")
    ("echo-1" . "echo-1-2") ("echo" . "echo-2")
    ("foxtrot-1" . "foxtrot-1") ("foxtrot" . "foxtrot") ("foxtrot" . "foxtrot-2")
    (" a " . "-a-") ("-a-" . "-a--1")))

;; slug-each : (String -> String) (Listof String) -> (Listof String)
;; Calls slug on each heading in order, as a page meets them.
(define (slug-each slug headings)
  (let loop ((hs headings) (out '()))
    (if (null? hs)
        (reverse out)
        (loop (cdr hs) (cons (slug (car hs)) out)))))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "site-unit")

;; --- slugify ---------------------------------------------------------
(for-each (lambda (row) (test-equal (car row) (cdr row) (slugify (car row))))
          github-anchors)
;; GitHub keeps a spacing mark that is not a letter. github-slugger's
;; Spacing_Mark row shows it, but also holds code points newer than some
;; Chez's Unicode tables; GitHub's rule goes a character at a time, so
;; four of that row's marks stand here alone.
(test-equal "spacing marks that are not letters are kept"
  "a\xF3E;-\xF3F;-\x1B44;-\xA9C0;b" (slugify "a\xF3E; \xF3F; \x1B44; \xA9C0;b"))
(test-equal "backtick code in a heading is stripped to its text"
  "What make build does" (heading-text '(h2 "What " (code "make build") " does")))
(test-equal "the whole heading-to-slug path"
  "what-make-build-does"
  (slugify (heading-text '(h2 "What " (code "make build") " does"))))

;; --- make-slugger ----------------------------------------------------
(test-equal "duplicate headings get -1, -2 suffixes"
  '("options" "options-1" "options-2")
  (let ((s (make-slugger))) (list (s "Options") (s "Options") (s "Options"))))
(test-equal "a taken slug moves on to the next number, as GitHub numbers it"
  (map cdr github-repeats) (slug-each (make-slugger) (map car github-repeats)))
(test-equal "heading-text skips the ^ attr node and inline tags"
  "Some text" (heading-text '(h2 (^ (id "foo")) "Some " (code "text"))))

;; --- serializer ------------------------------------------------------
(test-equal "text is escaped on output, not before"
  "<p>a &amp; &lt;b&gt;</p>" (sxml->html '(p "a & <b>")))
(test-equal "text does not escape a double quote"
  "<p>say \"hi\"</p>" (sxml->html '(p "say \"hi\"")))
(test-equal "attributes render from the caret marker and are quoted"
  "<a href=\"/x\">l</a>" (sxml->html '(a (^ (href "/x")) "l")))
(test-equal "escape-attr turns a double quote into &quot;"
  "<a title=\"say &quot;hi&quot;\">l</a>"
  (sxml->html '(a (^ (title "say \"hi\"")) "l")))
(test-equal "escape-attr escapes & < > in an attribute value"
  "<a title=\"a&amp;b&lt;c&gt;d\">l</a>"
  (sxml->html '(a (^ (title "a&b<c>d")) "l")))
(test-equal "void elements have no body and no end tag"
  "<hr>" (sxml->html '(hr)))
(test-equal "*TOP* is a fragment: it emits its children only"
  "<h1>a</h1>\n<p>b</p>\n" (sxml->html '(*TOP* (h1 "a") (p "b"))))
(test-equal "indentation inside pre/code is content, preserved byte-for-byte"
  "<pre><code>(define (f x)\n    (g\n      x))\n</code></pre>"
  (sxml->html '(pre (code "(define (f x)\n    (g\n      x))\n"))))
(test-equal "a *COMMENT* node renders as an HTML comment, not a bogus tag"
  "<!-- raw HTML omitted -->" (sxml->html '(*COMMENT* " raw HTML omitted ")))

;; --- transform -------------------------------------------------------
(let-values (((body toc)
              (transform-body '(*TOP* (h2 "Node shape") (p "x") (h2 "Node shape")))))
  (test-equal "headings gain a caret id from their slug"
    '(*TOP* (h2 (^ (id "node-shape")) "Node shape") (p "x")
            (h2 (^ (id "node-shape-1")) "Node shape"))
    body)
  (test-equal "the toc lists (level text slug) in document order"
    '((2 "Node shape" "node-shape") (2 "Node shape" "node-shape-1"))
    toc))
(let-values (((body toc)
              (transform-body '(*TOP* (h1 "Title") (h3 "Detail")))))
  (test-equal "the toc reads each heading's level from its tag"
    '(1 3) (map car toc)))
(let-values (((body toc)
              (transform-body '(*TOP* (blockquote (p "⚠️ Answer quickly."))))))
  (test-equal "a warning-sign blockquote is rewrapped as a warning callout div"
    '(*TOP* (div (^ (class "callout warning")) (blockquote (p "⚠️ Answer quickly."))))
    body))
(let-values (((body toc)
              (transform-body '(*TOP* (blockquote (p "A plain note."))))))
  (test-equal "a blockquote without the warning sign is left as it is"
    '(*TOP* (blockquote (p "A plain note.")))
    body))

;; --- links -----------------------------------------------------------
(test-equal "doc .md link (with anchor) becomes .html, anchor kept"
  (link "bodies.html#streaming-a-download")
  (rw (link "bodies.md#streaming-a-download") "handlers.md"))
(test-equal "bare doc .md link becomes .html"
  (link "handlers.html") (rw (link "handlers.md") "bodies.md"))
(test-equal "a link to README.md becomes index.html"
  (link "index.html") (rw (link "README.md") "bodies.md"))
(test-equal "a link to README.md#… becomes index.html#…"
  (link "index.html#five-ideas-to-keep-in-mind")
  (rw (link "README.md#five-ideas-to-keep-in-mind") "bodies.md"))
(test-equal "a link to ./README.md becomes index.html"
  (link "index.html") (rw (link "./README.md") "bodies.md"))
(test-equal "a ./page.md link has its ./ stripped"
  (link "handlers.html#reading-a-request")
  (rw (link "./handlers.md#reading-a-request") "bodies.md"))
(test-equal "same-page anchor is left as-is"
  (link "#reading-a-request") (rw (link "#reading-a-request") "handlers.md"))
(test-equal "a ../ escape is pinned to the GitHub blob at the ref"
  (link "https://github.com/Kiyomi-Computation-Systems/jsonparse/blob/main/examples/echo.sps")
  (rw (link "../examples/echo.sps") "handlers.md"))
(test-equal "a ../ escape is pinned to the ref it is given"
  (link "https://github.com/Kiyomi-Computation-Systems/jsonparse/blob/v1.2.3/examples/echo.sps")
  (let-values (((b d) (rewrite-links (link "../examples/echo.sps") reg "handlers.md" "v1.2.3")))
    b))
(test-equal "an https URL is untouched, even one ending in .md"
  (link "https://example.com/README.md")
  (rw (link "https://example.com/README.md") "handlers.md"))
(test-equal "an http URL is untouched, even one ending in .md"
  (link "http://example.com/a.md") (rw (link "http://example.com/a.md") "handlers.md"))
(test-equal "a non-.md relative target is left untouched"
  (link "style.css") (rw (link "style.css") "handlers.md"))
(test-equal "text naming a page is not a link, untouched"
  '(*TOP* (pre (code "see handlers.md")))
  (rw '(*TOP* (pre (code "see handlers.md"))) "handlers.md"))
(test-equal "an href on a non-a/img element is left untouched"
  '(*TOP* (span (^ (href "bodies.md")) "x"))
  (rw '(*TOP* (span (^ (href "bodies.md")) "x")) "handlers.md"))
(test-equal "an img src is rewritten like an href"
  '(*TOP* (img (^ (src "index.html"))))
  (rw '(*TOP* (img (^ (src "README.md")))) "handlers.md"))

(test-equal "an anchor absent from the registry is reported as a dangler"
  '(("handlers.md" . "bodies.md#nonesuch"))
  (dangling "bodies.md#nonesuch" "handlers.md"))
(test-equal "a README.md anchor absent from the registry is a dangler"
  '(("handlers.md" . "README.md#nonesuch"))
  (dangling "README.md#nonesuch" "handlers.md"))
(test-equal "a bare .md link to a page absent from the registry is a dangler"
  '(("handlers.md" . "missing.md")) (dangling "missing.md" "handlers.md"))
(test-equal "an anchored .md link to a page absent from the registry is a dangler"
  '(("handlers.md" . "missing.md#foo")) (dangling "missing.md#foo" "handlers.md"))
(test-equal "a bare .md link to a page in the registry is not a dangler"
  '() (dangling "bodies.md" "handlers.md"))
(test-equal "a same-page anchor absent from the page is a dangler"
  '(("handlers.md" . "#gone")) (dangling "#gone" "handlers.md"))
(test-equal "danglers come back in document order"
  '(("handlers.md" . "#one") ("handlers.md" . "#two"))
  (let-values (((b d) (rewrite-links '(*TOP* (p (a (^ (href "#one")) "1")
                                                (a (^ (href "#two")) "2")))
                                     reg "handlers.md" "main")))
    d))

;; --- page-file-name --------------------------------------------------
(test-equal "README.md is written as index.html"
  "index.html" (page-file-name "README.md"))
(test-equal "another page's .md becomes .html"
  "handlers.html" (page-file-name "handlers.md"))

;; --- pages -----------------------------------------------------------
(test-equal "the home page comes first, the rest in the home page's Read next order"
  '("README.md" "installing.md" "easy.md" "tree.md" "writer.md" "sequence.md"
    "parser.md" "string.md" "reference.md")
  (map car pages))

;; --- template --------------------------------------------------------
(test-eq "the document is rooted at html" 'html
  (and (pair? doc-out) (eq? (car doc-out) '*TOP*) (car (cadr doc-out))))
(test-eq "the stylesheet is linked in head" 'linked
  (if (string-contains-sub? doc-html "<link rel=\"stylesheet\" href=\"style.css\">")
      'linked 'missing))
(test-eq "the current page is marked in the nav" 'marked
  (if (string-contains-sub?
       doc-html "<a href=\"handlers.html\" class=\"on\" aria-current=\"page\">")
      'marked 'unmarked))
(test-eq "the TOC lists the page's headings" 'listed
  (if (string-contains-sub? doc-html "href=\"#reading-a-request\"") 'listed 'missing))
(test-eq "the wordmark names jsonparse and links the home page" 'present
  (if (string-contains-sub?
       doc-html "<a class=\"mark\" href=\"index.html\">jsonparse</a>")
      'present 'missing))
(test-eq "the top bar links the repository" 'present
  (if (string-contains-sub?
       doc-html "href=\"https://github.com/Kiyomi-Computation-Systems/jsonparse\">Source code</a>")
      'present 'missing))
(test-equal "the head describes jsonparse, in its description and keywords"
  '(#t #t)
  (list (string-contains-sub?
         doc-html "<meta name=\"description\" content=\"A fast, strict JSON parser for R6RS Scheme, generated by byte-machine\">")
        (string-contains-sub?
         doc-html "<meta name=\"keywords\" content=\"json parser streaming json-lines scheme chez r6rs byte-machine\">")))
(test-eq "a README.md nav entry links index.html" 'present
  (if (string-contains-sub? doc-html "<a href=\"index.html\">Home</a>") 'present 'missing))
(test-equal "the embedded theme script survives serialization unescaped"
  '(#t #f #f #f)
  (list (string-contains-sub? doc-html "<script>(function(){var r=document.documentElement")
        (string-contains-sub? doc-html "&amp;")
        (string-contains-sub? doc-html "&lt;")
        (string-contains-sub? doc-html "&gt;")))
;; A browser that refuses the page storage (site data blocked, some
;; private modes) throws from localStorage.  Unguarded, that ends the
;; script before it wires the toggle, and the toggle does nothing.
(test-equal "the theme script reaches localStorage twice, each time inside a try block"
  '(2 ())
  (let ((js (script-of doc-html)))
    (list (length (offsets-of js "localStorage")) (unguarded-storage js))))
(test-eq "the mode toggle carries the knob icon" 'present
  (if (string-contains-sub? doc-html "class=\"knob\"") 'present 'missing))
(test-equal "the footer nav links the previous and next pages"
  '(#t #t #t)
  (list (string-contains-sub? doc-html "class=\"pagenav\"")
        (string-contains-sub?
         doc-html "<a href=\"index.html\"><span class=\"lbl\">Previous</span>")
        (string-contains-sub? doc-html "<a href=\"bodies.html\" class=\"next\">")))
(test-eq "a page with no neighbours has no footer nav" 'absent
  (if (string-contains-sub?
       (sxml->html (page->document '(("README.md" . "Home")) "README.md" "Home"
                                   '(*TOP* (h1 "Home")) '() #f #f))
       "class=\"pagenav\"")
      'present 'absent))

(test-end "site-unit")

(exit (suite-exit-status runner))
