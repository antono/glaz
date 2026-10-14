import '../frame/link.dart';
import '../settings.dart';
import 'network.dart';
import 'notifications.dart';

/// The app's long-lived parts, made once at startup.
class Services {
  Services._(this.settings, this.link, this.network, this.notifications);

  final Settings settings;
  final FrameLink link;
  final NetworkService network;
  final NotificationService notifications;

  static late Services instance;

  static Future<Services> start({Settings? settings}) async {
    final s = settings ?? await Settings.load();
    final link = FrameLink();
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
    );
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
