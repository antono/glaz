import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import 'glaz_log.dart';

/// What a piece of Lua gave back: what it printed and returned, or its
/// error.
class LuaAnswer {
  const LuaAnswer(this.ok, this.text);
  final bool ok;
  final String text;
}

/// Runs Lua inside the app on the glasses while it runs: LUA_EVAL asks,
/// LUA_RESULT answers in packets (docs/PROTOCOL.md, "Lua console"). The
/// first byte of an answer is '+', or '-' and the error.
class GlassesLua {
  GlassesLua(this.link) {
    link.events
        .where((m) => m.length >= 3 && m[0] == luaResult)
        .listen(onPacket);
  }

  final FrameLink link;

  /// Lua that runs longer than this, or an app on the glasses that does
  /// not know LUA_EVAL, gets no answer.
  static const timeout = Duration(seconds: 15);

  static const _noAnswer =
      'No answer from the glasses. Their app may be older than this one: '
      'Upload it (Glasses tab), then try again.';

  int _next = 0;
  final _pending = <int, (BytesBuilder, Completer<Uint8List>)>{};

  /// [code, id, more, bytes...]
  @visibleForTesting
  void onPacket(List<int> m) {
    final entry = _pending[m[1]];
    if (entry == null) return; // given up on
    entry.$1.add(m.sublist(3));
    if (m[2] == 0) {
      _pending.remove(m[1]);
      entry.$2.complete(entry.$1.takeBytes());
    }
  }

  /// Runs [code] on the glasses. Throws when there is no answer.
  Future<LuaAnswer> run(String code) async {
    if (!link.connected) throw Exception('The glasses are not connected.');
    _next = _next % 255 + 1;
    final id = _next;
    final done = Completer<Uint8List>();
    _pending[id] = (BytesBuilder(), done);
    try {
      await link.send(luaEval, [id, ...utf8.encode(code)]);
      final bytes = await done.future.timeout(timeout);
      if (bytes.isEmpty) throw Exception('no answer');
      return LuaAnswer(
        bytes[0] == 0x2B,
        utf8.decode(bytes.sublist(1), allowMalformed: true),
      );
    } on TimeoutException {
      throw Exception(_noAnswer);
    } finally {
      _pending.remove(id);
    }
  }

  // one question a table, even while it is still being answered
  final _keys = <String, Future<List<String>>>{};

  /// Forgets the names [completions] learned: the glasses' globals change.
  void forget() => _keys.clear();

  /// What may follow the name before the cursor in [before]: whole names,
  /// each ending in '(' for a function and '.' for a table. Asked of the
  /// glasses, a table at a time, and kept.
  Future<List<String>> completions(String before) async {
    final (table, part) = splitName(before) ?? (null, null);
    if (part == null) return const [];
    final key = table ?? '_G';
    final List<String> names;
    try {
      names = await (_keys[key] ??= _names(key));
    } catch (_) {
      _keys.remove(key); // not connected, say: ask again next time
      return const [];
    }
    return [
      for (final n in names)
        if (n.startsWith(part) && n != part)
          '${table == null ? '' : '$table.'}$n',
    ];
  }

  Future<List<String>> _names(String table) async {
    final a = await run(
      'local t=$table if type(t)~="table" then return end local o={} '
      'for k,v in pairs(t) do if type(k)=="string" then '
      'o[#o+1]=k..(type(v)=="function" and "(" or '
      'type(v)=="table" and "." or "") end end '
      'table.sort(o) print(table.concat(o," "))',
    );
    if (!a.ok) return const [];
    return a.text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }
}

/// The name being typed at the end of [before]: the table it is in (null
/// for a global) and what of it is typed so far; null when the cursor is
/// not after a name or a dot.
@visibleForTesting
(String?, String)? splitName(String before) {
  final m = RegExp(
    r'([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)?(\.?)([A-Za-z_][A-Za-z0-9_]*)?$',
  ).firstMatch(before);
  if (m == null) return null;
  final head = m[1] ?? '';
  final dot = m[2]!.isNotEmpty;
  final tail = m[3] ?? '';
  if (dot) {
    if (head.isEmpty) return null;
    return (head, tail);
  }
  // no dot after the chain: its last part is what is typed
  if (head.isEmpty) return null;
  final i = head.lastIndexOf('.');
  if (i < 0) return (null, head);
  return (head.substring(0, i), head.substring(i + 1));
}

/// The Lua console for a computer: an HTTP server on the phone's own
/// loopback, reached through `adb forward` (utils/phone_lua.py). Nothing on
/// the network can reach it. On while [Settings.luaBridge] is.
///
///   POST /lua         the body is Lua; 200 with the answer, 422 with the
///                     error, 503 with no glasses
///   GET  /complete?q= the names that may follow q, one a line
class LuaBridge {
  LuaBridge(this.settings, this.lua) {
    settings.addListener(_apply);
    _apply();
  }

  final Settings settings;
  final GlassesLua lua;

  static const port = 8137;

  HttpServer? _server;
  bool _changing = false;

  bool get running => _server != null;

  Future<void> _apply() async {
    if (_changing || settings.luaBridge == running) return;
    _changing = true;
    try {
      if (settings.luaBridge) {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _server!.listen(_serve);
        glazLog(LogKind.task, 'Lua console on 127.0.0.1:$port');
      } else {
        await _server?.close(force: true);
        _server = null;
        glazLog(LogKind.task, 'Lua console closed');
      }
    } catch (e) {
      glazLog(LogKind.task, 'Lua console: $e', problem: true);
    } finally {
      _changing = false;
    }
    // the setting may have changed again meanwhile
    if (settings.luaBridge != running) unawaited(_apply());
  }

  Future<void> _serve(HttpRequest request) async {
    final out = request.response..headers.contentType = ContentType.text;
    try {
      if (request.method == 'POST' && request.uri.path == '/lua') {
        final code = await utf8.decodeStream(request);
        final a = await lua.run(code);
        out.statusCode = a.ok ? 200 : 422;
        out.write(a.text);
      } else if (request.method == 'GET' && request.uri.path == '/complete') {
        final q = request.uri.queryParameters['q'] ?? '';
        out.write((await lua.completions(q)).join('\n'));
      } else {
        out.statusCode = 404;
        out.write('POST /lua, or GET /complete?q=');
      }
    } catch (e) {
      out.statusCode = 503;
      out.write('$e'.replaceFirst('Exception: ', ''));
    }
    await out.close();
  }
}
