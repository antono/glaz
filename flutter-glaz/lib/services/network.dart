import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../frame/ascii.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// One answered request, for the Services screen.
class NetLogEntry {
  NetLogEntry(this.module, this.method, this.url, this.status);
  final String module;
  final String method;
  final String url;
  final int status;
  final DateTime at = DateTime.now();
}

/// Fetches web pages for modules on the glasses (docs/PROTOCOL.md,
/// "Internet"). Only for modules the user allowed, in Glaz > Apps.
class NetworkService extends ChangeNotifier {
  NetworkService(this.link, this.settings, {http.Client? client})
    : _client = client ?? http.Client() {
    link.events
        .where((m) => m.isNotEmpty && m[0] == netRequest)
        .listen(onPacket);
  }

  final FrameLink link;
  final Settings settings;
  final http.Client _client;

  static const maxBody = 4096;
  static const timeout = Duration(seconds: 15);

  final _partial = <int, BytesBuilder>{};
  final log = <NetLogEntry>[];

  /// One NET_REQUEST packet: [0x19, id, more, bytes...].
  @visibleForTesting
  void onPacket(List<int> packet) {
    if (packet.length < 3) return;
    final id = packet[1];
    final more = packet[2] != 0;
    _partial.putIfAbsent(id, BytesBuilder.new).add(packet.sublist(3));
    if (more) return;
    final text = utf8.decode(
      _partial.remove(id)!.takeBytes(),
      allowMalformed: true,
    );
    _handle(id, text);
  }

  Future<void> _handle(int id, String text) async {
    final lines = text.split('\n');
    final module = lines.first;
    final method = lines.length > 1 ? lines[1] : '';
    final url = lines.length > 2 ? lines[2] : '';
    final body = lines.length > 3 ? lines.sublist(3).join('\n') : '';

    final (status, bytes) = await answer(module, method, url, body);
    log.insert(0, NetLogEntry(module, method, url, status));
    if (log.length > 20) log.removeLast();
    notifyListeners();

    await link.send(netResponse, [id, status >> 8, status & 0xFF, ...bytes]);
  }

  /// The status and body for one request. Never throws: whatever goes wrong
  /// becomes status 0 and the error as text.
  Future<(int, List<int>)> answer(
    String module,
    String method,
    String url,
    String body,
  ) async {
    if (!settings.serviceOn('network') || !settings.netAllowed(module)) {
      return (403, ascii.encode('not allowed: Glaz > Apps'));
    }
    final uri = Uri.tryParse(url);
    if ((method != 'GET' && method != 'POST') ||
        uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      return (400, ascii.encode('bad request'));
    }
    try {
      final request = http.Request(method, uri);
      if (method == 'POST') request.body = body;
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
      final bytes = response.bodyBytes;
      return (
        response.statusCode,
        bytes.length > maxBody ? bytes.sublist(0, maxBody) : bytes,
      );
    } catch (e) {
      final why = toAscii('$e');
      return (0, ascii.encode(why.length > 200 ? why.substring(0, 200) : why));
    }
  }
}
