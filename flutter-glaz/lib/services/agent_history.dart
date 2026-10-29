import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One request to the AI agent: who asked, what, how long it took, and
/// the start of the answer or what went wrong.
class AgentCall {
  AgentCall(this.who, this.asked, this.at);

  /// The app that asked: 'Assistant', 'Factchecker'.
  final String who;

  /// The request's last user message, cut to [AgentHistory.textMax].
  final String asked;
  final DateTime at;

  /// Null while it is waited for.
  Duration? took;

  /// The start of the answer, cut to [AgentHistory.textMax].
  String? answer;
  String? error;

  bool get done => took != null;

  Map<String, Object?> toJson() => {
    'who': who,
    'asked': asked,
    'at': at.millisecondsSinceEpoch,
    'ms': took?.inMilliseconds,
    'answer': answer,
    'error': error,
  };

  factory AgentCall.fromJson(Map<String, dynamic> j) =>
      AgentCall(
          j['who'] as String? ?? '',
          j['asked'] as String? ?? '',
          DateTime.fromMillisecondsSinceEpoch(j['at'] as int? ?? 0),
        )
        ..took = j['ms'] == null ? null : Duration(milliseconds: j['ms'] as int)
        ..answer = j['answer'] as String?
        ..error = j['error'] as String?;
}

/// The requests to the AI agent, newest first, as its page in Glaz > More
/// > Services lists them; kept on the phone, in agent_history.json, once
/// [attach]ed.
class AgentHistory extends ChangeNotifier {
  AgentHistory();

  static final instance = AgentHistory();

  /// The newest kept.
  static const kept = 50;

  /// The most of a request or an answer kept, in characters.
  static const textMax = 300;

  final calls = <AgentCall>[];
  File? _file;
  Future<void> _saving = Future.value();

  /// Keeps the history in [file], reading what is there.
  Future<void> attach(File file) async {
    _file = file;
    try {
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List;
      calls
        ..clear()
        ..addAll([
          for (final c in list) AgentCall.fromJson(c as Map<String, dynamic>),
        ]);
      // one waited for when the app went is never answered now
      for (final c in calls.where((c) => !c.done)) {
        c
          ..took = Duration.zero
          ..error = 'the app stopped meanwhile';
      }
    } catch (_) {
      calls.clear();
    }
    notifyListeners();
  }

  static String _cut(String s) {
    final t = s.trim();
    return t.length > textMax ? '${t.substring(0, textMax - 2)}..' : t;
  }

  /// A request sent now.
  AgentCall start(String who, String asked) {
    final c = AgentCall(who, _cut(asked), DateTime.now());
    calls.insert(0, c);
    if (calls.length > kept) calls.removeRange(kept, calls.length);
    notifyListeners();
    _save();
    return c;
  }

  /// [call] answered, or gone wrong with [error].
  void end(AgentCall call, {String? answer, String? error}) {
    call
      ..took = DateTime.now().difference(call.at)
      ..answer = answer == null ? null : _cut(answer)
      ..error = error;
    notifyListeners();
    _save();
  }

  /// Forgets them all.
  void clear() {
    calls.clear();
    notifyListeners();
    _save();
  }

  @visibleForTesting
  Future<void> get saved => _saving;

  void _save() {
    final f = _file;
    if (f == null) return;
    final json = jsonEncode([for (final c in calls) c.toJson()]);
    _saving = _saving.then((_) async {
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(json);
      } catch (_) {}
    });
  }
}
