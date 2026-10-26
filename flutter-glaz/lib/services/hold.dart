import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../frame/link.dart';
import '../settings.dart';
import 'flipper_remote.dart';
import 'glaz_log.dart';

/// Android keeps glaz running while the Flipper remote has something to
/// hold -- the Flipper near or connected, the glasses connected -- with a
/// foreground service and its notification (LinkService.kt), and wakes it
/// when the Flipper comes near (FlipperPresence.kt). This tells it what
/// is connected, and hands the Flipper's coming to [FlipperRemote].
/// Elsewhere, and in tests, there is no channel: nothing happens.
class LinkHold {
  LinkHold(this.link, this.settings, this.remote);

  final FrameLink link;
  final Settings settings;
  final FlipperRemote remote;

  static const channel = MethodChannel('glaz/hold');

  /// What made glaz start, as the log says it.
  static const _why = {
    'app': 'the app opened',
    'flipper': 'the Flipper came near',
    'service': 'the link service',
    'bound': 'Android bound it again',
  };

  Map<String, Object?>? _sent;

  /// What Android is told: everything that decides whether it holds.
  @visibleForTesting
  Map<String, Object?> get state => {
    'flipper': settings.serviceOn('flipper_remote'),
    'paired': remote.paired.isNotEmpty,
    'flipperConnected': remote.connected,
    'flipperName': remote.name,
    'glasses': link.connected,
    'glassesName': link.name,
  };

  /// Listens to Android and to what it is told about, logs why glaz
  /// started, and tells it what is connected now.
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'present' && call.arguments == true) {
        remote.appeared();
      }
      return null;
    });
    try {
      final why = await channel.invokeMethod<String>('started');
      if (why != null) glazLog(LogKind.link, 'start: ${_why[why] ?? why}');
    } on MissingPluginException {
      return; // not Android, or a test: nobody to tell
    } on PlatformException {
      return;
    }
    link.addListener(_changed);
    settings.addListener(_changed);
    remote.addListener(_changed);
    _changed();
  }

  void _changed() {
    final now = state;
    if (mapEquals(now, _sent)) return;
    _sent = now;
    channel.invokeMethod<void>('state', now).catchError((Object _) {
      _sent = null; // told again with the next change
    });
  }

  /// The notification that says glaz holds the links: Android 13 on asks
  /// for it. Only with glaz on screen; a no stands, Android asks no more.
  Future<void> askNotifications() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // no activity to ask from
    }
  }
}
