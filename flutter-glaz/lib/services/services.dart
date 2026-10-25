import 'dart:io';

import '../frame/link.dart';
import '../settings.dart';
import '../term/hosts.dart';
import 'agent_files.dart';
import 'app_check.dart';
import 'assistant.dart';
import 'flipper.dart';
import 'flipper_remote.dart';
import 'gemini.dart';
import 'glasses_files.dart';
import 'glasses_lua.dart';
import 'keys.dart';
import 'location.dart';
import 'module_settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photo_dir.dart';
import 'photos.dart';
import 'reader.dart';
import 'recordings.dart';
import 'speech.dart';
import 'term.dart';
import 'transcripts.dart';
import 'translate.dart';
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
    this.translate,
    this.lua,
    this.flipper,
    this.reader,
    this.term,
    this.gemini,
    this.flipperRemote,
    this.appCheck,
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
  final TranslateService translate;
  final GlassesLua lua;
  final FlipperMirror flipper;
  final FlipperRemote flipperRemote;
  final ReaderService reader;
  final TermService term;
  final GeminiService gemini;
  final AppCheck appCheck;

  static late Services instance;

  /// [photoDir]: where photos go; [photoRoot] by default. [recordingDir]:
  /// where recordings go; [recordingRoot] by default.
  static Future<Services> start({
    Settings? settings,
    Directory? photoDir,
    Directory? recordingDir,
    Directory? readerDir,
    Directory? assistantDir,
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
    final hosts = TermHosts(s, DeviceSecrets());
    final keys = KeyRemote(link, s);
    final lua = GlassesLua(link);
    final services = Services._(
      s,
      link,
      NetworkService(link, s),
      NotificationService(link, s),
      photos,
      LocationService(link, s),
      GlassesFiles(link),
      RecorderService(link, s, recordings, transcripts: transcripts),
      transcripts,
      keys,
      AssistantService(
        link,
        s,
        Transcriber.platform,
        queries: GlazFiles(link, s, photos, recordings, transcripts),
        voice: Voice.platform,
        dir: assistantDir ?? await assistantRoot(),
      ),
      TranslateService(
        link,
        s,
        Transcriber.platform,
        Translator.platform,
        reader: PhotoReader.platform,
      ),
      lua,
      FlipperMirror(link, s),
      ReaderService(link, s, readerDir ?? await readerRoot()),
      TermService(link, s, hosts),
      GeminiService(link, s),
      FlipperRemote(link, s, lua),
      AppCheck(link, s),
    );
    await services.reader.load();
    await services.assistant.load();
    LuaBridge(s, services.lua);
    SettingsSync(link, s);
    services.keys.attach();
    services.flipper.attach();
    services.flipperRemote.attach();
    services.term.attach();
    services.keys.terminal = services.term;
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    await services.notifications.init();
    return instance = services;
  }
}
