/*
 * bench/JacksonBench.java: Jackson's side of the benchmarks (ADR-0013,
 * ADR-0023, ADR-0024).
 *
 *   java -cp jackson-core.jar:DIR JacksonBench ROUNDS ROUND-BYTES FILE...
 *
 * Two lanes per file, parse then events, over the file's bytes in memory:
 *
 *   parse   nextToken() until null, tracking only the nesting depth and the
 *           count of root values so that trailing values fail the pass
 *   events  the same loop, counting the ten names by token. number-bytes is
 *           getTextLength() of a number token (number text is ASCII).
 *           text-bytes is the UTF-8 length of each string's and field
 *           name's decoded text, worked out from its chars (a surrogate
 *           pair is 4 bytes), read through getTextCharacters() with
 *           getTextOffset() and getTextLength(): the parser's own buffer,
 *           no String made.
 *
 * One JsonFactory at its defaults for the whole run; a new JsonParser per
 * pass from createParser(byte[]), closed at the pass's end. A pass fails
 * unless the input is exactly one JSON value: Jackson reads on past the
 * root value, so a second root value or no value at all is an error here.
 * Warm-up round, then ROUNDS timed rounds by System.nanoTime(), a
 * System.gc() before each outside the timing. No JVM flags.
 */
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import com.fasterxml.jackson.core.json.PackageVersion;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;

public class JacksonBench {
  static final int NULL = 0, TRUE = 1, FALSE = 2, NUMBER = 3, STRING = 4, KEY = 5,
      OBJECT = 6, ARRAY = 7, NUMBER_BYTES = 8, TEXT_BYTES = 9;
  static final String[] NAMES = {"null", "true", "false", "number", "string", "key",
      "object", "array", "number-bytes", "text-bytes"};

  static final JsonFactory FACTORY = new JsonFactory();
  /** Passes finished since the last reset. */
  static long passes;

  static void die(String msg) {
    System.err.println("JacksonBench: " + msg);
    System.exit(1);
  }

  static IOException bad(String msg) { return new IOException(msg); }

  /** Bytes of the UTF-8 encoding of the chars, a surrogate pair being 4. */
  static long utf8Length(char[] cs, int off, int len) {
    long n = 0;
    int end = off + len;
    for (int i = off; i < end; i++) {
      char c = cs[i];
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (Character.isHighSurrogate(c) && i + 1 < end && Character.isLowSurrogate(cs[i + 1])) {
        n += 4;
        i++;
      } else n += 3;
    }
    return n;
  }

  /** One parse pass. COUNTS is null for the parse lane. */
  static void pass(byte[] data, long[] counts) throws IOException {
    int depth = 0;
    int roots = 0;
    try (JsonParser p = FACTORY.createParser(data)) {
      JsonToken t;
      while ((t = p.nextToken()) != null) {
        switch (t) {
          case START_OBJECT:
            if (depth == 0) roots++;
            depth++;
            if (counts != null) counts[OBJECT]++;
            break;
          case START_ARRAY:
            if (depth == 0) roots++;
            depth++;
            if (counts != null) counts[ARRAY]++;
            break;
          case END_OBJECT:
          case END_ARRAY:
            depth--;
            break;
          case FIELD_NAME:
            if (counts != null) {
              counts[KEY]++;
              counts[TEXT_BYTES] += utf8Length(p.getTextCharacters(), p.getTextOffset(), p.getTextLength());
            }
            break;
          case VALUE_STRING:
            if (depth == 0) roots++;
            if (counts != null) {
              counts[STRING]++;
              counts[TEXT_BYTES] += utf8Length(p.getTextCharacters(), p.getTextOffset(), p.getTextLength());
            }
            break;
          case VALUE_NUMBER_INT:
          case VALUE_NUMBER_FLOAT:
            if (depth == 0) roots++;
            if (counts != null) {
              counts[NUMBER]++;
              counts[NUMBER_BYTES] += p.getTextLength();
            }
            break;
          case VALUE_TRUE:
            if (depth == 0) roots++;
            if (counts != null) counts[TRUE]++;
            break;
          case VALUE_FALSE:
            if (depth == 0) roots++;
            if (counts != null) counts[FALSE]++;
            break;
          case VALUE_NULL:
            if (depth == 0) roots++;
            if (counts != null) counts[NULL]++;
            break;
          default:
            throw bad("unexpected token " + t);
        }
      }
    }
    if (roots != 1) throw bad(roots + " root values");
    passes++;
  }

  static void putString(StringBuilder sb, String s) {
    sb.append('"');
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (c == '"' || c == '\\') sb.append('\\');
      sb.append(c < 0x20 ? ' ' : c);
    }
    sb.append('"');
  }

  static long positive(String s, String what) {
    try {
      if (s.isEmpty() || s.charAt(0) < '0' || s.charAt(0) > '9') throw new NumberFormatException();
      long v = Long.parseLong(s);
      if (v <= 0) throw new NumberFormatException();
      return v;
    } catch (NumberFormatException e) {
      die(what + " is not a positive integer: " + s);
      return 0;
    }
  }

  static void countsForm(StringBuilder sb, String head, long[] c) {
    sb.append(" (").append(head);
    for (int k = 0; k < NAMES.length; k++) sb.append(" (").append(NAMES[k]).append(" . ").append(c[k]).append(")");
    sb.append(")");
  }

  public static void main(String[] argv) throws Exception {
    if (argv.length < 3) die("usage: JacksonBench ROUNDS ROUND-BYTES FILE...");
    long rounds = positive(argv[0], "ROUNDS");
    long roundBytes = positive(argv[1], "ROUND-BYTES");
    StringBuilder sb = new StringBuilder();
    sb.append("(runtime (parser jackson) (version ");
    putString(sb, "jackson-core " + PackageVersion.VERSION + ", OpenJDK " + Runtime.version());
    sb.append(") (how ");
    putString(sb, "JVM defaults, no flags; one JsonFactory at its defaults, a JsonParser per pass");
    sb.append(") (rounds ").append(rounds).append(") (round-bytes ").append(roundBytes).append("))");
    System.out.println(sb);

    for (int f = 2; f < argv.length; f++) {
      String path = argv[f];
      String name = Paths.get(path).getFileName().toString();
      byte[] data = Files.readAllBytes(Paths.get(path));
      if (data.length == 0) die("empty: " + path);
      long iterations = (roundBytes + data.length - 1) / data.length;

      for (int lane = 0; lane < 2; lane++) {
        boolean counted = lane == 1;
        String laneName = counted ? "events" : "parse";
        System.err.println("JacksonBench: " + name + " " + laneName);
        long[] counts = new long[10];
        try {
          pass(data, counted ? counts : null);
        } catch (Exception e) {
          sb.setLength(0);
          sb.append("(failure (file ");
          putString(sb, name);
          sb.append(") (parser jackson) (lane ").append(laneName).append(") (reason ");
          String m = String.valueOf(e.getMessage());
          int nl = m.indexOf('\n');
          putString(sb, e.getClass().getSimpleName() + ": " + (nl >= 0 ? m.substring(0, nl) : m));
          sb.append("))");
          System.out.println(sb);
          continue;
        }
        long[] timed = new long[10];
        passes = 0;
        try {
          for (long i = 0; i < iterations; i++) pass(data, counted ? timed : null);
          long[] ns = new long[(int) rounds];
          for (int r = 0; r < rounds; r++) {
            System.gc();
            long t0 = System.nanoTime();
            for (long i = 0; i < iterations; i++) pass(data, counted ? timed : null);
            ns[r] = System.nanoTime() - t0;
          }
          sb.setLength(0);
          sb.append("(result (file ");
          putString(sb, name);
          sb.append(") (bytes ").append(data.length).append(") (parser jackson) (lane ").append(laneName)
              .append(") (iterations ").append(iterations).append(") (round-ns");
          for (long n : ns) sb.append(' ').append(n);
          sb.append(")");
          if (counted) countsForm(sb, "counts", counts); else sb.append(" (counts)");
          sb.append(" (passes ").append(passes).append(")");
          if (counted) countsForm(sb, "timed-counts", timed);
          sb.append(")");
          System.out.println(sb);
        } catch (Exception e) {
          die(name + " " + laneName + ": " + e);
        }
      }
    }
  }
}
