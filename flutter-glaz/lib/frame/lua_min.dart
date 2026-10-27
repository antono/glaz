/// Shrinks Lua source for the glasses: comments out, and each line's
/// leading and trailing blanks. Every line break stays, so line N here is
/// line N in the repository: the compiled code is byte for byte the same
/// (test/lua_min_test.dart), and a line number in an error on the glasses
/// points at the right line.
///
/// It matters for more than upload time. Frame's require() reads the whole
/// file into memory before compiling it (lua_file_require in the firmware's
/// file.c), so comments cost heap at the worst moment: glaz.lua with
/// its comments ran the glasses out of memory on start. Strings, including
/// long [[ ]] and [==[ ]==] ones, are copied untouched: '--:--' in a string
/// is not a comment.
///
/// A line longer than [maxLine] is broken at a blank, or after , ; ( ) { },
/// outside any string:
/// the glasses read a file a line at a time, at most 512 bytes a read
/// (LUAL_BUFFERSIZE on their 32-bit build), and compiling on them goes
/// through those reads (upload.dart). Only already-minified one-line files
/// (lib/*.min.lua) have such lines.
String minifyLua(String src, {int maxLine = 400}) {
  final out = StringBuffer();
  final line = StringBuffer();
  var i = 0;
  final n = src.length;

  void endLine() {
    out.writeln(line.toString().trim());
    line.clear();
  }

  // Length of a long bracket's '=' run at [at] ('[' then '='* then '['),
  // or -1 when there is none.
  int longLevel(int at) {
    if (at >= n || src[at] != '[') return -1;
    var j = at + 1;
    while (j < n && src[j] == '=') {
      j++;
    }
    return j < n && src[j] == '[' ? j - at - 1 : -1;
  }

  // Index just past the long bracket closing level [level], from [from].
  int longEnd(int from, int level) {
    final close = ']${'=' * level}]';
    final k = src.indexOf(close, from);
    return k < 0 ? n : k + close.length;
  }

  while (i < n) {
    final c = src[i];
    if (c == '-' && i + 1 < n && src[i + 1] == '-') {
      // a comment: long, to its closing bracket; short, to the end of line
      final level = longLevel(i + 2);
      if (level >= 0) {
        final end = longEnd(i + 2 + level + 2, level);
        // a long comment may span lines; keep each break it held
        for (final ch in src.substring(i, end).split('')) {
          if (ch == '\n') endLine();
        }
        i = end;
      } else {
        while (i < n && src[i] != '\n') {
          i++;
        }
      }
      continue;
    }
    if (c == '[') {
      final level = longLevel(i);
      if (level >= 0) {
        // a long string: verbatim, line breaks and all
        final end = longEnd(i + level + 2, level);
        line.write(src.substring(i, end));
        i = end;
        continue;
      }
    }
    if (c == '"' || c == "'") {
      // a short string: to the matching quote, minding escapes
      var j = i + 1;
      while (j < n && src[j] != c && src[j] != '\n') {
        j += src[j] == '\\' ? 2 : 1;
      }
      final end = j < n && src[j] == c ? j + 1 : j;
      line.write(src.substring(i, end));
      i = end;
      continue;
    }
    if (c == '\n') {
      endLine();
      i++;
      continue;
    }
    final ch = c == '\r' || c == '\t' ? ' ' : c;
    if (ch == ' ' && line.length >= maxLine) {
      endLine(); // a blank between tokens: a line break is just as good
    } else {
      line.write(ch);
      // or right after punctuation that ends a token, for lines with no
      // blank to break at; to Lua a line break is only white space
      if (line.length >= maxLine && ',;(){}'.contains(ch)) endLine();
    }
    i++;
  }
  if (line.isNotEmpty) endLine();
  return out.toString();
}
