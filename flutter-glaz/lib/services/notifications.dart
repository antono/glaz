import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

import '../frame/font.dart';
import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// One notification kept for the glasses' list.
class Notice {
  Notice(this.id, this.app, this.title, this.text, {DateTime? at})
    : at = at ?? DateTime.now();
  final int id;
  final String app;
  final String title;
  final String text;
  final DateTime at;
}

/// Forwards the phone's notifications to the glasses (docs/PROTOCOL.md,
/// "Notifications"), and keeps the last [keep] for their list (Apps >
/// Notifications), which they read a few at a time. Android only: iOS
/// gives apps no access to other apps' notifications. Runs while Glaz
/// runs; it is not a background service yet.
class NotificationService extends ChangeNotifier {
  NotificationService(this.link, this.settings) {
    link.events
        .where((m) => m.isNotEmpty && m[0] == noticesGet)
        .listen(onRequest);
  }

  final FrameLink link;
  final Settings settings;

  static const maxBytes = 200;

  /// Notifications kept for the glasses' list.
  static const keep = 50;

  /// Of the list, at most this many at once: the glasses hold no more.
  static const window = 10;

  /// At most this much in one answer: a MODULE_CALL the glasses put
  /// together in memory.
  static const maxAnswer = 900;

  /// How wide a line of the list or of one opened may be, in px: the
  /// screen from where the glasses draw a module's text (glaz.lua,
  /// LEFT_X) to its right edge, less a little.
  static const lineWidth = 560;

  final _kept = <Notice>[];
  int _nextId = 1;

  /// Newest first.
  List<Notice> get kept => List.unmodifiable(_kept);

  bool get supported => !kIsWeb && Platform.isAndroid;
  bool permission = false;
  int forwarded = 0;

  StreamSubscription<ServiceNotificationEvent>? _sub;

  /// How long a forwarded notification is remembered, so that a re-post of
  /// it is not forwarded again.
  static const remember = Duration(minutes: 30);
  final _seen = <String, DateTime>{};

  Future<void> init() async {
    if (!supported) return;
    permission = await NotificationListenerService.isPermissionGranted();
    if (permission) _listen();
    notifyListeners();
  }

  /// Opens the system page where the user lets Glaz read notifications.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    permission = await NotificationListenerService.requestPermission();
    if (permission) _listen();
    notifyListeners();
    return permission;
  }

  void _listen() {
    _sub ??= NotificationListenerService.notificationsStream.listen(_onEvent);
  }

  void _onEvent(ServiceNotificationEvent e) {
    // removals, and ongoing ones (music, navigation) that update constantly
    if (e.hasRemoved || e.onGoing) return;
    if (!settings.serviceOn('notifications')) return;
    final pkg = e.packageName;
    if (pkg == 'dev.glaz.glaz') return;
    final title = e.title;
    final text = e.content;
    if (title.isEmpty && text.isEmpty) return;
    if (!isNew(pkg, title, text, DateTime.now())) return;
    send(appName(pkg), title, text);
  }

  /// Whether this notification was not forwarded within [remember]. Apps
  /// re-post a notification to update it, and Telegram re-posts every one
  /// of a chat's unread messages with each new message; once is enough.
  bool isNew(String pkg, String title, String text, DateTime now) {
    _seen.removeWhere((_, at) => now.difference(at) > remember);
    final key = '$pkg\n$title\n$text';
    if (_seen.containsKey(key)) return false;
    _seen[key] = now;
    return true;
  }

  Future<void> send(String app, String title, String text) async {
    _keep(app, title, text);
    if (!link.connected) return;
    await link.send(notify, encode(app, title, text));
    forwarded++;
    notifyListeners();
  }

  void _keep(String app, String title, String text) {
    String clean(String s) =>
        forGlasses(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    _kept.insert(0, Notice(_nextId++, clean(app), clean(title), clean(text)));
    if (_kept.length > keep) _kept.removeLast();
  }

  /// NOTICES_GET, [0x0E, op, n (4)]: op 1 the list from number n (0 the
  /// newest), op 2 notification n, all of it. Answered with MODULE_CALL
  /// 'notifications'.
  @visibleForTesting
  Future<void> onRequest(List<int> m) async {
    if (m.length < 6) return;
    final op = m[1];
    final n = ByteData.sublistView(Uint8List.fromList(m)).getUint32(2);
    final arg = op == 1
        ? listAnswer(n)
        : op == 2
        ? fullAnswer(n)
        : null;
    if (arg != null) await link.callModule('notifications', arg);
  }

  /// 'l:from:total' and a line '\nid|app: title' each, from number from.
  String listAnswer(int from) {
    final out = StringBuffer('l:$from:${_kept.length}');
    final room = lineWidth - textWidth('> ');
    var bytes = out.length;
    for (final n in _kept.skip(from).take(window)) {
      final what = n.title.isNotEmpty ? n.title : n.text;
      final line = '\n${n.id}|${cutToWidth('${n.app}: $what', room)}';
      final size = utf8.encode(line).length;
      if (bytes + size > maxAnswer) break;
      out.write(line);
      bytes += size;
    }
    return out.toString();
  }

  /// 'f:id' and its lines: the app and when, the title, the text; as many
  /// as fit in [maxAnswer]. One no longer kept: '(gone)'.
  String fullAnswer(int id) {
    final out = StringBuffer('f:$id');
    final i = _kept.indexWhere((n) => n.id == id);
    if (i < 0) return '$out\n(gone)';
    final n = _kept[i];
    final at =
        '${n.at.hour.toString().padLeft(2, '0')}:'
        '${n.at.minute.toString().padLeft(2, '0')}';
    final lines = [
      cutToWidth('$at  ${n.app}', lineWidth),
      ...wrapToWidth(n.title, lineWidth),
      ...wrapToWidth(n.text, lineWidth),
    ];
    var bytes = out.length;
    for (final line in lines) {
      final size = utf8.encode(line).length + 1;
      if (bytes + size > maxAnswer) {
        out.write('\n..');
        break;
      }
      out.write('\n$line');
      bytes += size;
    }
    return out.toString();
  }

  /// Shows a sample on the glasses, to check the whole path.
  Future<void> sendTest() =>
      send('Glaz', 'Test notification', 'Meeting in room 137 at 15:00');

  /// 'app\ntitle\ntext' in UTF-8, cut to [maxBytes].
  static List<int> encode(String app, String title, String text) {
    String line(String s) =>
        forGlasses(s)
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r' {2,}'), ' ')
            .trim();
    var out = '${line(app)}\n${line(title)}\n${line(text)}';
    return utf8.encode(cutToBytes(out, maxBytes));
  }

  static const _known = {
    'org.telegram.messenger': 'Telegram',
    'org.thunderdog.challegram': 'Telegram',
    'com.whatsapp': 'WhatsApp',
    'org.thoughtcrime.securesms': 'Signal',
    'com.google.android.gm': 'Gmail',
    'com.google.android.apps.messaging': 'Messages',
    'com.google.android.calendar': 'Calendar',
    'com.android.phone': 'Phone',
    'com.google.android.dialer': 'Phone',
    'com.slack': 'Slack',
  };

  static const _generic = {
    'com',
    'org',
    'net',
    'io',
    'app',
    'apps',
    'android',
    'google',
    'mobile',
    'client',
    'messenger',
    'ru',
    'de',
    'nl',
    'co',
  };

  /// A readable name from a package name: 'com.spotify.music' -> 'Spotify'.
  static String appName(String pkg) {
    final known = _known[pkg];
    if (known != null) return known;
    final parts = pkg.split('.').where((p) => !_generic.contains(p)).toList();
    if (parts.isEmpty) return pkg;
    final word = parts.first;
    return word[0].toUpperCase() + word.substring(1);
  }
}
