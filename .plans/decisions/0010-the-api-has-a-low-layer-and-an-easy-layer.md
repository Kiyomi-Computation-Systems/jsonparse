# ADR-0010: The API has a low layer and an easy layer

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** jsonparse's libraries and what each one exports
- **Related:** plan §7 questions 6 and 8; ADR-0003, ADR-0006, ADR-0007,
  ADR-0011, ADR-0014; uriparse ADR-0040, which this follows

## Context

jsonparse has two kinds of caller:

- **Servers, streams and large inputs** feed bytes in chunks. They want no
  allocation they didn't ask for, byte offsets, and results instead of
  exceptions.
- **Config files, API responses, scripts and tests** have a whole document and
  want a value, or an exception when it is bad.

uriparse serves the same two with two layers. Its low layer takes bytes, reuses
its collectors and returns results with byte offsets. `(uri easy)` takes
strings, returns a validated record and raises `&uri-error` with a character
offset. Every easy export composes low-layer exports, and nothing below easy
imports it. uriparse holds that rule with a comment; no check enforces it.

JSON differs in one way: a JSON value is plain Scheme data (ADR-0006). uriparse
needs an opaque record and a copy between its layers. jsonparse needs neither.

A textual port decodes before a parser sees the bytes. Measured on
2026-10-30, reading the bytes `"`, `#xFF`, `"` through a UTF-8 textual port:

- **Chez 10.4.0** reads U+FFFD in place of `#xFF`. `make-transcoder` defaults
  to the `replace` error-handling mode, as R6RS says.
- **Guile 3.0.11** warns "transcoders not implemented" and reads U+00FF.

Either way the text is wrong and no error is raised.

## Decision

1. **The low layer.** It takes bytes, counts offsets in bytes, and never
   raises on bad input.
   - **`(jsonparse parser)`** is the push parser. It takes byte chunks and calls
     a handler. Strings and numbers arrive as ranges of the caller's chunk, never
     copied. A parser is reusable, and its options, such as the depth limit, are
     set when it is made. Every result carries a code and a byte offset. Its
     exports are jsonparse's own names, so callers never import
     `(byte-machine runtime)`.
   - **`(jsonparse string)`** assembles strings and numbers from those ranges,
     with one growable buffer per parser. It converts numbers (ADR-0011).
   - **`(jsonparse tree)`** builds values as the input streams in, with the
     options in ADR-0006 and ADR-0011.
   - **`(jsonparse writer)`** writes values as UTF-8 to a binary port. It
     refuses what JSON can't express (ADR-0007).
   - **`(jsonparse sequence)`** reads streams of many values: JSON Lines,
     RFC 7464 and whitespace-separated values (ADR-0014).
   - Supporting libraries, such as the options record and `&json-error`, also
     sit in this layer.
2. **The easy layer is `(jsonparse easy)`.** Every export composes low-layer
   exports.
   - **Reading:** `string->json`, `bytevector->json` and `read-json` read one
     whole value. Anything after it but whitespace is an error.
   - **Writing:** `json->string`, `json->bytevector` and `write-json`, with an
     option to pretty-print.
   - **Conveniences:** `json-ref` for paths such as
     `(json-ref v "users" 0 "name")`, `json=?` and `json-null?`.
   - **Errors raise `&json-error`,** with a reason (the low layer's code) and an
     offset. The offset counts characters for a string and bytes for a
     bytevector or a port.
   - **Options** are an optional last argument: the same options record the low
     layer takes. Leaving it out means the defaults.
3. **Ports are binary in both layers.** A textual port may already have hidden
   invalid UTF-8. A caller with a string calls `string->json`.
4. **Imports go one way, held by a check.** The import check (ADR-0003) fails
   if any library under `src/` imports `(jsonparse easy)`.
5. **Both layers return the same values.** There is no easy-only record and no
   copy between the layers.
6. **The writer lands in M1, beside the reader.** The easy layer needs both
   directions.

## Consequences

- **There are two surfaces to keep in agreement.** As uriparse does, the
  conformance vectors (JSONTestSuite `y_` and `n_`) run through both layers.
- **`&json-error` is defined below the easy layer,** so the writer can raise
  it, and easy re-exports it.
- **A byte-machine ABI bump doesn't change jsonparse's API,** because no
  runtime type is exported.
- **M1 grows by the writer and the easy layer.** M4 keeps the leniency options
  and, if wanted, a streaming generator from events.
