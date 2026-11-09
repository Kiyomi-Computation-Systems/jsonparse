/*
 * bench/yyjson-bench.c: yyjson's side of the benchmarks (ADR-0013,
 * ADR-0024).
 *
 *   yyjson-bench ROUNDS ROUND-BYTES FILE...
 *
 * Two lanes per file:
 *
 *   tree       yyjson_read with default flags, then yyjson_doc_free
 *   tree+walk  the same, with a walk of the document counting the nine
 *              names (strings' and keys' decoded bytes) before the free
 */
#include "bench-harness.h"
#include <yyjson.h>

static void walk(yyjson_val *v, long *k) {
  switch (yyjson_get_type(v)) {
  case YYJSON_TYPE_NULL: k[B_NULL]++; break;
  case YYJSON_TYPE_BOOL: k[yyjson_get_bool(v) ? B_TRUE : B_FALSE]++; break;
  case YYJSON_TYPE_NUM: k[B_NUMBER]++; break;
  case YYJSON_TYPE_STR:
    k[B_STRING]++; k[B_TEXT_BYTES] += (long)yyjson_get_len(v); break;
  case YYJSON_TYPE_ARR: {
    size_t i, max;
    yyjson_val *c;
    k[B_ARRAY]++;
    yyjson_arr_foreach(v, i, max, c) walk(c, k);
    break;
  }
  case YYJSON_TYPE_OBJ: {
    size_t i, max;
    yyjson_val *key, *val;
    k[B_OBJECT]++;
    yyjson_obj_foreach(v, i, max, key, val) {
      k[B_KEY]++;
      k[B_TEXT_BYTES] += (long)yyjson_get_len(key);
      walk(val, k);
    }
    break;
  }
  default: break;
  }
}

static const char *pass(bench_file *f, long *counts, int walking) {
  yyjson_read_err err;
  yyjson_doc *doc = yyjson_read_opts((char *)f->text, f->size, 0, NULL, &err);
  if (!doc) return err.msg ? err.msg : "yyjson rejects the text";
  if (walking) walk(yyjson_doc_get_root(doc), counts);
  yyjson_doc_free(doc);
  return NULL;
}
static const char *tree_pass(bench_file *f, long *c) { return pass(f, c, 0); }
static const char *walk_pass(bench_file *f, long *c) { return pass(f, c, 1); }

int main(int argc, char **argv) {
  static const bench_lane lanes[2] = {
    {"tree", tree_pass, 0}, {"tree+walk", walk_pass, 9}
  };
  char how[512];
  snprintf(how, sizeof how,
           "%s %s; yyjson_read, default flags, then yyjson_doc_free in every pass",
           BENCH_COMPILER, BENCH_CFLAGS);
  return bench_main(argc, argv, "yyjson", YYJSON_VERSION_STRING, how, lanes, 2, NULL, NULL);
}
