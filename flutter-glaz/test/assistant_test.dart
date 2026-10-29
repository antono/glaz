import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/agent.dart';
import 'package:glaz/services/agent_files.dart';
import 'package:glaz/services/assistant.dart';
import 'package:glaz/services/photos.dart';
import 'package:glaz/services/recordings.dart';
import 'package:glaz/services/transcripts.dart';
import 'package:glaz/services/voice.dart';
import 'package:glaz/settings.dart';

import 'speech_test.dart' show FakeTranscriber;

/// Keeps what would go to the glasses.
class SentLink extends FrameLink {
  final sent = <(int, String)>[];

  @override
  Future<void> send(
    int code,
    List<int> payload, {
    bool duringTask = false,
    bool log = true,
  }) {
    sent.add((code, utf8.decode(payload, allowMalformed: true)));
    return Future.value();
  }
}

class FakeAgent implements Agent {
  FakeAgent(this.reply);
  String reply;

  /// Answered first, one an ask, before [reply].
  List<String> replies = [];
  final asked = <List<AgentMessage>>[];

  @override
  Future<String> ask(List<AgentMessage> messages, {Duration? wait}) async {
    asked.add(messages);
    return replies.isNotEmpty ? replies.removeAt(0) : reply;
  }
}

class FakeVoice implements Voice {
  FakeVoice(this.now);
  Headphones now;
  final said = <(String, String)>[];
  int stops = 0;

  @override
  Future<Headphones> headphones() async => now;

  @override
  Future<bool> speak(String text, String language) async {
    if (!now.ok) return false;
    said.add((text, language));
    return true;
  }

  @override
  Future<void> stop() async => stops++;
}

class FakeQueries implements AgentQueries {
  final ran = <GlassesCommand>[];

  @override
  bool handles(String command) => GlazFiles.commands.contains(command);

  @override
  Future<QueryResult> run(GlassesCommand c) async {
    ran.add(c);
    return QueryResult(
      'result of $c',
      c.name == 'photo'
          ? [
              Uint8List.fromList([1, 3, 7]),
            ]
          : [],
    );
  }
}

void main() {
  group('splitReply', () {
    test('commands out, text kept', () {
      final (text, commands) = splitReply(
        '@open weather\nСейчас покажу.\n`@set weather.city=Minsk`\n',
      );
      expect(text, 'Сейчас покажу.');
      expect(commands, const [
        GlassesCommand('open', 'weather'),
        GlassesCommand('set', 'weather.city=Minsk'),
      ]);
    });

    test('an @ inside a sentence is text', () {
      final (text, commands) = splitReply('Write to me @home');
      expect(text, 'Write to me @home');
      expect(commands, isEmpty);
    });
  });

  group('wrapForGlasses', () {
    test('lines of at most 26 characters, Cyrillic kept', () {
      final out = wrapForGlasses('Встречаемся в 137 кабинете на третьем этаже');
      for (final line in out.split('\n')) {
        expect(line.length, lessThanOrEqualTo(26));
      }
      expect(
        out.replaceAll('\n', ' '),
        'Встречаемся в 137 кабинете на третьем этаже',
      );
    });

    test('cut at maxLines, ending in ..', () {
      final out = wrapForGlasses('word ' * 100, maxLines: 3);
      final lines = out.split('\n');
      expect(lines, hasLength(3));
      expect(lines.last, endsWith('..'));
    });
  });

  group('assistant', () {
    late Settings settings;
    late SentLink link;
    late FakeAgent agent;
    late AssistantService assistant;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = SentLink();
      agent = FakeAgent('@open weather\nСейчас покажу.');
      assistant = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
      );
    });

    String? last(int code) =>
        link.sent.lastWhere((s) => s.$1 == code, orElse: () => (0, '')).$2;

    test('sound in, question to the agent, commands run', () async {
      assistant.onMessage([recStart, 8, 8, forAssistant]);
      expect(assistant.state, AssistantState.listening);
      assistant.onMessage([audioChunk, 1, 2, 3]);
      assistant.onMessage([audioEnd, 4]);
      await pumpEventQueue();

      // FakeTranscriber hears each piece as its number
      expect(agent.asked.single.last.content, '1 2');
      expect(agent.asked.single.first.role, 'system');
      expect(last(appOpen), 'weather');
      expect(assistant.turns.single.answer, 'Сейчас покажу.');
      expect(assistant.state, AssistantState.idle);
    });

    test('the answer goes to Assistant when nothing else opens', () async {
      agent.reply = 'Сорок два.';
      await assistant.ask('Сколько?');
      expect(last(appOpen), 'assistant\nt:0\nQ|Сколько?\nA|Сорок два.');
      expect(last(moduleCall), 'assistant\nt:1\nQ|Сколько?');
    });

    test('only the apps last uploaded are offered and opened', () async {
      String prompt() => agent.asked.last.first.content;
      agent.reply = '@open stopwatch';
      // no upload seen yet: the switches in Menu
      settings.setInstalled('reader', false);
      await assistant.ask('?');
      expect(prompt(), contains('- stopwatch ('));
      expect(prompt(), isNot(contains('- reader (')));

      // switched off after an upload: still on the glasses
      settings.setUploaded(link.model.name, ['stopwatch', 'tuner']);
      settings.setInstalled('stopwatch', false);
      await assistant.ask('?');
      expect(prompt(), contains('- stopwatch ('));
      expect(last(appOpen), 'stopwatch');

      // uploaded since, without it
      settings.setUploaded(link.model.name, ['tuner', 'uptime']);
      link.sent.clear();
      await assistant.ask('?');
      expect(prompt(), contains('- tuner ('));
      expect(prompt(), isNot(contains('- stopwatch (')));
      expect(prompt(), isNot(contains('- reader (')));
      expect(
        link.sent.where((s) => s.$1 == appOpen && s.$2 == 'stopwatch'),
        isEmpty,
      );
    });

    test('heard in its own language, the recordings\' until picked', () {
      final t = FakeTranscriber();
      final a = AssistantService(link, settings, t, agent: (_) => agent);
      settings.speechLanguage = 'de-DE';
      a.onMessage([recStart, 16, 8, forAssistant]);
      expect(t.language, 'de-DE');
      settings.assistantLanguage = 'ru-RU';
      a.onMessage([recStart, 16, 8, forAssistant]);
      expect(t.language, 'ru-RU');
      expect(settings.speechLanguage, 'de-DE');
    });

    test('dropped on the glasses: nothing is asked', () async {
      assistant.onMessage([recStart, 16, 8, forAssistant]);
      assistant.onMessage([audioChunk, 1, 2]);
      assistant.onMessage([recDrop]);
      await pumpEventQueue();
      expect(agent.asked, isEmpty);
      expect(assistant.state, AssistantState.idle);
    });

    test('dropped while the agent thinks: its answer is thrown away', () async {
      final asked = assistant.ask('Сколько?');
      assistant.onMessage([recDrop]);
      await asked;
      expect(agent.asked, hasLength(1));
      expect(link.sent.where((s) => s.$1 == appOpen), isEmpty);
    });

    test('read aloud in headphones, as written, not transliterated', () async {
      final voice = FakeVoice(const Headphones(true, name: 'Buds'));
      final a = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
        voice: voice,
      );
      settings.assistantLanguage = 'ru-RU';
      agent.reply = 'Сорок два.';
      await a.ask('Сколько?');
      expect(voice.said, [('Сорок два.', 'ru-RU')]);
    });

    test('not read aloud to a speaker, nor when switched off', () async {
      final voice = FakeVoice(
        const Headphones(false, why: "the phone's loudspeaker"),
      );
      final a = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
        voice: voice,
      );
      agent.reply = 'Сорок два.';
      await a.ask('Сколько?');
      expect(voice.said, isEmpty);
      voice.now = const Headphones(true);
      settings.assistantSpeaks = false;
      await a.ask('Сколько?');
      expect(voice.said, isEmpty);
      // the glasses' screen has it all the same
      expect(link.sent.last.$1, appOpen);
      expect(link.sent.last.$2, endsWith('A|Сорок два.'));
    });

    test('a new question or a drop stops the reading', () async {
      final voice = FakeVoice(const Headphones(true));
      final a = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
        voice: voice,
      );
      a.onMessage([recStart, 16, 8, forAssistant]);
      a.onMessage([recDrop]);
      expect(voice.stops, 2);
    });

    test('a Recorder recording is not a question', () async {
      assistant.onMessage([recStart, 8, 8]);
      assistant.onMessage([audioEnd, 4]);
      await pumpEventQueue();
      expect(agent.asked, isEmpty);
      expect(assistant.state, AssistantState.idle);
    });

    test('the conversation goes on', () async {
      await assistant.ask('one');
      await assistant.ask('two');
      final messages = agent.asked.last.map((m) => m.role).toList();
      expect(messages, ['system', 'user', 'assistant', 'user']);
    });

    test('no agent set up: says where, on the glasses', () async {
      assistant = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: agentFrom,
      );
      await assistant.ask('hi');
      expect(last(appOpen), contains('\nE|Set up the AI agent: Glaz\nE|> More > Services'));
    });

    test('set takes only known settings and options', () async {
      await assistant.run(const [
        GlassesCommand('set', 'weather.city=Минск'),
        GlassesCommand('set', 'photo.quality=high'),
        GlassesCommand('set', 'photo.quality=ultra'),
        GlassesCommand('set', 'weather.nope=1'),
      ]);
      expect(settings.config('weather', 'city'), 'Минск');
      expect(settings.config('photo', 'quality'), 'HIGH');
      expect(settings.config('weather', 'nope'), isNull);
    });

    test('press uses the remote', () async {
      await assistant.run(const [
        GlassesCommand('press', 'back'),
        GlassesCommand('press', 'right'),
        GlassesCommand('open', 'nosuchapp'),
      ]);
      expect(link.sent.map((s) => s.$1), [input, input]);
    });
  });

  group('queries', () {
    late Settings settings;
    late SentLink link;
    late FakeAgent agent;
    late FakeQueries queries;
    late AssistantService assistant;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = SentLink();
      queries = FakeQueries();
      agent = FakeAgent('');
      assistant = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
        queries: queries,
      );
    });

    test('a query is answered, then the agent answers', () async {
      agent.replies = ['@photo', 'Вижу кота.'];
      await assistant.ask('Что я вижу?');

      expect(queries.ran, const [GlassesCommand('photo', '')]);
      final second = agent.asked[1];
      expect(second[second.length - 2].content, '@photo');
      expect(second.last.content, 'result of @photo');
      expect(second.last.images.single, [1, 3, 7]);
      // the tool call on the glasses too, while it runs and after
      expect(
        link.sent.where((s) => s.$1 == moduleCall).map((s) => s.$2),
        contains(
          'assistant\nt:1\nQ|Что я вижу?\n'
          'T|* Took a photo with the\nT|glasses ..',
        ),
      );
      expect(link.sent.last, (
        appOpen,
        'assistant\nt:0\nQ|Что я вижу?\n'
            'T|* Took a photo with the\nT|glasses\nA|Вижу кота.',
      ));
      expect(assistant.turns.single.queries, hasLength(1));

      // the conversation keeps no photos
      await assistant.ask('А сейчас?');
      expect(agent.asked.last.every((m) => m.images.isEmpty), isTrue);
      expect(agent.asked.last.map((m) => m.role), [
        'system',
        'user',
        'assistant',
        'user',
        'assistant',
        'user',
      ]);
    });

    test(
      'each query is a tool call of the turn, with what it brought',
      () async {
        agent.replies = ['@photo', 'Вижу кота.'];
        await assistant.ask('Что я вижу?');
        final call = assistant.turns.single.queries.single;
        expect(call.command, const GlassesCommand('photo', ''));
        expect(call.result, 'result of @photo (a photo)');
      },
    );

    test('an agent that keeps asking is cut short', () async {
      agent.reply = '@photos today';
      await assistant.ask('?');
      expect(agent.asked, hasLength(AssistantService.maxRounds + 1));
      expect(queries.ran, hasLength(AssistantService.maxRounds));
    });

    test('the prompt offers queries only when allowed', () {
      expect(systemPrompt(settings), contains('@getphoto'));
      settings.agentFiles = false;
      expect(systemPrompt(settings), isNot(contains('@getphoto')));
    });
  });

  group('Glaz files', () {
    late Directory tmp;
    late Settings settings;
    late GlazFiles files;
    late RecordingStore recordings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      tmp = await Directory.systemTemp.createTemp('glaz_files');
      final photos = PhotoService(
        FrameLink(),
        settings,
        PhotoStore(Directory('${tmp.path}/photos')),
      );
      final side = img.Image(width: 4, height: 2);
      await photos.store.saveSingle(
        withOrientation(img.encodeJpg(side)),
        DateTime(2026, 10, 17, 13, 7, 1, 137),
      );
      recordings = RecordingStore(Directory('${tmp.path}/rec'));
      final w = await recordings.begin(DateTime(2026, 10, 17, 9), 8000, 8);
      w.add(List.filled(8000, 0));
      await w.close();
      await transcriptOf(w.file).writeAsString('Купить молоко и хлеб');
      files = GlazFiles(
        FrameLink(),
        settings,
        photos,
        recordings,
        TranscriptService(recordings, settings, null),
      );
    });

    tearDown(() => tmp.delete(recursive: true));

    test('photos are listed, and one comes upright', () async {
      final list = await files.run(
        const GlassesCommand('photos', '2026-10-16'),
      );
      expect(list.text, contains('No photos'));
      final all = await files.run(const GlassesCommand('photos', '2026-10-17'));
      expect(all.text, contains('2026-10-17 13-07-01-137.jpg'));

      final got = await files.run(
        const GlassesCommand('getphoto', '2026-10-17 13-07-01-137.jpg'),
      );
      final photo = img.decodeJpg(got.images.single)!;
      expect((photo.width, photo.height), (2, 4));
    });

    test('recordings with their transcripts', () async {
      final list = await files.run(const GlassesCommand('recordings', ''));
      expect(list.text, contains('2026-10-17 09-00-00.wav'));
      expect(list.text, contains('1 s'));
      expect(list.text, contains('"Купить молоко и хлеб"'));
      final t = await files.run(
        const GlassesCommand('transcript', '2026-10-17 09-00-00.wav'),
      );
      expect(t.text, endsWith('Купить молоко и хлеб'));
    });

    test('nothing without the permission', () async {
      settings.agentFiles = false;
      final r = await files.run(const GlassesCommand('photos', ''));
      expect(r.text, startsWith('Not allowed'));
    });

    test('no photo from glasses that are not there', () async {
      final r = await files.run(const GlassesCommand('photo', ''));
      expect(r.text, 'The glasses are not connected.');
    });
  });

  group('chat completions', () {
    test('endpoint with or without /v1', () {
      expect(
        ChatCompletionsAgent.endpoint('http://h.ts.net:8642/').toString(),
        'http://h.ts.net:8642/v1/chat/completions',
      );
      expect(
        ChatCompletionsAgent.endpoint('https://h.ts.net/v1').toString(),
        'https://h.ts.net/v1/chat/completions',
      );
    });

    test('sends the key and model, reads the answer', () async {
      late http.Request seen;
      final agent = ChatCompletionsAgent(
        url: 'https://h.ts.net',
        key: 'k137',
        model: 'hermes-agent',
        client: MockClient((r) async {
          seen = r;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': ' Привет '},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect(await agent.ask(const [AgentMessage('user', 'hi')]), 'Привет');
      expect(seen.headers['Authorization'], 'Bearer k137');
      expect(jsonDecode(seen.body)['model'], 'hermes-agent');
    });

    test('photos go as data URLs', () {
      final json = AgentMessage(
        'user',
        'look',
        images: [
          Uint8List.fromList([1, 3, 7]),
        ],
      ).toJson();
      expect(json['content'], [
        {'type': 'text', 'text': 'look'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,AQMH'},
        },
      ]);
    });

    test('a refused key says so', () async {
      final agent = ChatCompletionsAgent(
        url: 'https://h.ts.net',
        key: 'bad',
        model: 'm',
        client: MockClient((_) async => http.Response('no', 401)),
      );
      expect(
        agent.ask(const []),
        throwsA(
          isA<AgentError>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    });
  });

  group('chats', () {
    late Settings settings;
    late Directory dir;
    late FakeAgent agent;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      dir = Directory.systemTemp.createTempSync('glaz_chats');
      agent = FakeAgent('Сорок два.');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    AssistantService service() => AssistantService(
      SentLink(),
      settings,
      FakeTranscriber(),
      agent: (_) => agent,
      queries: FakeQueries(),
      dir: dir,
    );

    test('kept on the phone and read back', () async {
      agent.replies = ['@transcript 137', 'Встреча в 137.'];
      final a = service();
      await a.ask('Где встреча?');
      await a.saved;

      final b = service();
      await b.load();
      final chat = b.chats.single;
      expect(chat.title, 'Где встреча?');
      expect(chat.turns.single.answer, 'Встреча в 137.');
      expect(
        chat.turns.single.queries.single.command,
        const GlassesCommand('transcript', '137'),
      );
      expect(chat.history.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
    });

    test('a chat picked again goes on, its history sent', () async {
      final a = service();
      await a.ask('Первый?');
      a.newChat();
      await a.ask('Второй?');
      expect(a.chats, hasLength(2));

      final first = a.chats.last;
      await a.ask('И ещё?', chat: first);
      expect(agent.asked.last.map((m) => m.content).skip(1), [
        'Первый?',
        'Сорок два.',
        'И ещё?',
      ]);
      expect(a.chats.first, first);
      expect(first.turns, hasLength(2));
      await a.saved;
    });

    test('removed for good', () async {
      final a = service();
      await a.ask('?');
      a.remove(a.chats.single);
      await a.saved;
      expect(a.current, isNull);
      final b = service();
      await b.load();
      expect(b.chats, isEmpty);
    });

    test('listed on the glasses, and picked there', () async {
      final link = SentLink();
      final a = AssistantService(
        link,
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
      );
      await a.ask('Первый вопрос');
      a.newChat();
      await a.ask('Второй | вопрос');

      a.onMessage([assist, 1, 0, 0]);
      final second = a.chats.first, first = a.chats.last;
      expect(link.sent.last, (
        moduleCall,
        'assistant\nc:${second.id}\n${second.id}|Второй вопрос'
            '\n${first.id}|Первый вопрос',
      ));

      a.onMessage([assist, 2, 0, first.id]);
      expect(a.current, first);
      expect(
        link.sent.last.$2,
        'assistant\nt:0\nQ|Первый вопрос\nA|Сорок два.',
      );

      a.onMessage([assist, 3, 0, 0]);
      expect(a.current, isNull);
    });

    test('a long chat goes to the glasses as its newest turns', () async {
      final a = AssistantService(
        SentLink(),
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
      );
      agent.reply = 'слово ' * 40;
      for (var i = 0; i < 137; i++) {
        await a.ask('Вопрос $i');
      }
      final out = a.onGlasses(a.current!);
      expect(
        utf8.encode(out).length,
        lessThanOrEqualTo(AssistantService.maxBytes),
      );
      expect(out, contains('Q|Вопрос 136'));
      expect(out, isNot(contains('Q|Вопрос 0\n')));
    });
  });
}
