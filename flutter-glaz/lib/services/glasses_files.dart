import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';

/// A file or folder on the glasses.
class GlassesEntry {
  const GlassesEntry(this.name, {this.size, this.folder = false});
  final String name;
  final int? size;
  final bool folder;
}

/// A folder on the glasses: what is in it, and for the root, how much of
/// the file system is free, when their firmware can tell (null with stock
/// firmware, which has no frame.file.space()).
class GlassesFolder {
  const GlassesFolder(this.entries, {this.free, this.total});
  final List<GlassesEntry> entries;
  final int? free;
  final int? total;
}

/// Looks at the files on the glasses while their app runs: FILES_GET and
/// FILE_GET ask, FILES and FILE_DATA answer in packets (docs/PROTOCOL.md,
/// "Files"). The first byte of an answer is '+', or '-' and why.
class GlassesFiles {
  GlassesFiles(this.link) {
    link.events
        .where((m) => m.length >= 3 && (m[0] == files || m[0] == fileData))
        .listen(onPacket);
  }

  final FrameLink link;

  /// A listing is short; no answer this soon means the app on the glasses
  /// does not know the request -- it is older than this one.
  static const listTimeout = Duration(seconds: 8);

  /// A file is cut at 64 KB on the glasses, at Bluetooth speed; this is
  /// how long the phone waits for the rest.
  static const readTimeout = Duration(seconds: 60);

  static const _noAnswer =
      'No answer from the glasses. Their app may be '
      'older than this one: Upload it (Glasses tab), then try again.';

  int _next = 0;
  final _pending = <(int, int), (BytesBuilder, Completer<Uint8List>)>{};

  /// [code, id, more, bytes...]
  @visibleForTesting
  void onPacket(List<int> m) {
    final key = (m[0], m[1]);
    final entry = _pending[key];
    if (entry == null) return; // given up on, or not ours
    entry.$1.add(m.sublist(3));
    if (m[2] == 0) {
      _pending.remove(key);
      entry.$2.complete(entry.$1.takeBytes());
    }
  }

  Future<Uint8List> _ask(
    int ask,
    int answer,
    String path,
    Duration timeout,
  ) async {
    _next = _next % 255 + 1;
    final id = _next;
    final done = Completer<Uint8List>();
    _pending[(answer, id)] = (BytesBuilder(), done);
    await link.send(ask, [id, ...utf8.encode(path)]);
    try {
      final bytes = await done.future.timeout(timeout);
      if (bytes.isEmpty || bytes[0] != 0x2B) {
        // '-' and the glasses' error, or nothing at all
        throw Exception(
          bytes.isEmpty
              ? 'no answer'
              : utf8.decode(bytes.sublist(1), allowMalformed: true),
        );
      }
      return Uint8List.sublistView(bytes, 1);
    } on TimeoutException {
      throw Exception(_noAnswer);
    } finally {
      _pending.remove((answer, id));
    }
  }

  /// Folders first, then files, each by name. [path] '' is the root.
  Future<GlassesFolder> list(String path) async => parseListing(
    utf8.decode(
      await _ask(filesGet, files, path, listTimeout),
      allowMalformed: true,
    ),
  );

  Future<Uint8List> read(String path) =>
      _ask(fileGet, fileData, path, readTimeout);
}

/// 'd\tname' and 'f\tsize\tname' lines, and for the root 's\tfree\ttotal'
/// where the firmware can tell; any other line is skipped.
@visibleForTesting
GlassesFolder parseListing(String text) {
  final out = <GlassesEntry>[];
  int? free, total;
  for (final line in const LineSplitter().convert(text)) {
    final f = line.split('\t');
    if (f.length == 3 && f[0] == 's') {
      free = int.tryParse(f[1]);
      total = int.tryParse(f[2]);
    } else if (f.length == 2 && f[0] == 'd') {
      out.add(GlassesEntry(f[1], folder: true));
    } else if (f.length >= 3 && f[0] == 'f') {
      out.add(GlassesEntry(f.sublist(2).join('\t'), size: int.tryParse(f[1])));
    }
  }
  out.sort(
    (a, b) => a.folder != b.folder
        ? (a.folder ? -1 : 1)
        : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  return GlassesFolder(out, free: free, total: total);
}
