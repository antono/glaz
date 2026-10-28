import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/agent.dart';
import 'package:glaz/services/assistant.dart';
import 'package:glaz/services/factcheck.dart';
import 'package:glaz/services/speech.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink;

/// Hears each piece of sound as the text its bytes spell.
class TextTranscriber extends Transcriber {
  int starts = 0;
  final cancelled = <String>[];

  @override
  Future<SpeechModel> model(String language) async => SpeechModel.available;

  @override
  Future<void> download(
    String language, {
    void Function(int got, int total)? progress,
  }) async {}

  @override
  Transcription start(String language) {
    starts++;
    return _Heard(this);
  }
}

class _Heard extends Transcription {
  _Heard(this.t);
  final TextTranscriber t;

  @override
  Future<void> add(
    List<int> samples, {
    required int rate,
    required int bits,
    bool unsigned8 = false,
  }) async => hear(Heard(utf8.decode(samples)));

  @override
  Future<void> finish() async => end();

  @override
  Future<void> cancel() async {
    t.cancelled.add(text);
    end();
  }
}

/// Answers the claims prompt with [claims] and each check from [checks],
/// by the claim; a check not in it waits for [release].
class ScriptAgent implements Agent {
  String claims = '[]';
  final checks = <String, String>{};
  final asked = <List<AgentMessage>>[];
  final waiting = <String, Completer<String>>{};
  Object? fail;

  @override
  Future<String> ask(List<AgentMessage> messages) async {
    asked.add(messages);
    if (fail != null) throw fail!;
    final user = messages.last.content;
    if (messages.first.content == claimsPrompt) return claims;
    final reply = checks[user];
    if (reply != null) return reply;
    return (waiting[user] = Completer<String>()).future;
  }

  void release(String claim, String reply) =>
      waiting.remove(claim)!.complete(reply);
}

List<int> say(String text) => [audioChunk, ...utf8.encode(text)];

void main() {
  late Settings settings;
  late SentLink link;
  late TextTranscriber transcriber;
  late ScriptAgent agent;
  late FactCheckService fc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    link = SentLink();
    transcriber = TextTranscriber();
    agent = ScriptAgent();
    fc = FactCheckService(link, settings, transcriber, agent: (_) => agent);
  });

  /// What went to the glasses' Fact check, in order.
  List<String> calls() => [
    for (final (code, text) in link.sent)
      if (code == moduleCall && text.startsWith('factcheck\n'))
        text.substring('factcheck\n'.length),
  ];

  String lastCall() => calls().last;

  String claim(String c, String short) => '{"claim": "$c", "short": "$short"}';

  String check(String v, String summary, [List<String> urls = const []]) =>
      jsonEncode({'verdict': v, 'summary': summary, 'sources': urls});

  test('a new session: an empty list, then listening', () {
    fc.onMessage([recStart, 16, 8, forFactcheck]);
    expect(calls(), ['f:0']);
    expect(fc.listening, isTrue);
    expect(transcriber.starts, 1);
  });

  test(
    'a cut checks what was said since the last; listening goes on',
    () async {
      agent.claims =
          '[${claim('The Eiffel Tower is 137 m tall', 'Eiffel 137 m')}]';
      agent.checks['The Eiffel Tower is 137 m tall'] = check(
        'false',
        'It is 330 m tall.',
        ['https://en.wikipedia.org/wiki/Eiffel_Tower'],
      );
      fc.onMessage([recStart, 8, 8, forFactcheck]);
      fc.onMessage(say('the tower is'));
      fc.onMessage(say('137 metres'));
      fc.onMessage([facts, 1, 0, 0]);
      // a new transcription for what follows, the cut pending
      expect(transcriber.starts, 2);
      expect(fc.listening, isTrue);
      expect(lastCall(), 'f:1');
      fc.onMessage(say('next part'));
      await pumpEventQueue();

      final asked = agent.asked.first;
      expect(asked.first.content, claimsPrompt);
      expect(asked.last.content, 'the tower is 137 metres');
      expect(agent.asked[1].last.content, 'The Eiffel Tower is 137 m tall');
      expect(lastCall(), 'f:0\n1|F|Eiffel 137 m');
      final f = fc.current!.facts.single;
      expect(f.verdict, Verdict.wrong);
      expect(f.sources, ['https://en.wikipedia.org/wiki/Eiffel_Tower']);
      expect(fc.current!.segments.single.text, 'the tower is 137 metres');

      // the next cut has only what came after the first
      agent.claims = '[]';
      fc.onMessage([facts, 1, 0, 0]);
      await pumpEventQueue();
      expect(agent.asked.last.last.content, 'next part');
      expect(calls().reversed.take(2), [
        'f:0\n1|F|Eiffel 137 m',
        'n:No facts in that',
      ]);
      expect(fc.sessions, [fc.current]);
    },
  );

  test('checks in parallel; the list as each comes', () async {
    agent.claims = '[${claim('A is 1', 'A one')}, ${claim('B is 2', 'B two')}]';
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('a and b'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    expect(agent.waiting.keys, ['A is 1', 'B is 2']);
    expect(lastCall(), 'f:0\n1|P|A one\n2|P|B two');

    agent.release('B is 2', check('true', 'Yes.'));
    await pumpEventQueue();
    expect(lastCall(), 'f:0\n1|P|A one\n2|T|B two');
    agent.release('A is 1', check('partly', 'Almost.'));
    await pumpEventQueue();
    expect(lastCall(), 'f:0\n1|M|A one\n2|T|B two');
  });

  test('a fact opened: d:, again when its check comes', () async {
    agent.claims = '[${claim('Water boils at 137 C', 'Boils 137')}]';
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('water'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();

    fc.onMessage([facts, 2, 0, 1]);
    expect(lastCall(), 'd:1:P\nCHECKING..\nWater boils at 137 C');

    agent.release(
      'Water boils at 137 C',
      check('false', 'At sea level it boils at 100 C.', [
        'https://www.britannica.com/science/boiling-point',
        'https://en.wikipedia.org/wiki/Boiling_point',
        'https://de.wikipedia.org/wiki/Siedepunkt',
        'https://www.bbc.co.uk/x',
      ]),
    );
    await pumpEventQueue();
    expect(calls().reversed.take(2).toList().reversed, [
      'f:0\n1|F|Boils 137',
      'd:1:F\nFALSE\nWater boils at 137 C\nAt sea level it boils at\n100 C.\n'
          'britannica.com\nwikipedia.org\nbbc.co.uk',
    ]);

    fc.onMessage([facts, 2, 0, 9]);
    expect(lastCall(), 'e:This fact is gone');
  });

  test('the list again on op 3', () async {
    fc.onMessage([facts, 3, 0, 0]);
    expect(lastCall(), 'f:0');
    agent.claims = '[${claim('X', 'x')}]';
    agent.checks['X'] = check('unknown', 'No source.');
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('x'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    link.sent.clear();
    fc.onMessage([facts, 3, 0, 0]);
    expect(calls(), ['f:0\n1|U|x']);
  });

  test(
    'op 0: the sound since the cut dropped, checks running finish',
    () async {
      final dir = Directory.systemTemp.createTempSync('glaz_facts');
      addTearDown(() => dir.deleteSync(recursive: true));
      fc = FactCheckService(
        link,
        settings,
        transcriber,
        agent: (_) => agent,
        dir: dir,
      );
      agent.claims = '[${claim('Y is 137', 'Y 137')}]';
      fc.onMessage([recStart, 8, 8, forFactcheck]);
      fc.onMessage(say('y'));
      fc.onMessage([facts, 1, 0, 0]);
      await pumpEventQueue();
      fc.onMessage(say('not checked'));
      await pumpEventQueue();
      fc.onMessage([facts, 0, 0, 0]);
      await pumpEventQueue();
      expect(fc.listening, isFalse);
      expect(transcriber.cancelled, ['not checked']);

      // a cut after leaving is nothing
      final n = agent.asked.length;
      fc.onMessage([facts, 1, 0, 0]);
      await pumpEventQueue();
      expect(agent.asked, hasLength(n));

      // nothing to the glasses: it would start Fact check in the
      // background, in place of the app there
      link.sent.clear();
      agent.release('Y is 137', check('true', 'So it is.'));
      await pumpEventQueue();
      expect(calls(), isEmpty);
      await fc.saved;
      final again = FactCheckService(link, settings, transcriber, dir: dir);
      await again.load();
      final f = again.sessions.single.facts.single;
      expect(f.verdict, Verdict.right);
      expect(f.summary, 'So it is.');
      expect(again.sessions.single.segments.single.text, 'y');
    },
  );

  test('nothing to the glasses once another app has the sound', () async {
    agent.claims = '[${claim('Z', 'z')}]';
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('z'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    fc.onMessage([recStart, 8, 8, 0]); // Recorder
    link.sent.clear();
    agent.release('Z', check('true', 'Yes.'));
    await pumpEventQueue();
    expect(calls(), isEmpty);
    fc.onMessage([facts, 3, 0, 0]); // opened again: the list
    expect(calls(), ['f:0\n1|T|z']);
  });

  test('nothing heard: a note, nothing asked', () async {
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    expect(calls(), ['f:0', 'f:1', 'n:Nothing heard', 'f:0']);
    expect(agent.asked, isEmpty);
    expect(fc.sessions, isEmpty);
  });

  test('what goes wrong: no agent, no recognition, agent errors', () async {
    fc = FactCheckService(link, settings, transcriber, agent: (_) => null);
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    expect(lastCall(), 'e:Set up the agent: Glaz > Menu > Assistant');
    expect(fc.listening, isFalse);

    fc = FactCheckService(link, settings, null, agent: (_) => agent);
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    expect(lastCall(), 'e:No speech recognition on this phone');

    settings.setService('factcheck', false);
    fc = FactCheckService(link, settings, transcriber, agent: (_) => agent);
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    expect(lastCall(), startsWith('e:Fact check is off'));
    settings.setService('factcheck', true);

    agent.fail = AgentError('no answer in 120 s');
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('z'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    expect(calls().reversed.take(2), ['f:0', 'e:no answer in 120 s']);
  });

  test('a check gone wrong is unknown, with why', () async {
    agent.claims = '[${claim('P', 'p')}, ${claim('Q', 'q')}]';
    agent.checks['P'] = 'I could not find anything, sorry.';
    agent.checks['Q'] = '{"verdict": "true", "summary": ';
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage(say('p q'));
    fc.onMessage([facts, 1, 0, 0]);
    await pumpEventQueue();
    expect(lastCall(), 'f:0\n1|U|p\n2|U|q');
    expect(
      fc.current!.facts.first.summary,
      'The agent answered something else',
    );
  });

  test('another app\'s sound stops listening', () {
    fc.onMessage([recStart, 8, 8, forFactcheck]);
    fc.onMessage([recStart, 8, 8, forAssistant]);
    expect(fc.listening, isFalse);
  });

  test('the assistant drops its question on Fact check\'s sound', () {
    final a = AssistantService(link, settings, transcriber);
    a.onMessage([recStart, 8, 8, forAssistant]);
    expect(a.state, AssistantState.listening);
    a.onMessage([recStart, 8, 8, forFactcheck]);
    expect(a.state, AssistantState.idle);
  });

  group('parsing', () {
    test('claims in fences, with talk around them', () {
      expect(
        parseClaims(
          'Here you go:\n```json\n[{"claim": "Moscow has 137 metro '
          'stations", "short": "Metro 137"}, "Bare claim", {"short": "x"}]\n'
          '```\nHope it helps!',
        ),
        [
          ('Moscow has 137 metro stations', 'Metro 137'),
          ('Bare claim', 'Bare claim'),
        ],
      );
      expect(parseClaims('[]'), isEmpty);
      expect(() => parseClaims('No claims here.'), throwsFormatException);
      expect(() => parseClaims('[{"claim": '), throwsFormatException);
    });

    test('a check, fenced; sources as URLs or objects', () {
      final (v, summary, sources) = parseCheck(
        '```\n{"verdict": "Partly", "summary": "Close.", "sources": '
        '["https://a.org/1", {"url": "https://b.org"}, ""]}\n```',
      );
      expect(v, Verdict.partly);
      expect(summary, 'Close.');
      expect(sources, ['https://a.org/1', 'https://b.org']);
      expect(parseCheck('{"verdict": "maybe"}').$1, Verdict.unknown);
      expect(() => parseCheck('true'), throwsFormatException);
    });
  });

  group('for the glasses', () {
    test('a short is a row: 22 characters at most, | and newlines out', () {
      expect(
        FactCheckService.glassesShort('Exactly twenty-two ch.'),
        'Exactly twenty-two ch.',
      );
      expect(
        FactCheckService.glassesShort('Twenty-three characters'),
        'Twenty-three charact..',
      );
      expect(FactCheckService.glassesShort('a|b\nc'), 'a b c');
    });

    test('the list keeps the newest that fit in 900 bytes', () {
      final s = fc.current = FactSession(1);
      for (var i = 0; i < 137; i++) {
        s.facts.add(Fact(i + 1, 'claim $i', 'Short claim number $i'));
      }
      final list = fc.glassesList();
      expect(utf8.encode(list).length, lessThanOrEqualTo(900));
      final lines = list.split('\n');
      expect(lines.first, 'f:0');
      expect(lines.last, '137|P|Short claim number 136');
      final ids = [for (final l in lines.skip(1)) int.parse(l.split('|')[0])];
      expect(ids, List.generate(ids.length, (i) => 138 - ids.length + i));
    });

    test('a fact is cut to 900 bytes, in the language heard', () {
      settings.assistantLanguage = 'ru-RU';
      final f = Fact(7, 'Утверждение', 'у')
        ..verdict = Verdict.right
        ..summary = 'Очень длинное объяснение ' * 80;
      final d = fc.glassesFact(f);
      expect(utf8.encode(d).length, lessThanOrEqualTo(900));
      expect(d, startsWith('d:7:T\nПРАВДА\nУтверждение\nОчень'));
      for (final l in d.split('\n').skip(1)) {
        expect(l.length, lessThanOrEqualTo(26));
      }
    });
  });
}
