# Installing

jsonparse is a set of R6RS libraries with one dependency, byte-machine's
runtime. There is nothing to compile.

## What you need

- **Chez Scheme 10.4.1 or later,** on Linux or macOS. The examples call it
  `scheme`; Homebrew on macOS names it `chez`.
- The libraries import only `(rnrs)` and byte-machine's runtime, so another
  R6RS Scheme may work, but none is tested.

## From a checkout

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/jsonparse.git
```

The submodule `vendor/byte-machine` holds the runtime. Already cloned
without `--recursive`? Run `git submodule update --init`, or `make
submodules`.

Two folders go on Chez's library path, `src/` and `vendor/byte-machine/src`:

```sh
cd jsonparse
scheme --libdirs src:vendor/byte-machine/src --program app.sps
```

Or set them once for the shell:

```sh
export CHEZSCHEMELIBDIRS=$PWD/src:$PWD/vendor/byte-machine/src
```

In the checkout, `make dev` starts a REPL with the libraries on the path,
and `make run PROGRAM=app.sps` runs a program.

## With Akku, soon

The Akku package is ready, but not yet published. Once it is, this installs
it in your project's directory:

```sh
akku install jsonparse
. .akku/bin/activate
scheme --program app.sps
```

- **`akku install jsonparse`** adds jsonparse to your `Akku.manifest`, making
  one if there is none, and puts it and byte-machine under `.akku/lib`.
- **`.akku/bin/activate`** points Chez's library path at `.akku/lib` for
  this shell.

## A first program

```scheme
(import (rnrs) (jsonparse easy))

(display (json->string (string->json "[1, {\"a\": null}]")))
(newline)
```

It prints `[1,{"a":null}]`. [The home page](README.md) shows more, and
[Whole documents and streams](easy.md) explains it.
