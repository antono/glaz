import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../frame/link.dart';
import '../frame/upload.dart';
import '../settings.dart';
import 'glaz_log.dart';

/// What the glasses have for an app, as [AppCheck] found it.
enum GlassesApp {
  /// Not looked yet, or no telling: the link is down, a task has the
  /// glasses, or neither the app nor the REPL answered.
  unknown,

  /// The app answers.
  running,

  /// No main.lua: never uploaded, wiped by a firmware update or a reset,
  /// an upload cut short.
  missing,

  /// main.lua is there, but the REPL answers in its place: the app
  /// stopped, an error on start, say.
  stopped,
}

/// What the REPL's answer to [AppCheck.probe] says; null: none came.
GlassesApp glassesAppFrom({required bool heard, String? repl}) => heard
    ? GlassesApp.running
    : switch (repl) {
        'no app' => GlassesApp.missing,
        'app' => GlassesApp.stopped,
        _ => GlassesApp.unknown,
      };

/// Looks, on every connect, whether the glasses have the app: glasses
/// fresh from the box, a firmware update or a reset have none, and the
/// link comes up all the same. The app answers STATUS, sent on connect
/// (link.dart); with no answer the REPL is asked -- it answers only when
/// no app runs, since a running one blocks it (docs/PROTOCOL.md, "Status").
/// Nothing is broken or stopped on the way: no break, no reset.
class AppCheck extends ChangeNotifier {
  AppCheck(this.link, this.settings) {
    link.onConnected.add(_check);
    link.addListener(() {
      if (!link.connected) _set(GlassesApp.unknown);
    });
  }

  final FrameLink link;
  final Settings settings;

  GlassesApp app = GlassesApp.unknown;

  /// How long the app has to answer STATUS, and the REPL its question.
  static const appWait = Duration(seconds: 8);
  static const replWait = Duration(seconds: 3);

  /// Whether main.lua is on the glasses; the REPL prints 'app' or 'no
  /// app'. The file is closed again: an open one stays open.
  static const probe =
      "local ok,f=pcall(frame.file.open,'main.lua','read') "
      "if ok and f then f:close() end print(ok and 'app' or 'no app')";

  void _set(GlassesApp a) {
    if (a == app) return;
    app = a;
    notifyListeners();
  }

  Future<void> _check() async {
    _set(GlassesApp.unknown);
    // Halo: no glaz app to look for yet, and none to offer (model.dart)
    if (!link.model.supported) return;
    final connects = link.connects;
    // anything from the app will do; STATUS goes right after this
    final heard = await link.events.first
        .timeout(appWait)
        .then((_) => true, onError: (_) => false);
    final device = link.device;
    // the link went and came back meanwhile: that connect looks itself
    if (link.connects != connects || device == null) return;
    if (heard) return _set(GlassesApp.running);
    if (link.busy) return;
    String? said;
    try {
      final lines = await Repl(device).lines(
        probe,
        '',
        timeout: replWait,
        match: (l) => l == 'app' || l == 'no app',
      );
      said = lines.lastOrNull;
    } catch (_) {} // no answer: an app that is busy, or asleep
    if (link.connects != connects || !link.connected) return;
    final found = glassesAppFrom(heard: false, repl: said);
    glazLog(LogKind.link, switch (found) {
      GlassesApp.missing => 'no app on the glasses',
      GlassesApp.stopped => 'the app on the glasses is not running',
      _ => 'the app on the glasses did not answer',
    }, problem: found != GlassesApp.unknown);
    _set(found);
  }

  /// Uploads main.lua and the apps switched on in Menu, as Upload on the
  /// Glasses tab does; then looks again.
  Future<void> upload() async {
    if (!link.model.supported) return;
    final files = await luaFiles(
      rootBundle,
      settings.installed,
      model: link.model,
    );
    await link.runTask(
      'Upload',
      (device, report) => uploadApp(device, files, report),
    );
  }
}
