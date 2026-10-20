// Text for the glasses' display, made here, on the phone. The firmware's
// font (our build, v26.292 and later: docs/FIRMWARE.md) has ASCII, Latin-1,
// Cyrillic and a few signs; what it has is kept as it is, so Cyrillic stays
// Cyrillic. Common typography it lacks gets a look-alike, Latin letters it
// lacks lose their marks, emoji are dropped, anything else becomes '?'.
// The result goes to the glasses as UTF-8.

/// Whether the font has a glyph for [c] (system_font.h in the firmware).
bool hasGlyph(int c) =>
    c == 0x0A ||
    (c >= 0x20 && c < 0x7F) ||
    (c >= 0xA1 && c <= 0xFF && !_latin1Gaps.contains(c)) ||
    (c >= 0x400 && c <= 0x45F) ||
    _cyrillicExtra.contains(c) ||
    _signs.contains(c);

// U+00A1..U+00FF the font does not have
const _latin1Gaps = {
  0xA4, 0xA6, 0xA7, 0xA8, 0xAA, 0xAC, 0xAD, 0xAF, 0xB2, 0xB3, 0xB4, 0xB6, //
  0xB8, 0xB9, 0xBA, 0xBC, 0xBD, 0xBE,
};

// beyond U+045F: Kazakh, Tatar, Bashkir, Yakut, Tajik, Uzbek, Ukrainian Ґ
const _cyrillicExtra = {
  0x490, 0x491, 0x492, 0x493, 0x494, 0x495, 0x496, 0x497, 0x498, 0x499, //
  0x49A, 0x49B, 0x4A0, 0x4A1, 0x4A2, 0x4A3, 0x4A4, 0x4A5, 0x4AA, 0x4AB, //
  0x4AE, 0x4AF, 0x4B0, 0x4B1, 0x4B2, 0x4B3, 0x4B6, 0x4B7, 0x4BA, 0x4BB, //
  0x4C0, 0x4C1, 0x4C2, 0x4CF, 0x4D0, 0x4D1, 0x4D6, 0x4D7, 0x4D8, 0x4D9, //
  0x4E2, 0x4E3, 0x4E8, 0x4E9, 0x4EE, 0x4EF, 0x4F2, 0x4F3,
};

const _signs = {
  0x131, 0x141, 0x142, 0x152, 0x153, 0x160, 0x161, 0x178, 0x17D, 0x17E, //
  0x192, 0x20AC, 0x2116,
};

// What the font lacks, by what it has
const _map = {
  'ś': 's',
  'ź': 'z',
  'ż': 'z',
  'č': 'c',
  'ř': 'r',
  'ě': 'e',
  'ą': 'a',
  'ę': 'e',
  'ć': 'c',
  'ń': 'n',
  'ő': 'o',
  'ű': 'u',
  'ğ': 'g',
  'ş': 's',
  '“': '"',
  '”': '"',
  '„': '"',
  '‘': "'",
  '’': "'",
  '‚': "'",
  '‹': '<',
  '›': '>',
  '–': '-',
  '—': '-',
  '−': '-',
  '‐': '-',
  '…': '...',
  '•': '·',
  ' ': ' ',
  '­': '',
  ' ': ' ',
  ' ': ' ',
  ' ': ' ',
};

bool _isEmoji(int c) =>
    (c >= 0x1F000 && c <= 0x1FAFF) ||
    (c >= 0x2600 && c <= 0x27BF) ||
    (c >= 0xFE00 && c <= 0xFE0F) ||
    c == 0x200D;

String forGlasses(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (hasGlyph(rune)) {
      out.writeCharCode(rune);
      continue;
    }
    if (rune == 0x09) {
      out.write(' ');
      continue;
    }
    if (_isEmoji(rune) || rune < 0x20) continue;
    final ch = String.fromCharCode(rune);
    final lower = ch.toLowerCase();
    final mapped = _map[ch] ?? _map[lower];
    if (mapped == null) {
      out.write('?');
    } else if (ch != lower) {
      out.write(mapped.toUpperCase());
    } else {
      out.write(mapped);
    }
  }
  return out.toString().replaceAll(RegExp(r'\?{2,}'), '?');
}

/// The longest start of [s] that is at most [max] bytes in UTF-8, cut
/// between characters.
String cutToBytes(String s, int max) {
  var bytes = 0;
  var end = 0;
  for (final rune in s.runes) {
    final n = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes + n > max) break;
    bytes += n;
    end += rune > 0xFFFF ? 2 : 1;
  }
  return s.substring(0, end);
}
