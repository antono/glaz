// The glasses' font is ASCII only, so text for the display is converted
// here, on the phone: Cyrillic is transliterated, common typography gets its
// ASCII look-alike, emoji are dropped, anything else becomes '?'.

const _map = {
  'а': 'a',
  'б': 'b',
  'в': 'v',
  'г': 'g',
  'д': 'd',
  'е': 'e',
  'ё': 'e',
  'ж': 'zh',
  'з': 'z',
  'и': 'i',
  'й': 'y',
  'к': 'k',
  'л': 'l',
  'м': 'm',
  'н': 'n',
  'о': 'o',
  'п': 'p',
  'р': 'r',
  'с': 's',
  'т': 't',
  'у': 'u',
  'ф': 'f',
  'х': 'kh',
  'ц': 'ts',
  'ч': 'ch',
  'ш': 'sh',
  'щ': 'shch',
  'ъ': '',
  'ы': 'y',
  'ь': '',
  'э': 'e',
  'ю': 'yu',
  'я': 'ya',
  'і': 'i',
  'ї': 'yi',
  'є': 'ye',
  'ґ': 'g',
  'ў': 'u',
  'ä': 'a',
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'å': 'a',
  'ã': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ø': 'o',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ñ': 'n',
  'ç': 'c',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
  'ł': 'l',
  'ś': 's',
  'ź': 'z',
  'ż': 'z',
  'č': 'c',
  'š': 's',
  'ž': 'z',
  'ř': 'r',
  'ě': 'e',
  'ą': 'a',
  'ę': 'e',
  'ć': 'c',
  'ń': 'n',
  '«': '"',
  '»': '"',
  '“': '"',
  '”': '"',
  '„': '"',
  '‘': "'",
  '’': "'",
  '–': '-',
  '—': '-',
  '−': '-',
  '…': '...',
  '•': '*',
  '·': '.',
  '№': 'No',
  '°': '',
  '\u00a0': ' ',
  '\u2009': ' ',
  '\u202f': ' ',
};

bool _isEmoji(int c) =>
    (c >= 0x1F000 && c <= 0x1FAFF) ||
    (c >= 0x2600 && c <= 0x27BF) ||
    (c >= 0xFE00 && c <= 0xFE0F) ||
    c == 0x200D;

String toAscii(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x0A || (rune >= 0x20 && rune < 0x7F)) {
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
    } else if (ch != lower && mapped.isNotEmpty) {
      // capital: capitalise the first letter only ('Щ' -> 'Shch')
      out.write(mapped[0].toUpperCase() + mapped.substring(1));
    } else {
      out.write(mapped);
    }
  }
  return out.toString().replaceAll(RegExp(r'\?{2,}'), '?');
}
