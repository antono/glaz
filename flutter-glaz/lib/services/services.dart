import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../frame/link.dart';
import '../settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photos.dart';

/// The app's long-lived parts, made once at startup.
class Services {
  Services._(
    this.settings,
    this.link,
    this.network,
    this.notifications,
    this.photos,
  );

  final Settings settings;
  final FrameLink link;
  final NetworkService network;
  final NotificationService notifications;
  final PhotoService photos;

  static late Services instance;

  /// [photoDir]: where photos go; the app's documents folder by default.
  static Future<Services> start({
    Settings? settings,
    Directory? photoDir,
  }) async {
    final s = settings ?? await Settings.load();
    final link = FrameLink();
    final dir =
        photoDir ??
        Directory('${(await getApplicationDocumentsDirectory()).path}/photos');
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
      PhotoService(link, s, PhotoStore(dir)),
    );
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
