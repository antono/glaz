import 'dart:io';

import '../frame/link.dart';
import '../settings.dart';
import 'glasses_files.dart';
import 'keys.dart';
import 'location.dart';
import 'module_settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photo_dir.dart';
import 'photos.dart';
import 'recordings.dart';

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
    this.recorder,
    this.keys,
  );

  final Settings settings;
  final FrameLink link;
  final NetworkService network;
  final NotificationService notifications;
  final PhotoService photos;
  final LocationService location;
  final GlassesFiles files;
  final RecorderService recorder;
  final KeyRemote keys;

  static late Services instance;

  /// [photoDir]: where photos go; [photoRoot] by default. [recordingDir]:
  /// where recordings go; [recordingRoot] by default.
  static Future<Services> start({
    Settings? settings,
    Directory? photoDir,
    Directory? recordingDir,
  }) async {
    final s = settings ?? await Settings.load();
    final link = FrameLink();
    final dir = photoDir ?? await photoRoot();
    final recDir = recordingDir ?? await recordingRoot();
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
      PhotoService(link, s, PhotoStore(dir)),
      LocationService(link, s),
      GlassesFiles(link),
      RecorderService(link, s, RecordingStore(recDir)),
      KeyRemote(link, s),
    );
    SettingsSync(link, s);
    services.keys.attach();
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
