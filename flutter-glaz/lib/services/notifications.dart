import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

import '../frame/ascii.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// Forwards the phone's notifications to the glasses (docs/PROTOCOL.md,
/// "Notifications"). Android only: iOS gives apps no access to other apps'
/// notifications. Runs while Glaz runs; it is not a background service yet.
class NotificationService extends ChangeNotifier {
  NotificationService(this.link, this.settings);

  final FrameLink link;
  final Settings settings;

  static const maxBytes = 200;

  bool get supported => !kIsWeb && Platform.isAndroid;
  bool permission = false;
  int forwarded = 0;

  StreamSubscription<ServiceNotificationEvent>? _sub;
  String _lastKey = '';
  DateTime _lastAt = DateTime(0);

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
    // apps re-post a notification to update it; once is enough
    final key = '$pkg\n$title\n$text';
    final now = DateTime.now();
    if (key == _lastKey && now.difference(_lastAt).inSeconds < 10) return;
    _lastKey = key;
    _lastAt = now;
    send(appName(pkg), title, text);
  }

  Future<void> send(String app, String title, String text) async {
    if (!link.connected) return;
    await link.send(notify, encode(app, title, text));
    forwarded++;
    notifyListeners();
  }

  /// Shows a sample on the glasses, to check the whole path.
  Future<void> sendTest() =>
      send('Glaz', 'Test notification', 'Meeting in room 137 at 15:00');

  /// 'app\ntitle\ntext' in ASCII, cut to [maxBytes].
  static List<int> encode(String app, String title, String text) {
    String line(String s) =>
        toAscii(s)
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r' {2,}'), ' ')
            .trim();
    var out = '${line(app)}\n${line(title)}\n${line(text)}';
    if (out.length > maxBytes) out = out.substring(0, maxBytes);
    return ascii.encode(out);
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
