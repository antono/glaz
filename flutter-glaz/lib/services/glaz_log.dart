import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where a log entry comes from.
enum LogKind {
  /// The Bluetooth link: looking, connecting, up, down, pairing trouble.
  link('Link'),

  /// What the glasses printed while their app ran, their errors included.
  glasses('Glasses'),

  /// A job that has the glasses to itself: Upload, Restart.
  task('Tasks'),

  /// The assistant: questions, answers, what went wrong.
  assistant('Assistant'),

  /// Translate: what was heard, its translation, what went wrong.
  translate('Translate'),

  /// Fact check: what was heard, the claims, their checks.
  factcheck('Fact check'),

  /// A message to or from the glasses, by its code (protocol.dart).
  message('Messages');

  const LogKind(this.label);
  final String label;
}

class LogEntry {
  LogEntry(this.at, this.kind, this.text, {this.problem = false});
  final DateTime at;
  final LogKind kind;
  final String text;

  /// Something went wrong.
  final bool problem;

  /// One line of the log file: time, kind, '!' for a problem, the text.
  String get line =>
      '${at.toIso8601String()}\t${kind.name}\t${problem ? '!' : ''}\t'
      '${text.replaceAll('\n', ' / ')}';

  static LogEntry? parse(String line) {
    final p = line.split('\t');
    if (p.length < 4) return null;
    final at = DateTime.tryParse(p[0]);
    final kind = LogKind.values.where((k) => k.name == p[1]).firstOrNull;
    if (at == null || kind == null) return null;
    return LogEntry(at, kind, p.sublist(3).join('\t'), problem: p[2] == '!');
  }
}

/// What the app and the glasses did, for Glaz > More > Log: the last
/// [keep] entries, kept in a file across restarts. Each also goes to the
/// system log (adb logcat -s flutter) as 'glaz kind: text'.
class GlazLog extends ChangeNotifier {
  GlazLog();

  static final instance = GlazLog();

  static const keep = 1000;

  /// Oldest first.
  final entries = <LogEntry>[];

  File? _file;
  IOSink? _out;
  int _written = 0;

  /// Reads back the log [file] holds and writes to it from now on.
  Future<void> attach(File file) async {
    _file = file;
    try {
      if (await file.exists()) {
        final old = [
          for (final l in await file.readAsLines()) ?LogEntry.parse(l),
        ];
        entries.insertAll(0, old);
        _trim();
      }
      // the file starts over with what is kept
      await file.parent.create(recursive: true);
      await file.writeAsString(
        entries.map((e) => '${e.line}\n').join(),
        flush: true,
      );
      _written = entries.length;
      _out = file.openWrite(mode: FileMode.append);
    } catch (_) {
      _out = null; // the log still works, in memory
    }
    notifyListeners();
  }

  void add(LogKind kind, String text, {bool problem = false}) {
    final e = LogEntry(DateTime.now(), kind, text.trim(), problem: problem);
    debugPrint('glaz ${kind.name}${problem ? ' failed' : ''}: ${e.text}');
    entries.add(e);
    _trim();
    _out?.writeln(e.line);
    // the file grows to twice what is kept, then starts over
    if (++_written > 2 * keep) _rewrite();
    notifyListeners();
  }

  void _trim() {
    if (entries.length > keep) entries.removeRange(0, entries.length - keep);
  }

  Future<void> _rewrite() async {
    final file = _file;
    final out = _out;
    if (file == null || out == null) return;
    _out = null;
    try {
      await out.close();
      await file.writeAsString(entries.map((e) => '${e.line}\n').join());
      _written = entries.length;
      _out = file.openWrite(mode: FileMode.append);
    } catch (_) {}
  }

  /// Waits for what was added to be in the file.
  Future<void> flush() async {
    try {
      await _out?.flush();
    } catch (_) {}
  }

  Future<void> clear() async {
    entries.clear();
    await _rewrite();
    notifyListeners();
  }
}

/// Adds to [GlazLog.instance].
void glazLog(LogKind kind, String text, {bool problem = false}) =>
    GlazLog.instance.add(kind, text, problem: problem);
