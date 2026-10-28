import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import 'agent.dart';
import 'assistant.dart';
import 'glaz_log.dart';
import 'speech.dart';

/// What a check found a claim to be.
enum Verdict {
  checking('P', 'Checking'),
  right('T', 'True'),
  wrong('F', 'False'),
  partly('M', 'Partly true'),
  unknown('U', 'Unknown');

  const Verdict(this.code, this.label);

  /// Its letter on the wire (docs/PROTOCOL.md, "Fact check").
  final String code;
  final String label;

  static Verdict byCode(String? code) =>
      values.where((v) => v.code == code).firstOrNull ?? unknown;

  /// The agent's word for it: true, false, partly, unknown.
  static Verdict parse(Object? word) {
    final w = '${word ?? ''}'.trim().toLowerCase();
    if (w == 'true' || w == 'correct') return right;
    if (w == 'false' || w == 'incorrect') return wrong;
    if (w.startsWith('part') || w == 'mixed' || w == 'misleading') {
      return partly;
    }
    return unknown;
  }

  /// The word the glasses show over a check, in capitals, in [language]
  /// (a BCP 47 tag, Settings.assistantLanguage) where it is one of a few.
  String word(String language) {
    final words = _words[language.split('-').first] ?? _words['en']!;
    return words[index];
  }

  static const _words = {
    'en': ['CHECKING..', 'TRUE', 'FALSE', 'PARTLY TRUE', 'UNKNOWN'],
    'ru': ['ПРОВЕРЯЮ..', 'ПРАВДА', 'ЛОЖЬ', 'ОТЧАСТИ ПРАВДА', 'НЕИЗВЕСТНО'],
    'de': ['PRUEFE..', 'WAHR', 'FALSCH', 'TEILWEISE WAHR', 'UNKLAR'],
    'fr': ['VERIFICATION..', 'VRAI', 'FAUX', 'EN PARTIE VRAI', 'INCONNU'],
    'es': [
      'VERIFICANDO..',
      'VERDADERO',
      'FALSO',
      'EN PARTE CIERTO',
      'DESCONOCIDO',
    ],
  };
}

/// A claim heard, and what its check found.
class Fact {
  Fact(this.id, this.claim, this.short, {DateTime? at})
    : at = at ?? DateTime.now();

  /// 1..65535, unique within its session.
  final int id;
  final String claim;

  /// The claim in a few words, as the agent put it.
  final String short;
  final DateTime at;
  Verdict verdict = Verdict.checking;
  String summary = '';
  List<String> sources = const [];

  Map<String, Object?> toJson() => {
    'id': id,
    'claim': claim,
    'short': short,
    'at': at.millisecondsSinceEpoch,
    'v': verdict.code,
    'summary': summary,
    'sources': sources,
  };

  factory Fact.fromJson(Map<String, dynamic> j) =>
      Fact(
          j['id'] as int,
          j['claim'] as String,
          j['short'] as String? ?? '',
          at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        )
        ..verdict = Verdict.byCode(j['v'] as String?)
        ..summary = j['summary'] as String? ?? ''
        ..sources = [for (final s in j['sources'] as List? ?? const []) '$s'];
}

/// What was said between two cuts.
class FactSegment {
  FactSegment(this.text, {DateTime? at}) : at = at ?? DateTime.now();
  final String text;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'text': text,
    'at': at.millisecondsSinceEpoch,
  };

  factory FactSegment.fromJson(Map<String, dynamic> j) => FactSegment(
    j['text'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
  );
}

/// One go of Fact check on the glasses: from opening it to leaving.
class FactSession {
  FactSession(this.id, {DateTime? at}) : at = at ?? DateTime.now();
  final int id;
  final DateTime at;
  final segments = <FactSegment>[];

  /// Oldest first.
  final facts = <Fact>[];
  int _nextFact = 1;

  /// Its cuts still being transcribed or having their claims pulled out;
  /// not kept.
  int pending = 0;

  Fact? fact(int id) => facts.where((f) => f.id == id).firstOrNull;

  Fact _add(String claim, String short) {
    final f = Fact(_nextFact, claim, short);
    _nextFact = _nextFact % 65535 + 1;
    facts.add(f);
    return f;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.millisecondsSinceEpoch,
    'next': _nextFact,
    'segments': [for (final s in segments) s.toJson()],
    'facts': [for (final f in facts) f.toJson()],
  };

  factory FactSession.fromJson(Map<String, dynamic> j) {
    final s = FactSession(
      j['id'] as int,
      at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
    );
    s.segments.addAll([
      for (final g in j['segments'] as List? ?? const [])
        FactSegment.fromJson(g as Map<String, dynamic>),
    ]);
    s.facts.addAll([
      for (final f in j['facts'] as List? ?? const [])
        Fact.fromJson(f as Map<String, dynamic>),
    ]);
    s._nextFact = j['next'] as int? ?? s.facts.length + 1;
    return s;
  }
}

/// The JSON in an agent's answer: fences and talk around it dropped, from
/// the first [open] to the last [close].
Object? _jsonIn(String reply, String open, String close) {
  final text = reply.replaceAll(RegExp(r'```[a-zA-Z]*'), '');
  final from = text.indexOf(open);
  final to = text.lastIndexOf(close);
  if (from < 0 || to < from) {
    throw const FormatException('no JSON in the answer');
  }
  return jsonDecode(text.substring(from, to + 1));
}

/// The claims in the agent's answer to [claimsPrompt]: (claim, short)
/// each; a [FormatException] if there is no list in it.
@visibleForTesting
List<(String, String)> parseClaims(String reply) {
  final json = _jsonIn(reply, '[', ']');
  if (json is! List) throw const FormatException('not a list');
  final out = <(String, String)>[];
  for (final c in json) {
    final claim = (c is Map ? c['claim'] : c)?.toString().trim() ?? '';
    if (claim.isEmpty) continue;
    final short = c is Map ? c['short']?.toString().trim() ?? '' : '';
    out.add((claim, short.isEmpty ? claim : short));
  }
  return out;
}

/// The agent's answer to [checkPrompt]: verdict, summary, sources; a
/// [FormatException] if there is no object in it.
@visibleForTesting
(Verdict, String, List<String>) parseCheck(String reply) {
  final json = _jsonIn(reply, '{', '}');
  if (json is! Map) throw const FormatException('not an object');
  final sources = json['sources'];
  final urls = <String>[];
  if (sources is List) {
    for (final s in sources) {
      final url = '${(s is Map ? s['url'] : s) ?? ''}'.trim();
      if (url.isNotEmpty) urls.add(url);
    }
  }
  return (
    Verdict.parse(json['verdict']),
    '${json['summary'] ?? ''}'.trim(),
    urls,
  );
}

/// What the agent is told to pull the claims out of what was said.
const claimsPrompt = '''
You pull checkable factual claims out of a conversation, heard through smart glasses and transcribed by speech recognition: words may be misheard, and there is no punctuation or speaker names.
Answer with JSON only, no other text: an array of objects {"claim": the claim in full, as a sentence that stands on its own, "short": the claim in at most 22 characters}. Both in the language of the speech.
Only claims of fact that can be checked: numbers, dates, events, records, what is so about the world. Not opinions, plans, feelings, questions or small talk. Each claim once.
If there are none, answer [].''';

/// What the agent is told to check a claim with; [now] the date it is.
String checkPrompt(DateTime now) =>
    '''
You check a factual claim heard in a conversation. Today is ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.
Search the web for it and read what you find. Answer with JSON only, no other text: {"verdict": "true", "false", "partly" or "unknown", "summary": at most three short sentences on what is so, in the language of the claim, "sources": [the URLs you based it on]}.
Say "unknown" when you found no source for it: never guess.''';

/// Fact check (docs/PROTOCOL.md, "Fact check"): the glasses' Fact check
/// streams everything said around the wearer; at each tap the phone takes
/// what was said since the last, has the agent pull the claims out of it
/// and check each one, and sends the glasses the list, coloured by verdict.
class FactCheckService extends ChangeNotifier {
  FactCheckService(
    this.link,
    this.settings,
    this.transcriber, {
    Agent? Function(Settings)? agent,
    this.dir,
  }) : _agentFor = agent ?? AssistantService.defaultAgent {
    link.events.listen(onMessage);
    link.addListener(() {
      if (!link.connected) {
        _onGlasses = false;
        _drop();
      }
    });
  }

  final FrameLink link;
  final Settings settings;

  /// Null where the phone has no speech recognition.
  final Transcriber? transcriber;

  /// The assistant's agent: the same server, key and model.
  final Agent? Function(Settings) _agentFor;

  /// Where the sessions are kept, factchecks.json, next to the
  /// assistant's chats; null: not kept (tests).
  final Directory? dir;

  /// The newest this many sessions are kept.
  static const sessionsKept = 30;

  /// The most sent to the glasses at once, in bytes.
  static const maxBytes = 900;

  /// Every session kept with something heard in it, newest first.
  final sessions = <FactSession>[];

  /// The session on the glasses now, or last; null before the first.
  FactSession? current;

  /// Listening to the glasses' sound now.
  bool get listening => _transcription != null;

  /// What is heard since the last cut, as it is heard.
  String heard = '';

  /// The current session's cuts still being transcribed or having their
  /// claims pulled out.
  int get pending => current?.pending ?? 0;

  int _nextSession = 1;
  Transcription? _transcription;
  StreamSubscription<Heard>? _heardSub;
  Future<void> _feed = Future.value();
  int _rate = 8000;
  int _bits = 8;

  /// The fact open on the glasses, sent again when its check comes.
  int? _opened;

  /// Fact check is open on the glasses. Not open, nothing is sent: a
  /// MODULE_CALL would start it in the background, in place of the app
  /// that is there (Recorder recording, say).
  bool _onGlasses = false;

  File? get _file => dir == null ? null : File('${dir!.path}/factchecks.json');

  /// The sessions kept on the phone, read once at start.
  Future<void> load() async {
    final f = _file;
    try {
      if (f == null || !await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      sessions
        ..clear()
        ..addAll([
          for (final s in j['sessions'] as List)
            FactSession.fromJson(s as Map<String, dynamic>),
        ]);
      _nextSession = j['next'] as int? ?? sessions.length + 1;
    } catch (e) {
      glazLog(LogKind.factcheck, 'sessions not read: $e', problem: true);
    }
    notifyListeners();
  }

  /// Saves one after another, never two writing the file at once.
  Future<void> _saving = Future.value();

  /// Done when what was found so far is on disk.
  @visibleForTesting
  Future<void> get saved => _saving;

  void _save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'next': _nextSession,
          'sessions': [for (final s in sessions) s.toJson()],
        }),
      );
    } catch (e) {
      glazLog(LogKind.factcheck, 'sessions not saved: $e', problem: true);
    }
  }

  /// Forgets [session] for good.
  void remove(FactSession session) {
    sessions.remove(session);
    notifyListeners();
    _save();
  }

  @visibleForTesting
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case recStart:
        if (m.length > 3 && m[3] == forFactcheck) {
          _start(
            m.length > 1 && m[1] == 16 ? 16 : 8,
            m.length > 2 && m[2] > 0 ? m[2] * 1000 : 8000,
          );
        } else {
          // another app's sound from now on
          _onGlasses = false;
          if (listening) _drop();
        }
      case audioChunk:
        _add(m.sublist(1));
      case audioEnd:
        // not sent by Fact check: the sound stopped, what came is checked
        if (!listening) return;
        _add(m.sublist(1));
        _cut(next: false);
      case facts:
        _onFacts(m);
    }
  }

  /// The glasses' Fact check: left, cut, open a fact, the list again
  /// (`FACTS`, docs/PROTOCOL.md, "Fact check").
  void _onFacts(List<int> m) {
    final op = m.length > 1 ? m[1] : -1;
    final id = m.length > 3 ? m[2] << 8 | m[3] : 0;
    // a cut comes only from Fact check open; the list or a fact asked for
    // say it is
    if (op == 0) _onGlasses = false;
    if (op == 2 || op == 3) _onGlasses = true;
    switch (op) {
      case 0:
        // the sound since the last cut is not checked; checks running go on
        _opened = null;
        if (!listening) return;
        glazLog(LogKind.factcheck, 'left on the glasses');
        _drop();
      case 1:
        if (listening) _cut(next: true);
      case 2:
        _opened = id;
        final fact = current?.fact(id);
        _call(fact == null ? 'e:This fact is gone' : glassesFact(fact));
      case 3:
        _sendList();
    }
  }

  void _start(int bits, int rate) {
    _drop();
    _opened = null;
    _onGlasses = true;
    current = FactSession(_nextSession++);
    _sendList();
    if (!settings.serviceOn('factcheck')) {
      _call('e:Fact check is off: Glaz > More > Services');
      return;
    }
    final t = transcriber;
    if (t == null) {
      _call('e:No speech recognition on this phone');
      return;
    }
    if (_agentFor(settings) == null) {
      _call('e:Set up the agent: Glaz > Menu > Assistant');
      return;
    }
    _bits = bits;
    _rate = rate;
    glazLog(LogKind.factcheck, 'listening');
    _listen(t);
  }

  /// A new transcription for the sound that follows.
  void _listen(Transcriber t) {
    final tr = _transcription = t.start(settings.assistantLanguage);
    heard = '';
    _heardSub = tr.heard.listen((_) {
      heard = tr.text;
      notifyListeners();
    });
    notifyListeners();
  }

  void _add(List<int> samples) {
    final tr = _transcription;
    if (tr == null || samples.isEmpty) return;
    _feed = _feed
        .then((_) => tr.add(samples, rate: _rate, bits: _bits))
        .catchError((_) {});
  }

  /// What was said since the last cut is checked; with [next], listening
  /// goes on in a transcription of its own.
  void _cut({required bool next}) {
    final tr = _transcription!;
    final feed = _feed;
    final session = current!;
    _heardSub?.cancel();
    _heardSub = null;
    _transcription = null;
    if (next && transcriber != null) _listen(transcriber!);
    session.pending++;
    notifyListeners();
    _sendList(session);
    _check(session, tr, feed).whenComplete(() {
      session.pending--;
      notifyListeners();
      _sendList(session);
    }).ignore();
  }

  Future<void> _check(
    FactSession session,
    Transcription tr,
    Future<void> feed,
  ) async {
    await feed;
    String text;
    try {
      await tr.finish();
      text = await tr.done;
    } on TranscriptionError catch (e) {
      glazLog(LogKind.factcheck, 'recognition: ${e.message}', problem: true);
      text = e.text;
    } catch (e) {
      glazLog(LogKind.factcheck, 'recognition: $e', problem: true);
      text = tr.text;
    }
    text = text.trim();
    if (text.isEmpty) {
      _call('n:Nothing heard', session);
      return;
    }
    glazLog(LogKind.factcheck, 'heard: $text');
    session.segments.add(FactSegment(text));
    if (!sessions.contains(session)) {
      sessions.insert(0, session);
      while (sessions.length > sessionsKept) {
        sessions.removeLast();
      }
    }
    _save();

    final agent = _agentFor(settings);
    if (agent == null) {
      _call('e:Set up the agent: Glaz > Menu > Assistant', session);
      return;
    }
    List<(String, String)> claims;
    try {
      claims = parseClaims(
        await agent.ask([
          const AgentMessage('system', claimsPrompt),
          AgentMessage('user', text),
        ]),
      );
    } on FormatException {
      glazLog(LogKind.factcheck, 'no claims in the answer', problem: true);
      _call('e:The agent answered something else', session);
      return;
    } catch (e) {
      glazLog(LogKind.factcheck, 'claims: $e', problem: true);
      _call('e:${oneRow('$e')}', session);
      return;
    }
    if (claims.isEmpty) {
      _call('n:No facts in that', session);
      return;
    }
    final added = [for (final (c, s) in claims) session._add(c, s)];
    glazLog(
      LogKind.factcheck,
      'claims: ${claims.map((c) => c.$1).join(' / ')}',
    );
    notifyListeners();
    _save();
    // the list as it is now, with the cut no longer pending, comes from
    // _cut; the checks go on after it
    for (final f in added) {
      _verify(session, f, agent).ignore();
    }
  }

  /// Checks [fact] with [agent]; what goes wrong is its summary.
  Future<void> _verify(FactSession session, Fact fact, Agent agent) async {
    try {
      final (v, summary, sources) = parseCheck(
        await agent.ask([
          AgentMessage('system', checkPrompt(DateTime.now())),
          AgentMessage('user', fact.claim),
        ]),
      );
      fact
        ..verdict = v
        ..summary = summary
        ..sources = sources;
    } on FormatException {
      fact
        ..verdict = Verdict.unknown
        ..summary = 'The agent answered something else';
    } catch (e) {
      fact
        ..verdict = Verdict.unknown
        ..summary = '$e';
    }
    glazLog(
      LogKind.factcheck,
      '${fact.verdict.label}: ${fact.claim}${fact.summary.isEmpty ? '' : ' -- ${fact.summary}'}',
      problem: fact.verdict == Verdict.unknown && fact.sources.isEmpty,
    );
    notifyListeners();
    _save();
    _sendList(session);
    if (session == current && _opened == fact.id) {
      _call(glassesFact(fact), session);
    }
  }

  /// The facts as the glasses list them: `f:<pending>`, then
  /// `\n<id>|<verdict>|<short>` each, oldest first, the newest that fit in
  /// [maxBytes].
  @visibleForTesting
  String glassesList([FactSession? session]) {
    final s = session ?? current;
    final head = 'f:${s?.pending ?? 0}';
    final lines = <String>[];
    var bytes = utf8.encode(head).length;
    for (final f in (s?.facts ?? const <Fact>[]).reversed) {
      final line = '\n${f.id}|${f.verdict.code}|${glassesShort(f.short)}';
      final n = utf8.encode(line).length;
      if (bytes + n > maxBytes) break;
      bytes += n;
      lines.insert(0, line);
    }
    return '$head${lines.join()}';
  }

  /// [short] cut to a row of the list: the glasses put a mark and a space
  /// before it.
  static String glassesShort(String short) {
    final s = forGlasses(short).replaceAll(RegExp(r'[\s|]+'), ' ').trim();
    return s.length > 22 ? '${s.substring(0, 20)}..' : s;
  }

  /// [fact] for the glasses: `d:<id>:<verdict>`, then the verdict word, the
  /// claim, the summary and the sources' sites, in lines cut to the screen,
  /// as many as fit in [maxBytes].
  @visibleForTesting
  String glassesFact(Fact fact) {
    final text = [
      fact.verdict.word(settings.assistantLanguage),
      fact.claim,
      if (fact.summary.isNotEmpty) fact.summary,
      for (final s in fact.sources.map(site).toSet().take(3)) s,
    ].join('\n');
    final out = StringBuffer('d:${fact.id}:${fact.verdict.code}');
    var bytes = out.length;
    for (final l in wrapForGlasses(text, maxLines: 60).split('\n')) {
      final n = utf8.encode(l).length + 1;
      if (bytes + n > maxBytes) break;
      bytes += n;
      out.write('\n$l');
    }
    return out.toString();
  }

  /// The site a source is on, as the glasses show it: wikipedia.org for
  /// https://en.wikipedia.org/wiki/..., bbc.co.uk for www.bbc.co.uk.
  static String site(String url) {
    final u = Uri.tryParse(url.trim());
    final host = u == null || u.host.isEmpty ? url.trim() : u.host;
    final parts = host.split('.');
    // co.uk, com.au: the name is the label before them
    final keep =
        parts.length > 2 &&
            parts.last.length == 2 &&
            parts[parts.length - 2].length <= 3
        ? 3
        : 2;
    return parts.length <= keep
        ? host
        : parts.sublist(parts.length - keep).join('.');
  }

  /// [text] for the status row: what the font has, one line, 60
  /// characters at most.
  static String oneRow(String text) {
    final s = forGlasses(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 60 ? '${s.substring(0, 58)}..' : s;
  }

  void _sendList([FactSession? session]) {
    if ((session ?? current) != current) return;
    _call(glassesList());
  }

  /// To Fact check on the glasses: only seen while it is on screen. What
  /// is for [session] no longer there is not sent.
  void _call(String arg, [FactSession? session]) {
    if (!_onGlasses || (session != null && session != current)) return;
    link.callModule('factcheck', arg);
  }

  /// Stops listening: what was heard since the last cut is not checked.
  void _drop() {
    _heardSub?.cancel();
    _heardSub = null;
    final tr = _transcription;
    _transcription = null;
    heard = '';
    if (tr != null) {
      tr.cancel().catchError((_) {});
      notifyListeners();
    }
  }
}
