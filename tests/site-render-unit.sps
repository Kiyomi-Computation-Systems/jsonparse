#!r6rs
;;; The docs site's whole pipeline, (site render), on small inputs: markdown
;;; through chez-cmark-gfm, headings slugged, links rewritten across pages,
;;; each page templated.  Imports (cmark gfm), which loads libcmark-gfm.  Not
;;; named test-*.sps, so `make test` does not run it; `make check-site` does.
;;; From the repository root:
;;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs:build/akku/chez-cmark-gfm/src \
;;;     chez --program tests/site-render-unit.sps
(import (rnrs) (srfi :64) (jsonparse-testing) (site render) (site serializer)
        (only (site pages) pages page-file-name))

;; string-contains-sub? : String String -> Boolean
(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; count-substring : String String -> Integer
;; Non-overlapping occurrences of NEEDLE in HAY.
(define (count-substring hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0) (count 0))
      (cond ((> (+ i n) h) count)
            ((string=? needle (substring hay i (+ i n))) (loop (+ i n) (+ count 1)))
            (else (loop (+ i 1) count))))))

;; page-html : SiteResult String -> String
(define (page-html r name)
  (sxml->html (cond ((assoc name (site-result-pages r)) => cdr)
                    (else (error 'site-render-unit "page missing" name)))))

;; Two pages; the home page links to a heading on easy.md, and
;; easy.md links back to the home page.  The anchor is only knowable
;; after easy.md is slugged.
(define inputs
  '(("README.md" . "# Home\n\nSee [reading](easy.md#reading-a-request).\n")
    ("easy.md" . "# Quickstart\n\n## Reading a request\n\ntext\n\n### The path\n\nmore text\n\n[home](README.md)\n")))

(define r (render-site inputs "main"))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "site-render-unit")

(test-equal "every input yields a page, in input order"
  '("README.md" "easy.md") (map car (site-result-pages r)))
(test-equal "the registry carries every one of a page's heading slugs, its h1 included"
  '("quickstart" "reading-a-request" "the-path")
  (cond ((assoc "easy.md" (site-result-registry r)) => cdr) (else 'missing)))
(test-equal "resolvable cross-page links, README.md among them, do not dangle"
  '() (site-result-leaked r))

(let ((html (page-html r "easy.md")))
  (test-eq "the rail links the h2 anchor" 'linked
    (if (string-contains-sub? html "href=\"#reading-a-request\"") 'linked 'missing))
  (test-eq "the rail does not link the h1 anchor" 'absent
    (if (string-contains-sub? html "href=\"#quickstart\"") 'present 'absent))
  (test-eq "an h3 remains a rendered link target" 'present
    (if (string-contains-sub? html "id=\"the-path\"") 'present 'missing))
  (test-eq "the rail lists h2 sections, not h3 details" 'absent
    (if (string-contains-sub? html "href=\"#the-path\"") 'present 'absent))
  (test-eqv "a link to README.md is written as index.html, beside the wordmark's"
    2 (count-substring html "href=\"index.html\""))
  (test-eq "no link keeps the README.md name" 'absent
    (if (string-contains-sub? html "README") 'present 'absent))
  (test-eq "the page's title is its nav label" 'present
    (if (string-contains-sub? html "<title>Whole documents and streams</title>") 'present 'missing)))

;; The home page is reached from the wordmark and the page text, not
;; listed as a nav item: only the wordmark links index.html on a page that
;; does not link it in its text.
(let ((html (page-html r "README.md")))
  (test-eqv "index.html is linked once on the home page: the wordmark, not a nav item"
    1 (count-substring html "href=\"index.html\""))
  (test-eq "the home page has no footer nav" 'absent
    (if (string-contains-sub? html "class=\"pagenav\"") 'present 'absent)))

;; Footer neighbours follow the nav's order: (site pages)'s pages, the home
;; page left out. pagenav-of cuts a page's footer out whole, and
;; expected-pagenav writes the one the page's place in that order calls for:
;; a link to each neighbour, labelled, or an empty span on a side with none.

;; pagenav-of : String -> (U String #f) — the footer div of HTML, whole.
(define (pagenav-of html)
  (let ((open "<div class=\"pagenav\">"))
    (let loop ((i 0))
      (cond ((> (+ i (string-length open)) (string-length html)) #f)
            ((string=? open (substring html i (+ i (string-length open))))
             (let find ((j i))
               (cond ((> (+ j 6) (string-length html)) #f)
                     ((string=? "</div>" (substring html j (+ j 6)))
                      (substring html i (+ j 6)))
                     (else (find (+ j 1))))))
            (else (loop (+ i 1)))))))

;; expected-pagenav : String -> String — the footer for NAME's place in the nav.
(define (expected-pagenav name)
  (let* ((nav (filter (lambda (p) (not (string=? (car p) "README.md"))) pages))
         (before (let loop ((ps nav) (prev #f))
                   (if (string=? (caar ps) name) prev (loop (cdr ps) (car ps)))))
         (after (let ((tail (member name (map car nav))))
                  (and (pair? (cdr tail)) (assoc (cadr tail) nav)))))
    (string-append
     "<div class=\"pagenav\">"
     (if before
         (string-append "<a href=\"" (page-file-name (car before))
                        "\"><span class=\"lbl\">Previous</span>\x2190; " (cdr before) "</a>")
         "<span></span>")
     (if after
         (string-append "<a href=\"" (page-file-name (car after))
                        "\" class=\"next\"><span class=\"lbl\">Next</span>" (cdr after) " \x2192;</a>")
         "<span></span>")
     "</div>")))

(let ((site (render-site '(("easy.md" . "# Whole documents\n")
                           ("tree.md" . "# Building values\n")
                           ("reference.md" . "# API reference\n"))
                         "main")))
  (test-equal "the first page's footer links the next page, and no previous"
    (expected-pagenav "easy.md") (pagenav-of (page-html site "easy.md")))
  (test-equal "a middle page's footer links the pages either side of it"
    (expected-pagenav "tree.md") (pagenav-of (page-html site "tree.md")))
  (test-equal "the last page's footer links the page before it, and no next"
    (expected-pagenav "reference.md") (pagenav-of (page-html site "reference.md"))))

;; A warning-led blockquote passes through the whole pipeline as a callout.
(let ((html (page-html (render-site '(("easy.md" . "> ⚠️ Answer quickly.\n")) "main")
                       "easy.md")))
  (test-eq "a warning blockquote is rendered inside a callout div" 'present
    (if (string-contains-sub? html "<div class=\"callout warning\"><blockquote>")
        'present 'missing)))

(test-equal "an unresolvable cross-page anchor is reported"
  '(("README.md" . "easy.md#gone"))
  (site-result-leaked
   (render-site '(("README.md" . "[x](easy.md#gone)\n")
                  ("easy.md" . "# Quickstart\n"))
                "main")))
(test-equal "an unresolvable README.md anchor is reported"
  '(("easy.md" . "README.md#gone"))
  (site-result-leaked
   (render-site '(("README.md" . "# Home\n")
                  ("easy.md" . "[x](README.md#gone)\n"))
                "main")))
(test-equal "danglers across pages come back in page order"
  '(("README.md" . "#a") ("easy.md" . "#b"))
  (site-result-leaked
   (render-site '(("README.md" . "[x](#a)\n") ("easy.md" . "[y](#b)\n"))
                "main")))

(test-end "site-render-unit")

(exit (suite-exit-status runner))
