/*
 * bench/yajl-bench.c: yajl's side of the benchmarks (ADR-0013, ADR-0023).
 *
 *   yajl-bench ROUNDS ROUND-BYTES FILE...
 *
 * For each file, read into memory first, two lanes, as bench/run.sps runs
 * jsonparse's:
 *
 *   parse   yajl with no callbacks: it checks the text, UTF-8 included,
 *           and decodes nothing
 *   events  callbacks counting each value by kind, and the bytes of every
 *           number's text and every string's and key's decoded text, as
 *           (jsonparse-bench)'s counting handler counts
 *
 * Each lane makes a new handle per parse, as jsonparse makes a new parser,
 * and fails the run unless the parse succeeds. A round parses the file
 * enough times to read at least ROUND-BYTES, the same count
 * (jsonparse-bench)'s iterations-for gives. One warm-up round, then ROUNDS
 * timed ones, by CLOCK_MONOTONIC.
 *
 * It prints a runtime form, then a result form per file and lane, in the
 * shape (jsonparse-bench report) reads: one pass's counts, taken first and
 * outside the timing, then the passes the rounds finished, the warm-up's
 * included, and for events what they counted, summed. BENCH_CFLAGS names
 * the flags this harness was built with; libyajl is whatever pkg-config
 * found.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <yajl/yajl_parse.h>
#include <yajl/yajl_version.h>

#ifndef BENCH_CFLAGS
#define BENCH_CFLAGS "unknown"
#endif

#if defined(__clang__)
#define COMPILER "clang " __clang_version__
#elif defined(__GNUC__)
#define COMPILER "gcc " __VERSION__
#else
#define COMPILER "an unknown compiler"
#endif

enum { NUL, TRU, FALS, NUMBER, STRING, KEY, OBJECT, ARRAY, NUMBER_BYTES, TEXT_BYTES, COUNTS };
static const char *count_names[COUNTS] = {
  "null", "true", "false", "number", "string", "key", "object", "array",
  "number-bytes", "text-bytes"
};

static int on_null(void *c) { ((long *)c)[NUL]++; return 1; }
static int on_boolean(void *c, int b) { ((long *)c)[b ? TRU : FALS]++; return 1; }
static int on_number(void *c, const char *s, size_t n) {
  long *k = c; (void)s; k[NUMBER]++; k[NUMBER_BYTES] += (long)n; return 1;
}
static int on_string(void *c, const unsigned char *s, size_t n) {
  long *k = c; (void)s; k[STRING]++; k[TEXT_BYTES] += (long)n; return 1;
}
static int on_key(void *c, const unsigned char *s, size_t n) {
  long *k = c; (void)s; k[KEY]++; k[TEXT_BYTES] += (long)n; return 1;
}
static int on_start_map(void *c) { ((long *)c)[OBJECT]++; return 1; }
static int on_start_array(void *c) { ((long *)c)[ARRAY]++; return 1; }

/* In yajl_callbacks' order: null, boolean, integer, double, number, string,
   start_map, map_key, end_map, start_array, end_array. */
static yajl_callbacks counting = {
  on_null, on_boolean, NULL, NULL, on_number, on_string,
  on_start_map, on_key, NULL, on_start_array, NULL
};
static yajl_callbacks none;

/* The parses that have succeeded since the last reset. */
static unsigned long passes;

static void die(const char *what, const char *detail) {
  fprintf(stderr, "yajl-bench: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
  exit(1);
}

/* Writes S as a Scheme string literal. */
static void put_string(const char *s) {
  putchar('"');
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') putchar('\\');
    putchar(*s);
  }
  putchar('"');
}

static void parse_once(yajl_callbacks *cbs, long *counts,
                       const unsigned char *text, size_t size, const char *name) {
  yajl_handle h = yajl_alloc(cbs, NULL, counts);
  if (!h) die("yajl_alloc failed", NULL);
  if (yajl_parse(h, text, size) != yajl_status_ok
      || yajl_complete_parse(h) != yajl_status_ok) {
    unsigned char *msg = yajl_get_error(h, 0, text, size);
    fprintf(stderr, "yajl-bench: %s: %s\n", name, (const char *)msg);
    exit(1);
  }
  yajl_free(h);
  passes++;
}

static long long now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static unsigned long parse_count(const char *s, const char *what) {
  char *end;
  unsigned long v;
  if (*s < '0' || *s > '9') die(what, s);
  errno = 0;
  v = strtoul(s, &end, 10);
  if (errno || *end != '\0' || v == 0) die(what, s);
  return v;
}

static const char *basename_of(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

int main(int argc, char **argv) {
  unsigned long rounds, round_bytes;
  int v = yajl_version();
  char version[32];
  int f;

  if (argc < 4) die("usage: yajl-bench ROUNDS ROUND-BYTES FILE...", NULL);
  rounds = parse_count(argv[1], "ROUNDS is not a positive integer");
  round_bytes = parse_count(argv[2], "ROUND-BYTES is not a positive integer");

  snprintf(version, sizeof version, "%d.%d.%d", v / 10000, v / 100 % 100, v % 100);
  printf("(runtime (parser yajl) (version ");
  put_string(version);
  printf(") (compiler ");
  put_string(COMPILER);
  printf(") (flags ");
  put_string(BENCH_CFLAGS);
  printf(") (rounds %lu) (round-bytes %lu))\n", rounds, round_bytes);

  for (f = 3; f < argc; f++) {
    const char *path = argv[f], *name = basename_of(path);
    FILE *in = fopen(path, "rb");
    unsigned char *text;
    long size;
    unsigned long iterations, r, i;
    int lane;

    if (!in) die("cannot open", path);
    if (fseek(in, 0, SEEK_END) != 0 || (size = ftell(in)) <= 0 || fseek(in, 0, SEEK_SET) != 0)
      die("cannot size, or empty", path);
    text = malloc((size_t)size);
    if (!text || fread(text, 1, (size_t)size, in) != (size_t)size) die("cannot read", path);
    fclose(in);
    iterations = (round_bytes + (unsigned long)size - 1) / (unsigned long)size;

    for (lane = 0; lane < 2; lane++) {
      yajl_callbacks *cbs = lane == 0 ? &none : &counting;
      long counts[COUNTS] = {0}, scratch[COUNTS] = {0};
      long long *ns = malloc(rounds * sizeof *ns);
      if (!ns) die("out of memory", NULL);

      fprintf(stderr, "yajl-bench: %s %s\n", name, lane == 0 ? "parse" : "events");
      parse_once(cbs, counts, text, (size_t)size, name);
      passes = 0;
      for (i = 0; i < iterations; i++) parse_once(cbs, scratch, text, (size_t)size, name);
      for (r = 0; r < rounds; r++) {
        long long t0 = now_ns();
        for (i = 0; i < iterations; i++) parse_once(cbs, scratch, text, (size_t)size, name);
        ns[r] = now_ns() - t0;
      }

      printf("(result (file ");
      put_string(name);
      printf(") (bytes %ld) (parser yajl) (lane %s) (iterations %lu) (round-ns",
             size, lane == 0 ? "parse" : "events", iterations);
      for (r = 0; r < rounds; r++) printf(" %lld", ns[r]);
      printf(") (counts");
      if (lane == 1) {
        int k;
        for (k = 0; k < COUNTS; k++) printf(" (%s . %ld)", count_names[k], counts[k]);
      }
      printf(") (passes %lu)", passes);
      if (lane == 1) {
        int k;
        printf(" (timed-counts");
        for (k = 0; k < COUNTS; k++) printf(" (%s . %ld)", count_names[k], scratch[k]);
        printf(")");
      }
      printf(")\n");
      free(ns);
    }
    free(text);
  }
  return 0;
}
