/*
 * bench/bench-harness.h: what the native comparators' harnesses share
 * (ADR-0023, ADR-0024). Only rapidjson-bench.cc, simdjson-bench.cc and
 * yyjson-bench.c include it, and each includes it once.
 *
 * It holds the command line, the file reading, the monotonic clock, the
 * method (first pass, warm-up round, timed rounds, passes) and the forms
 * written, in the shape (jsonparse-bench report) reads. A harness gives it
 * its lanes: a name, a pass, and what the pass counts.
 *
 * A pass returns NULL when it succeeded, or a short reason. It adds what
 * it counted to the array it is given, which has ten slots in BENCH_NAMES'
 * order. The nine-name lanes leave number-bytes alone and it is not printed.
 */
#ifndef BENCH_HARNESS_H
#define BENCH_HARNESS_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef BENCH_CFLAGS
#define BENCH_CFLAGS "unknown"
#endif

#if defined(__clang__)
#define BENCH_COMPILER "clang " __clang_version__
#elif defined(__GNUC__)
#define BENCH_COMPILER "gcc " __VERSION__
#else
#define BENCH_COMPILER "an unknown compiler"
#endif

enum { B_NULL, B_TRUE, B_FALSE, B_NUMBER, B_STRING, B_KEY, B_OBJECT, B_ARRAY,
       B_NUMBER_BYTES, B_TEXT_BYTES, B_COUNTS };
static const char *const bench_names[B_COUNTS] = {
  "null", "true", "false", "number", "string", "key", "object", "array",
  "number-bytes", "text-bytes"
};

/* A file read into memory, NUL-terminated after SIZE bytes. USER is the
   harness's, made by its prepare hook. */
typedef struct bench_file {
  const char *name;
  unsigned char *text;
  size_t size;
  void *user;
} bench_file;

/* counted: 0 counts nothing; 9 counts all but number-bytes; 10 counts all. */
typedef struct bench_lane {
  const char *name;
  const char *(*pass)(bench_file *, long *counts);
  int counted;
} bench_lane;

static void bench_die(const char *what, const char *detail) {
  fprintf(stderr, "bench: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
  exit(1);
}

/* Writes S as a Scheme string literal. */
static void bench_put_string(const char *s) {
  putchar('"');
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') putchar('\\');
    putchar(*s == '\n' ? ' ' : *s);
  }
  putchar('"');
}

static long long bench_now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static unsigned long bench_parse_count(const char *s, const char *what) {
  char *end;
  unsigned long v;
  if (*s < '0' || *s > '9') bench_die(what, s);
  errno = 0;
  v = strtoul(s, &end, 10);
  if (errno || *end != '\0' || v == 0) bench_die(what, s);
  return v;
}

static const char *bench_basename(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

static int bench_counts_names(int counted, int k) {
  return !(counted == 9 && k == B_NUMBER_BYTES);
}

static void bench_print_counts(const long *c, int counted) {
  int k;
  for (k = 0; k < B_COUNTS; k++)
    if (bench_counts_names(counted, k)) printf(" (%s . %ld)", bench_names[k], c[k]);
}

/*
 * Runs the method over argv's files. PREPARE and RELEASE, either may be
 * NULL, run around each file's lanes. Returns main's status.
 */
static int bench_main(int argc, char **argv, const char *parser,
                      const char *version, const char *how,
                      const bench_lane *lanes, int nlanes,
                      void (*prepare)(bench_file *), void (*release)(bench_file *)) {
  unsigned long rounds, round_bytes;
  int f;

  if (argc < 4) bench_die("usage: HARNESS ROUNDS ROUND-BYTES FILE...", NULL);
  rounds = bench_parse_count(argv[1], "ROUNDS is not a positive integer");
  round_bytes = bench_parse_count(argv[2], "ROUND-BYTES is not a positive integer");

  printf("(runtime (parser %s) (version ", parser);
  bench_put_string(version);
  printf(") (how ");
  bench_put_string(how);
  printf(") (rounds %lu) (round-bytes %lu))\n", rounds, round_bytes);

  for (f = 3; f < argc; f++) {
    const char *path = argv[f];
    FILE *in = fopen(path, "rb");
    bench_file file;
    long size;
    unsigned long iterations, r, i;
    int l;

    if (!in) bench_die("cannot open", path);
    if (fseek(in, 0, SEEK_END) != 0 || (size = ftell(in)) <= 0 || fseek(in, 0, SEEK_SET) != 0)
      bench_die("cannot size, or empty", path);
    file.name = bench_basename(path);
    file.size = (size_t)size;
    file.user = NULL;
    file.text = (unsigned char *)malloc(file.size + 1);
    if (!file.text || fread(file.text, 1, file.size, in) != file.size) bench_die("cannot read", path);
    file.text[file.size] = '\0';
    fclose(in);
    iterations = (round_bytes + (unsigned long)size - 1) / (unsigned long)size;
    if (prepare) prepare(&file);

    for (l = 0; l < nlanes; l++) {
      const bench_lane *lane = &lanes[l];
      long counts[B_COUNTS] = {0}, scratch[B_COUNTS] = {0};
      unsigned long passes = 0;
      long long *ns = (long long *)malloc(rounds * sizeof *ns);
      const char *why;
      if (!ns) bench_die("out of memory", NULL);

      fprintf(stderr, "bench: %s %s %s\n", parser, file.name, lane->name);
      why = lane->pass(&file, counts);
      if (why) {
        printf("(failure (file ");
        bench_put_string(file.name);
        printf(") (parser %s) (lane %s) (reason ", parser, lane->name);
        bench_put_string(why);
        printf("))\n");
        free(ns);
        continue;
      }
      for (i = 0; i < iterations; i++) {
        why = lane->pass(&file, scratch);
        if (why) bench_die(why, file.name);
        passes++;
      }
      for (r = 0; r < rounds; r++) {
        long long t0 = bench_now_ns();
        for (i = 0; i < iterations; i++) {
          why = lane->pass(&file, scratch);
          if (why) bench_die(why, file.name);
          passes++;
        }
        ns[r] = bench_now_ns() - t0;
      }

      printf("(result (file ");
      bench_put_string(file.name);
      printf(") (bytes %ld) (parser %s) (lane %s) (iterations %lu) (round-ns",
             size, parser, lane->name, iterations);
      for (r = 0; r < rounds; r++) printf(" %lld", ns[r]);
      printf(") (counts");
      if (lane->counted) bench_print_counts(counts, lane->counted);
      printf(") (passes %lu)", passes);
      if (lane->counted) {
        printf(" (timed-counts");
        bench_print_counts(scratch, lane->counted);
        printf(")");
      }
      printf(")\n");
      free(ns);
    }
    if (release) release(&file);
    free(file.text);
  }
  return 0;
}

#endif
