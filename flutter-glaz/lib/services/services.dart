import 'dart:io';

import 'package:flutter/services.dart';

import '../frame/link.dart';
import '../frame/parts.dart';
import '../settings.dart';
import '../term/hosts.dart';
import 'agent_files.dart';
import 'agent_history.dart';
import 'app_check.dart';
import 'assistant.dart';
import 'factcheck.dart';
import 'flipper.dart';
import 'flipper_remote.dart';
import 'gemini.dart';
import 'glasses_files.dart';
import 'glasses_lua.dart';
import 'hold.dart';
import 'keys.dart';
import 'location.dart';
import 'module_settings.dart';
import 'network.dart';
import 'notifications.dart';
import 'photo_dir.dart';
import 'photos.dart';
import 'reader.dart';
import 'scales.dart';
import 'recordings.dart';
import 'speech.dart';
import 'term.dart';
import 'transcripts.dart';
import 'translate.dart';
import 'tuner.dart';
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
    this.tuner,
    this.parts,
    this.scales,
    this.factcheck,
  ) : hold = LinkHold(link, settings, flipperRemote);

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

  /// Android's hold on the links, and its wake by the Flipper; started
  /// from main(), so tests need no channel.
  final LinkHold hold;
  final ReaderService reader;
  final TermService term;
  final GeminiService gemini;
  final AppCheck appCheck;
  final TunerService tuner;
  final ScalesService scales;
  final FactCheckService factcheck;

  /// Which apps each pair of glasses has (docs/DEVICES.md).
  final GlassesParts parts;

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
    final assistantAt = assistantDir ?? await assistantRoot();
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
        dir: assistantAt,
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
      TunerService(link, s),
      await GlassesParts.load(rootBundle),
      ScalesService(link),
      FactCheckService(link, s, Transcriber.platform, dir: assistantAt),
    );
    await services.reader.load();
    await services.assistant.load();
    await services.factcheck.load();
    await AgentHistory.instance.attach(
      File('${assistantAt.path}/agent_history.json'),
    );
    LuaBridge(s, services.lua);
    SettingsSync(link, s);
    services.keys.attach();
    services.flipper.attach();
    services.flipperRemote.attach();
    services.term.attach();
    services.tuner.attach();
    services.scales.attach();
    services.keys.terminal = services.term;
    link.onConnected.add(() async {
      if (s.serviceOn('clock')) await link.sendClock();
    });
    // again with every STATUS: the one on connect or after an upload can
    // reach the glasses before their app is up, and the top bar shows
    // --:-- until the next connect
    link.onStatusAnswer.add(() {
      if (s.serviceOn('clock')) link.sendClock(log: false);
    });
    await services.notifications.init();
    return instance = services;
  }
}
