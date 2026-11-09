/*
 * bench/simdjson-bench.cc: simdjson's side of the benchmarks (ADR-0013,
 * ADR-0024).
 *
 *   simdjson-bench ROUNDS ROUND-BYTES FILE...
 *
 * Two lanes per file:
 *
 *   tree       dom::parser::parse of a padded_string: the DOM
 *   tree+walk  the same, then a walk of the dom::element counting the nine
 *              names (strings' and keys' decoded bytes)
 *
 * One dom::parser per lane, reused for every pass, as simdjson's
 * documentation advises; one padded_string per file, made outside the
 * timing. A bigint, which simdjson 4 keeps as a digit string, counts as a
 * number.
 */
#include "bench-harness.h"
#include <simdjson.h>

using namespace simdjson;

struct state {
  padded_string text;
  dom::parser parsers[2];
  state(const unsigned char *t, size_t n) : text((const char *)t, n) {}
};

static void prepare(bench_file *f) { f->user = new state(f->text, f->size); }
static void release(bench_file *f) { delete (state *)f->user; }

static const char *walk(dom::element e, long *k) {
  switch (e.type()) {
  case dom::element_type::ARRAY: {
    dom::array a;
    if (e.get(a)) return "not an array";
    k[B_ARRAY]++;
    for (dom::element c : a) {
      const char *why = walk(c, k);
      if (why) return why;
    }
    return NULL;
  }
  case dom::element_type::OBJECT: {
    dom::object o;
    if (e.get(o)) return "not an object";
    k[B_OBJECT]++;
    for (dom::key_value_pair p : o) {
      const char *why;
      k[B_KEY]++;
      k[B_TEXT_BYTES] += (long)p.key.size();
      why = walk(p.value, k);
      if (why) return why;
    }
    return NULL;
  }
  case dom::element_type::STRING: {
    std::string_view s;
    if (e.get(s)) return "not a string";
    k[B_STRING]++;
    k[B_TEXT_BYTES] += (long)s.size();
    return NULL;
  }
  case dom::element_type::BOOL: {
    bool b;
    if (e.get(b)) return "not a bool";
    k[b ? B_TRUE : B_FALSE]++;
    return NULL;
  }
  case dom::element_type::NULL_VALUE:
    k[B_NULL]++;
    return NULL;
  default:
    k[B_NUMBER]++;
    return NULL;
  }
}

static const char *pass(bench_file *f, long *counts, int lane) {
  dom::element root;
  error_code err = ((state *)f->user)->parsers[lane].parse(((state *)f->user)->text).get(root);
  if (err) return error_message(err);
  return lane == 0 ? NULL : walk(root, counts);
}
static const char *tree_pass(bench_file *f, long *c) { return pass(f, c, 0); }
static const char *walk_pass(bench_file *f, long *c) { return pass(f, c, 1); }

int main(int argc, char **argv) {
  static const bench_lane lanes[2] = {
    {"tree", tree_pass, 0}, {"tree+walk", walk_pass, 9}
  };
  char how[512];
  snprintf(how, sizeof how,
           "%s %s; dom::parser reused per lane, padded_string once per file; "
           "implementation %s; defaults",
           BENCH_COMPILER, BENCH_CFLAGS, get_active_implementation()->name().c_str());
  return bench_main(argc, argv, "simdjson", SIMDJSON_VERSION, how, lanes, 2, prepare, release);
}
