import 'dart:io';

import '../frame/link.dart';
import '../settings.dart';
import 'glasses_files.dart';
import 'location.dart';
import 'module_settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photo_dir.dart';
import 'photos.dart';

/// The app's long-lived parts, made once at startup.
class Services {
  Services._(
    this.settings,
    this.link,
    this.network,
    this.notifications,
    this.photos,
    this.location,
    this.files,
  );

  final Settings settings;
  final FrameLink link;
  final NetworkService network;
  final NotificationService notifications;
  final PhotoService photos;
  final LocationService location;
  final GlassesFiles files;

  static late Services instance;

  /// [photoDir]: where photos go; [photoRoot] by default.
  static Future<Services> start({
    Settings? settings,
    Directory? photoDir,
  }) async {
    final s = settings ?? await Settings.load();
    final link = FrameLink();
    final dir = photoDir ?? await photoRoot();
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
      PhotoService(link, s, PhotoStore(dir)),
      LocationService(link, s),
      GlassesFiles(link),
    );
    SettingsSync(link, s);
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
