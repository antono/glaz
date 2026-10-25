// Widths of the glasses' font, to cut text into lines that fit their
// screen here, on the phone. The same table as modules/reader.lua (from
// system_font.h in the firmware): per glyph, the byte minus 48 is its
// advance in px, 0 for none; the firmware puts [spacing] between glyphs.

import 'glyphs.dart';

const _ascii =
    '=5=CARD5:;EC8A60B@@?B?A?BA68CCC>OFB@CAABC<>C@GCDBFDADCEGEGA9?:DI;CB=B@?DB5;B8LBBBB;?>ACNDD@<5<A'; // ' ' to '~'
const _latin1 =
    '06>B0F000L0A00M0?D000A06000A000>FGGGGGP@A@AA<;@?FCDDDDDBDCCCCCFBCCCCCCCM>A@AA;;@?B@BBBABCBAA@ADBD'; // U+00A0..U+00FF
const _cyrillic =
    'AAH?AA<?>PPHCDECF@B?FAP@DDCDGCDCB@DEHEDALNEG@AMBCCB=F@P@BBCCHABAB=BDIDDAKNEF@@LBAAF=@?5?;MLFCBCC'; // U+0400..U+045F

/// The firmware's gap between glyphs.
const spacing = 4;

/// The font's other Cyrillic (Kazakh, Tatar..): as wide as an 'o'.
const _otherW = 18;

/// The font's emoji: as wide as the widest of them, so a line never overflows.
const _emojiW = 40;

/// Advance of code point [c], gap included; 0 for none.
int glyphWidth(int c) {
  String t;
  int base;
  if (c >= 32 && c <= 126) {
    t = _ascii;
    base = 32;
  } else if (c >= 0xA0 && c <= 0xFF) {
    t = _latin1;
    base = 0xA0;
  } else if (c >= 0x400 && c <= 0x45F) {
    t = _cyrillic;
    base = 0x400;
  } else if (c >= 0x490 && c <= 0x4FF) {
    return _otherW + spacing;
  } else if (isFontEmoji(c)) {
    return _emojiW + spacing;
  } else {
    return 0;
  }
  final w = t.codeUnitAt(c - base) - 48;
  return w > 0 ? w + spacing : 0;
}

/// How wide [s] is drawn, in px.
int textWidth(String s) {
  var w = 0;
  for (final c in s.runes) {
    w += glyphWidth(c);
  }
  return w;
}

/// [s] cut to at most [px] wide; ending in '..' when [mark] and it was cut.
String cutToWidth(String s, int px, {bool mark = true}) {
  if (textWidth(s) <= px) return s;
  final room = mark ? px - textWidth('..') : px;
  final out = StringBuffer();
  var w = 0;
  for (final c in s.runes) {
    final g = glyphWidth(c);
    if (w + g > room) break;
    out.writeCharCode(c);
    w += g;
  }
  return mark ? '${out.toString().trimRight()}..' : out.toString();
}

/// [text] in lines at most [px] wide, broken between words; a word wider
/// than a line is cut. The lines after the first start with [indent].
List<String> wrapToWidth(String text, int px, {String indent = ''}) {
  final lines = <String>[];
  var line = '';
  for (var word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final lead = lines.isEmpty ? '' : indent;
    final joined = line.isEmpty ? '$lead$word' : '$line $word';
    if (textWidth(joined) <= px) {
      line = joined;
      continue;
    }
    if (line.isNotEmpty) {
      lines.add(line);
      line = '';
    }
    // a word too wide for a line of its own: cut into pieces that fit
    while (textWidth('$indent$word') > px) {
      final head = cutToWidth('$indent$word', px, mark: false);
      lines.add(head);
      word = word.substring(head.length - indent.length);
    }
    line = lines.isEmpty ? word : '$indent$word';
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}
