/*
 * bench/rapidjson-bench.cc: RapidJSON's side of the benchmarks (ADR-0013,
 * ADR-0024).
 *
 *   rapidjson-bench ROUNDS ROUND-BYTES FILE...
 *
 * Two lanes per file, as bench/yajl-bench.c's:
 *
 *   parse   rapidjson::Reader with a handler that does nothing
 *   events  a handler counting each value by kind, and the bytes of every
 *           number's text and every string's and key's decoded text
 *
 * Both parse with kParseNumbersAsStringsFlag: numbers reach RawNumber as
 * text, unconverted, as yajl and jsonparse hand them over. Otherwise
 * RapidJSON's defaults, so it does not check UTF-8. A new Reader per pass,
 * over a StringStream on a NUL-terminated copy made once, outside the timing.
 */
#include "bench-harness.h"
#include <rapidjson/reader.h>
#include <rapidjson/stream.h>

using namespace rapidjson;

static const unsigned kFlags = kParseNumbersAsStringsFlag;

struct NullHandler : BaseReaderHandler<UTF8<>, NullHandler> {
  bool Default() { return true; }
};

struct CountHandler {
  long *k;
  explicit CountHandler(long *counts) : k(counts) {}
  bool Null() { k[B_NULL]++; return true; }
  bool Bool(bool b) { k[b ? B_TRUE : B_FALSE]++; return true; }
  bool Int(int) { return true; }
  bool Uint(unsigned) { return true; }
  bool Int64(int64_t) { return true; }
  bool Uint64(uint64_t) { return true; }
  bool Double(double) { return true; }
  bool RawNumber(const char *, SizeType n, bool) {
    k[B_NUMBER]++; k[B_NUMBER_BYTES] += (long)n; return true;
  }
  bool String(const char *, SizeType n, bool) {
    k[B_STRING]++; k[B_TEXT_BYTES] += (long)n; return true;
  }
  bool StartObject() { k[B_OBJECT]++; return true; }
  bool Key(const char *, SizeType n, bool) {
    k[B_KEY]++; k[B_TEXT_BYTES] += (long)n; return true;
  }
  bool EndObject(SizeType) { return true; }
  bool StartArray() { k[B_ARRAY]++; return true; }
  bool EndArray(SizeType) { return true; }
};

static const char *parse_pass(bench_file *f, long *) {
  Reader reader;
  StringStream ss((const char *)f->text);
  NullHandler h;
  return reader.Parse<kFlags>(ss, h) ? NULL : "RapidJSON rejects the text";
}

static const char *events_pass(bench_file *f, long *counts) {
  Reader reader;
  StringStream ss((const char *)f->text);
  CountHandler h(counts);
  return reader.Parse<kFlags>(ss, h) ? NULL : "RapidJSON rejects the text";
}

int main(int argc, char **argv) {
  static const bench_lane lanes[2] = {
    {"parse", parse_pass, 0}, {"events", events_pass, 10}
  };
  char how[512];
  snprintf(how, sizeof how,
           "%s %s; Reader over a StringStream, new per pass; "
           "kParseNumbersAsStringsFlag, otherwise defaults: no UTF-8 check",
           BENCH_COMPILER, BENCH_CFLAGS);
  return bench_main(argc, argv, "rapidjson", RAPIDJSON_VERSION_STRING, how, lanes, 2,
                    NULL, NULL);
}
