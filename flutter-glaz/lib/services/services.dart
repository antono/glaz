import 'dart:io';

import '../frame/link.dart';
import '../settings.dart';
import 'agent_files.dart';
import 'assistant.dart';
import 'glasses_files.dart';
import 'glasses_lua.dart';
import 'keys.dart';
import 'location.dart';
import 'module_settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photo_dir.dart';
import 'photos.dart';
import 'recordings.dart';
import 'speech.dart';
import 'transcripts.dart';
import 'voice.dart';

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
    this.transcripts,
    this.keys,
    this.assistant,
    this.lua,
  );

  final Settings settings;
  final FrameLink link;
  final NetworkService network;
  final NotificationService notifications;
  final PhotoService photos;
  final LocationService location;
  final GlassesFiles files;
  final RecorderService recorder;
  final TranscriptService transcripts;
  final KeyRemote keys;
  final AssistantService assistant;
  final GlassesLua lua;

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
    final recordings = RecordingStore(
      recDir,
      notes: recordingDir == null ? await recordingNotes() : null,
    );
    final photos = PhotoService(link, s, PhotoStore(dir));
    final transcripts = TranscriptService(recordings, s, Transcriber.platform);
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
      photos,
      LocationService(link, s),
      GlassesFiles(link),
      RecorderService(link, s, recordings),
      transcripts,
      KeyRemote(link, s),
      AssistantService(
        link,
        s,
        Transcriber.platform,
        queries: GlazFiles(link, s, photos, recordings, transcripts),
        voice: Voice.platform,
      ),
      GlassesLua(link),
    );
    LuaBridge(s, services.lua);
    SettingsSync(link, s);
    services.keys.attach();
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
