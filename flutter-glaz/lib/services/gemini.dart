import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../frame/font.dart';
import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// A bookmark on the Gemini home page.
class Bookmark {
  const Bookmark(this.url, this.title);
  final String url;
  final String title;

  Map<String, String> toJson() => {'url': url, 'title': title};
}

/// The bookmarks until the user sets their own: those of Geopard, the
/// GNOME Gemini browser, as it comes.
const defaultBookmarks = [
  Bookmark('gemini://geminiprotocol.net', 'Gemini project'),
  Bookmark('gemini://warmedal.se/~antenna/', 'Antenna aggregator'),
];

/// The bookmarks set in Glaz > Menu > Gemini; [defaultBookmarks] until
/// then.
List<Bookmark> bookmarksOf(Settings settings) {
  final raw = settings.config('gemini', 'bookmarks');
  if (raw == null) return defaultBookmarks;
  try {
    return [
      for (final b in jsonDecode(raw) as List)
        Bookmark(
          (b as Map)['url'] as String? ?? '',
          b['title'] as String? ?? '',
        ),
    ];
  } catch (_) {
    return defaultBookmarks;
  }
}

void setBookmarks(Settings settings, List<Bookmark> list) => settings.setConfig(
  'gemini',
  'bookmarks',
  jsonEncode([for (final b in list) b]),
);

/// One line of a page as the glasses draw it: [kind] T text, H heading,
/// L link, Q quote, P preformatted; [link] the link's number on the page.
class GemLine {
  const GemLine(this.kind, this.text, [this.link]);
  final String kind;
  final String text;
  final int? link;

  String get wire => '$kind${link ?? ''}|$text';
}

/// A page cut into lines for the glasses, and where its links go.
class GemPage {
  GemPage(this.url, this.lines, this.links);
  final String url;
  final List<GemLine> lines;

  /// links[n - 1] is where link n goes.
  final List<String> links;
}

/// A Gemini server's answer: the status, its meta (a MIME type, a
/// redirect's target, an error's text) and the body.
typedef GeminiReply = ({int status, String meta, List<int> body});

typedef GeminiFetch = Future<GeminiReply> Function(Uri uri);

/// The page that is the bookmarks.
const homeUrl = 'about:home';

/// The phone's own links on every page: back where it came from, home.
const backLink = 0;
const homeLink = 65535;

/// The width a line may take on the glasses, in px: from where
/// modules/gemini.lua draws text (TEXT_X) to the screen's right edge, less
/// a little.
const lineWidth = 530;

/// Fetches [uri] from its Gemini server: TLS on port 1965, the URL and
/// CRLF, then a header line and the body. Any certificate is taken: Gemini
/// servers sign their own, and this browser only reads.
Future<GeminiReply> fetchGemini(Uri uri, {Duration? timeout}) async {
  timeout ??= GeminiService.timeout;
  final socket = await SecureSocket.connect(
    uri.host,
    uri.hasPort ? uri.port : 1965,
    onBadCertificate: (_) => true,
    timeout: timeout,
  );
  try {
    socket.add(utf8.encode('$uri\r\n'));
    await socket.flush();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in socket.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > GeminiService.maxPage) break;
    }
    final all = bytes.takeBytes();
    var end = 0;
    while (end + 1 < all.length && !(all[end] == 13 && all[end + 1] == 10)) {
      end++;
    }
    final header = utf8.decode(all.sublist(0, end), allowMalformed: true);
    final status = int.tryParse(
      header.length >= 2 ? header.substring(0, 2) : '',
    );
    if (status == null) throw const FormatException('not a Gemini answer');
    return (
      status: status,
      meta: header.length > 3 ? header.substring(3).trim() : '',
      body: end + 2 <= all.length ? all.sublist(end + 2) : const <int>[],
    );
  } finally {
    socket.destroy();
  }
}

/// Lines for the glasses from a page's parts, added one by one: wrapped
/// to [lineWidth], what the font lacks given a look-alike, one empty line
/// at most between blocks, none at the ends.
class _Lines {
  final lines = <GemLine>[];
  final links = <String>[];

  void blank() {
    if (lines.isNotEmpty && lines.last.text.isNotEmpty) {
      lines.add(const GemLine('T', ''));
    }
  }

  void add(String kind, String text, {int? link, String indent = ''}) {
    for (final l in wrapToWidth(forGlasses(text), lineWidth, indent: indent)) {
      lines.add(GemLine(kind, l, link));
    }
  }

  void pre(String text) {
    final l = cutToWidth(
      forGlasses(text).replaceAll('\t', '  '),
      lineWidth,
      mark: false,
    );
    lines.add(GemLine('P', l));
  }

  void link(String url, String label) {
    links.add(url);
    add('L', label, link: links.length);
  }

  List<GemLine> done() {
    while (lines.isNotEmpty && lines.last.text.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }
}

/// Where a page lives, short: 'host/path'.
String shortUrl(String url) =>
    url.replaceFirst(RegExp(r'^gemini://'), '').replaceFirst(RegExp(r'/$'), '');

/// [text], gemtext from [base], as lines for the glasses (docs/PROTOCOL.md,
/// "Gemini"): '< back' and where it is first, '< back' and 'home' last.
GemPage gemtextPage(String base, String text, {bool plain = false}) {
  final out = _Lines();
  _top(out, base);
  var pre = false;
  final uri = Uri.parse(base);
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimRight();
    if (!plain && line.startsWith('```')) {
      pre = !pre;
      continue;
    }
    if (plain || pre) {
      if (pre) {
        out.pre(line);
      } else if (line.trim().isEmpty) {
        out.blank();
      } else {
        out.add('T', line);
      }
      continue;
    }
    if (line.trim().isEmpty) {
      out.blank();
    } else if (line.startsWith('=>')) {
      final m = RegExp(r'^=>\s*(\S+)\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      final target = _resolve(uri, m[1]!);
      final label = m[2]!.isNotEmpty ? m[2]! : m[1]!;
      final web = target.startsWith('gemini://') ? '' : ' [${_scheme(target)}]';
      out.link(target, '$label$web');
    } else if (line.startsWith('#')) {
      out.add('H', line.replaceFirst(RegExp(r'^#+\s*'), ''));
    } else if (line.startsWith('* ')) {
      out.add('T', '- ${line.substring(2).trim()}', indent: '  ');
    } else if (line.startsWith('>')) {
      out.add('Q', line.substring(1).trim());
    } else {
      out.add('T', line);
    }
  }
  return _withEnd(out, base);
}

/// A page that only says something: an error, a redirect gone wrong.
GemPage notePage(String base, String title, [String text = '']) {
  final out = _Lines();
  _top(out, base);
  out.add('H', title);
  if (text.isNotEmpty) out.add('T', text);
  return _withEnd(out, base);
}

/// The bookmarks, as the home page.
GemPage homePage(List<Bookmark> bookmarks) {
  final out = _Lines();
  out.add('H', 'Bookmarks');
  for (final b in bookmarks) {
    if (b.url.trim().isEmpty) continue;
    out.link(b.url.trim(), b.title.trim().isEmpty ? shortUrl(b.url) : b.title);
  }
  if (out.links.isEmpty) out.add('T', 'None yet: Glaz > Menu > Gemini.');
  return GemPage(homeUrl, out.done(), out.links);
}

void _top(_Lines out, String base) {
  out.lines.add(const GemLine('L', '< back', backLink));
  out.add('Q', shortUrl(base));
  out.blank();
}

GemPage _withEnd(_Lines out, String base) {
  final lines = out.done();
  lines
    ..add(const GemLine('T', ''))
    ..add(const GemLine('L', '< back', backLink))
    ..add(const GemLine('L', 'home', homeLink));
  return GemPage(base, lines, out.links);
}

String _resolve(Uri base, String ref) {
  try {
    return base.resolve(ref).toString();
  } catch (_) {
    return ref;
  }
}

String _scheme(String url) {
  final i = url.indexOf(':');
  return i > 0 ? url.substring(0, i) : 'link';
}

/// The Gemini browser's phone side (docs/PROTOCOL.md, "Gemini"): fetches
/// the pages modules/gemini.lua opens, keeps the one open and the way
/// back, and hands the glasses its lines a few dozen at a time. The home
/// page is the bookmarks, set in Glaz > Menu > Gemini.
class GeminiService extends ChangeNotifier {
  GeminiService(this.link, this.settings, {GeminiFetch? fetch})
    : _fetch = fetch ?? fetchGemini {
    link.events
        .where((m) => m.isNotEmpty && m[0] == geminiGet)
        .listen(onRequest);
    settings.addListener(_bookmarksChanged);
  }

  final FrameLink link;
  final Settings settings;
  final GeminiFetch _fetch;

  static const timeout = Duration(seconds: 15);

  /// At most this much of a page is read: the glasses page through it,
  /// but a phone's memory is not endless either.
  static const maxPage = 512 * 1024;

  /// At most this much text in one answer: a MODULE_CALL the glasses put
  /// together in memory.
  static const maxBytes = 900;

  /// At most this many lines in one answer.
  static const maxLines = 40;

  /// Lines sent above the one asked to show first.
  static const before = 8;

  static const _redirects = 5;
  static const _cached = 8;

  GemPage? _page;
  int _id = 0;
  int _top = 0;
  int _seq = 0;
  final _history = <(String, int)>[];
  final _cache = <String, GemPage>{};
  String _home = '';

  /// The page open on the glasses; null before they asked for one.
  String? get url => _page?.url;

  void _bookmarksChanged() {
    final now = jsonEncode([for (final b in bookmarksOf(settings)) b]);
    if (now == _home) return;
    _home = now;
    // the home page open: built again, under a new number, so the glasses
    // take it as another page the next time they ask
    if (_page?.url == homeUrl) _show(homePage(bookmarksOf(settings)), _top);
  }

  void _show(GemPage page, int top) {
    _page = page;
    _id = _id % 255 + 1;
    _top = top.clamp(0, page.lines.length);
    notifyListeners();
  }

  /// [0x0D, op, page, n (2), top (2)]: op 1 opens link n of the page, op 2
  /// asks for its lines from n; top is the line the glasses show first.
  @visibleForTesting
  Future<void> onRequest(List<int> m) async {
    if (m.length < 7) return;
    final b = ByteData.sublistView(Uint8List.fromList(m));
    final op = b.getUint8(1);
    final page = b.getUint8(2);
    final n = b.getUint16(3);
    final top = b.getUint16(5);
    if (page == _id && _page != null) _top = top;
    if (_page == null) _show(homePage(bookmarksOf(settings)), 0);
    if (page != _id) {
      // the glasses hold another page than the one open here: this one,
      // where it was left
      return _send(_from(_top));
    }
    if (op == 2) return _send(n);
    if (op != 1) return;
    if (n == backLink) return back();
    if (n == homeLink) return open(homeUrl);
    final links = _page!.links;
    if (n >= 1 && n <= links.length) return open(links[n - 1]);
  }

  int _from(int top) => top > before ? top - before : 0;

  Future<void> _send(int from) => link.callModule('gemini', answer(from));

  /// MODULE_CALL's argument for modules/gemini.lua:
  /// 'p:page:from:total:top:back' and a line each, as many as fit; back is
  /// 1 when there is a page to go back to, so the glasses' double tap goes
  /// there rather than out of Gemini.
  @visibleForTesting
  String answer(int from) {
    final lines = _page?.lines ?? const <GemLine>[];
    final start = from.clamp(0, lines.length);
    final back = _page != null && _page!.url != homeUrl ? 1 : 0;
    final out = StringBuffer('p:$_id:$start:${lines.length}:$_top:$back');
    var bytes = out.length;
    for (var i = start; i < lines.length && i < start + maxLines; i++) {
      final l = '\n${lines[i].wire}';
      final size = utf8.encode(l).length;
      if (bytes + size > maxBytes) break;
      out.write(l);
      bytes += size;
    }
    return out.toString();
  }

  /// Opens [target] on the glasses, from where it starts; the page left is
  /// the way back.
  Future<void> open(String target) async {
    final seq = ++_seq;
    final page = await load(target);
    if (seq != _seq) return; // another was asked for since
    if (_page != null) _history.add((_page!.url, _top));
    if (_history.length > 50) _history.removeAt(0);
    _show(page, 0);
    await _send(0);
  }

  /// Back to the page before, where it was left; home with none.
  Future<void> back() async {
    final seq = ++_seq;
    final (target, top) = _history.isEmpty
        ? (homeUrl, 0)
        : _history.removeLast();
    final page = _cache[target] ?? await load(target);
    if (seq != _seq) return;
    _show(page, top);
    await _send(_from(_top));
  }

  /// [target] as lines for the glasses: the page, or one saying why not.
  @visibleForTesting
  Future<GemPage> load(String target) async {
    if (target == homeUrl) return homePage(bookmarksOf(settings));
    final asked = Uri.tryParse(target);
    if (asked == null || !asked.isScheme('gemini')) {
      return notePage(
        target,
        'Not a Gemini page',
        'Open it on the phone: $target',
      );
    }
    if (!settings.serviceOn('network') || !settings.netAllowed('gemini')) {
      return notePage(target, 'No Internet', 'Allow it: Glaz > Menu > Gemini.');
    }
    var uri = asked;
    try {
      for (var i = 0; i <= _redirects; i++) {
        final r = await _fetch(uri).timeout(timeout * 2);
        final kind = r.status ~/ 10;
        if (kind == 3) {
          uri = uri.resolve(r.meta);
          continue;
        }
        final page = _pageOf(uri.toString(), r);
        if (kind == 2) _remember(page);
        return page;
      }
      return notePage(target, 'Too many redirects');
    } catch (e) {
      return notePage(target, 'Cannot open it', '$e');
    }
  }

  GemPage _pageOf(String url, GeminiReply r) {
    switch (r.status ~/ 10) {
      case 1:
        return notePage(url, 'It asks for input', r.meta);
      case 2:
        final mime = r.meta.isEmpty ? 'text/gemini' : r.meta.toLowerCase();
        if (!mime.startsWith('text/')) {
          return notePage(url, 'Cannot show it', mime);
        }
        final text = mime.contains('iso-8859-1')
            ? latin1.decode(r.body)
            : utf8.decode(r.body, allowMalformed: true);
        return gemtextPage(url, text, plain: !mime.startsWith('text/gemini'));
      case 6:
        return notePage(url, 'It wants a certificate', r.meta);
      default:
        return notePage(url, 'Error ${r.status}', r.meta);
    }
  }

  void _remember(GemPage page) {
    _cache.remove(page.url);
    _cache[page.url] = page;
    if (_cache.length > _cached) _cache.remove(_cache.keys.first);
  }

  @override
  void dispose() {
    settings.removeListener(_bookmarksChanged);
    super.dispose();
  }
}
