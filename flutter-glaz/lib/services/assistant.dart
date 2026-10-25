import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../glasses_menu.dart';
import '../settings.dart';
import 'agent.dart';
import 'agent_files.dart';
import 'glaz_log.dart';
import 'notifications.dart';
import 'speech.dart';
import 'voice.dart';

/// A command for the glasses in the agent's answer: a line of its own,
/// '@open weather'.
class GlassesCommand {
  const GlassesCommand(this.name, this.arg);
  final String name;
  final String arg;

  @override
  bool operator ==(Object other) =>
      other is GlassesCommand && other.name == name && other.arg == arg;

  @override
  int get hashCode => Object.hash(name, arg);

  @override
  String toString() => '@$name $arg'.trim();
}

final _commandLine = RegExp(r'^@([a-z]+)\b\s*(.*)$');

/// The agent's answer split: the text for the wearer, and the commands for
/// the glasses, in order. A command may come in backticks.
(String, List<GlassesCommand>) splitReply(String reply) {
  final text = <String>[];
  final commands = <GlassesCommand>[];
  for (final raw in reply.split('\n')) {
    final line = raw.trim().replaceAll(RegExp(r'^`+|`+$'), '').trim();
    final m = _commandLine.firstMatch(line);
    if (m != null) {
      commands.add(GlassesCommand(m[1]!, m[2]!.trim()));
    } else {
      text.add(raw);
    }
  }
  return (text.join('\n').trim(), commands);
}

/// [text] as the glasses show it: what their font has, in lines of at
/// most [width] characters, at most [maxLines] of them, the last ending in '..' if cut.
String wrapForGlasses(String text, {int width = 26, int maxLines = 24}) {
  final lines = <String>[];
  for (final para in forGlasses(text).split('\n')) {
    var line = '';
    for (var word in para.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      while (word.length > width) {
        if (line.isNotEmpty) lines.add(line);
        line = '';
        lines.add(word.substring(0, width));
        word = word.substring(width);
      }
      if (line.isEmpty) {
        line = word;
      } else if (line.length + 1 + word.length <= width) {
        line = '$line $word';
      } else {
        lines.add(line);
        line = word;
      }
    }
    if (line.isNotEmpty) lines.add(line);
  }
  if (lines.length > maxLines) {
    lines.removeRange(maxLines, lines.length);
    final last = lines[maxLines - 1];
    lines[maxLines - 1] =
        '${last.length > width - 2 ? last.substring(0, width - 2) : last}..';
  }
  return lines.join('\n');
}

/// The commands that bring the agent something, for [systemPrompt].
String _queries() =>
    '''
These commands bring you something instead. Write only them in that answer; the phone sends what they bring in the next message, and then you answer the wearer:
@photo                      a photo from the glasses' camera, taken now: what the wearer is looking at
@photos [day]               the photos on the phone, newest first; day: today, yesterday or ${_ymd(DateTime.now())}
@getphoto <name>            one of those photos
@recordings [day]           the wearer's voice recordings, with the start of each transcript
@transcript <name>          the whole transcript of one
''';

String _ymd(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// What the agent is told before the conversation: what the glasses are,
/// how to answer, and what it can make them do.
String systemPrompt(Settings settings) {
  final apps = StringBuffer();
  for (final section in glassesMenu) {
    for (final m in section.modules) {
      if (m.id == 'assistant' || !settings.installed(m.id)) continue;
      apps.write('- ${m.id} (${m.label}): ${m.summary}');
      for (final s in m.settings) {
        final value = settings.config(m.id, s.key) ?? s.initial;
        apps.write(
          s.text
              ? ' Setting ${m.id}.${s.key}: ${s.label}, free text, now '
                    '"$value".'
              : ' Setting ${m.id}.${s.key}: ${s.label}, one of '
                    '${s.options.join(', ')}, now $value.',
        );
      }
      apps.write('\n');
    }
  }
  return '''
You are the voice assistant of Glaz, smart glasses (Brilliant Labs Frame). The wearer said the message aloud; speech recognition may have misheard a word.
The glasses show five lines of 26 characters at a time and cannot show Cyrillic (it is transliterated). Answer briefly: one to three short sentences, no markdown, no lists, no emoji, no links. Answer in the language of the question.
You can control the glasses. Put each command on a line of its own, starting with @; the phone runs them and removes them from the text:
@open <app>                 put an app on the glasses' screen
@notify <text>              show a notification on the glasses
@set <app>.<key>=<value>    change an app's setting
@press ok|back|menu|left|right   a button of the phone's remote for the glasses
After @open the screen shows that app, not your text, so say a few words or nothing.
${settings.agentFiles ? _queries() : ''}The apps on the glasses:
$apps''';
}

/// Where the assistant's chats are kept: the app's own folder, as the
/// settings.
Future<Directory> assistantRoot() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/assistant');

/// Something the agent asked the phone for on the way to its answer -- a
/// photo, the photo list, a recording's transcript (agent_files.dart) --
/// and the start of what it brought; [result] is null while it runs.
class ToolCall {
  ToolCall(this.command, [this.result]);
  final GlassesCommand command;
  String? result;

  /// What is kept of a result: enough to see what came back.
  static const kept = 300;

  Map<String, Object?> toJson() => {
    'name': command.name,
    'arg': command.arg,
    'result': result,
  };

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
    GlassesCommand(j['name'] as String, j['arg'] as String? ?? ''),
    j['result'] as String?,
  );
}

/// One question and its answer, for the phone's screen.
class AssistantTurn {
  AssistantTurn(this.question, {DateTime? at}) : at = at ?? DateTime.now();
  final String question;
  final DateTime at;
  String? answer;
  List<GlassesCommand> commands = const [];

  /// What the agent asked the phone for on the way.
  List<ToolCall> queries = const [];
  String? error;

  Map<String, Object?> toJson() => {
    'q': question,
    'at': at.millisecondsSinceEpoch,
    'answer': answer,
    'commands': [
      for (final c in commands) {'name': c.name, 'arg': c.arg},
    ],
    'queries': [for (final q in queries) q.toJson()],
    'error': error,
  };

  factory AssistantTurn.fromJson(Map<String, dynamic> j) =>
      AssistantTurn(
          j['q'] as String,
          at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        )
        ..answer = j['answer'] as String?
        ..commands = [
          for (final c in j['commands'] as List? ?? const [])
            GlassesCommand(c['name'] as String, c['arg'] as String? ?? ''),
        ]
        ..queries = [
          for (final q in j['queries'] as List? ?? const [])
            ToolCall.fromJson(q as Map<String, dynamic>),
        ]
        ..error = j['error'] as String?;
}

/// One conversation with the agent: its questions and answers for the
/// screen, oldest first, and the text the agent is sent of it.
class AssistantChat {
  AssistantChat(this.id);
  final int id;
  final turns = <AssistantTurn>[];

  /// The last [AssistantService.keep] questions and answers, text only.
  final history = <AgentMessage>[];

  /// When it was last asked something.
  DateTime get lastAt => turns.isEmpty ? DateTime(0) : turns.last.at;

  String get title => turns.isEmpty ? 'New chat' : turns.first.question;

  Map<String, Object?> toJson() => {
    'id': id,
    'turns': [for (final t in turns) t.toJson()],
    'history': [
      for (final m in history) {'role': m.role, 'content': m.content},
    ],
  };

  factory AssistantChat.fromJson(Map<String, dynamic> j) {
    final chat = AssistantChat(j['id'] as int);
    chat.turns.addAll([
      for (final t in j['turns'] as List)
        AssistantTurn.fromJson(t as Map<String, dynamic>),
    ]);
    chat.history.addAll([
      for (final m in j['history'] as List? ?? const [])
        AgentMessage(m['role'] as String, m['content'] as String),
    ]);
    return chat;
  }
}

enum AssistantState { idle, listening, thinking }

/// The voice assistant (docs/PROTOCOL.md, "Assistant"): the glasses'
/// Assistant module streams what the wearer says, the phone transcribes it
/// and asks the agent, runs the commands in the answer and sends the rest
/// back to the glasses.
class AssistantService extends ChangeNotifier {
  AssistantService(
    this.link,
    this.settings,
    this.transcriber, {
    Agent? Function(Settings)? agent,
    this.queries,
    this.voice,
    this.dir,
  }) : _agentFor = agent ?? defaultAgent {
    link.events.listen(onMessage);
    link.addListener(() {
      if (!link.connected) _drop();
    });
    // the language picked is made ready as soon as it is picked
    settings.addListener(() {
      if (_language != null && settings.assistantLanguage != _language) {
        prepare().ignore();
      }
    });
  }

  final FrameLink link;
  final Settings settings;

  /// Null where the phone has no speech recognition.
  final Transcriber? transcriber;
  final Agent? Function(Settings) _agentFor;

  /// What the agent may ask for: photos, recordings (agent_files.dart).
  final AgentQueries? queries;

  /// Reads answers aloud, in headphones only; null where there is none.
  final Voice? voice;

  /// Where the chats are kept, chats.json; null: not kept (tests).
  final Directory? dir;

  /// Rounds of queries in one answer, at most: an agent that keeps asking
  /// gets its last answer shown.
  static const maxRounds = 3;

  static Agent? defaultAgent(Settings s) => s.agentUrl.isEmpty
      ? null
      : ChatCompletionsAgent(
          url: s.agentUrl,
          key: s.agentKey,
          model: s.agentModel,
        );

  /// A chat goes on while questions come within [forget] of each other,
  /// or of picking it on the phone; the agent is sent the last [keep]
  /// questions and answers of it. The newest [chatsKept] chats are kept.
  static const forget = Duration(minutes: 10);
  static const keep = 6;
  static const chatsKept = 50;

  /// The newest this many are listed on the glasses.
  static const glassesChats = 12;

  AssistantState state = AssistantState.idle;

  /// The language's speech model on the phone, as [prepare] last found it;
  /// null before. [downloading]: how far its download is, 0..1, while it
  /// downloads. [modelError]: why it could not be had.
  SpeechModel? model;
  double? downloading;
  String? modelError;
  String? _language;

  /// Gets the language picked ([Settings.assistantLanguage]) onto the
  /// phone, and the microphone permission the recognizer wants.
  Future<void> prepare() async {
    final t = transcriber;
    if (t == null) return;
    final language = _language = settings.assistantLanguage;
    model = null;
    modelError = null;
    notifyListeners();
    try {
      await t.permit();
      var m = await t.model(language);
      if (m == SpeechModel.downloadable || m == SpeechModel.downloading) {
        downloading = 0;
        notifyListeners();
        await t.download(
          language,
          progress: (got, total) {
            downloading = total > 0 ? got / total : null;
            notifyListeners();
          },
        );
        m = await t.model(language);
      }
      if (language == _language) model = m;
    } catch (e) {
      if (language == _language) modelError = '$e';
    } finally {
      downloading = null;
      notifyListeners();
    }
  }

  /// What is heard of the question being asked, as it is heard.
  String heard = '';

  /// Every chat kept, the one asked last first.
  final chats = <AssistantChat>[];

  /// The chat the next question goes to; null: a new one.
  AssistantChat? current;

  /// The current chat's questions and answers, oldest first.
  List<AssistantTurn> get turns => current?.turns ?? const [];

  DateTime _lastAt = DateTime(0);
  int _nextChat = 1;

  File? get _file => dir == null ? null : File('${dir!.path}/chats.json');

  /// The chats kept on the phone, read once at start.
  Future<void> load() async {
    final f = _file;
    try {
      if (f == null || !await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      chats
        ..clear()
        ..addAll([
          for (final c in j['chats'] as List)
            AssistantChat.fromJson(c as Map<String, dynamic>),
        ]);
      _nextChat = j['next'] as int? ?? chats.length + 1;
    } catch (e) {
      glazLog(LogKind.assistant, 'chats not read: $e', problem: true);
    }
    notifyListeners();
  }

  /// Saves one after another, never two writing the file at once.
  Future<void> _saving = Future.value();

  /// Done when what was asked so far is on disk.
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
          'next': _nextChat,
          'chats': [for (final c in chats) c.toJson()],
        }),
      );
    } catch (e) {
      glazLog(LogKind.assistant, 'chats not saved: $e', problem: true);
    }
  }

  /// [chat] goes on: the next question, from the glasses too, goes to it.
  void open(AssistantChat chat) {
    current = chat;
    _lastAt = DateTime.now();
    notifyListeners();
  }

  /// The next question starts a chat of its own.
  void newChat() {
    current = null;
    notifyListeners();
  }

  /// Forgets [chat] for good.
  void remove(AssistantChat chat) {
    chats.remove(chat);
    if (current == chat) current = null;
    notifyListeners();
    _save();
  }

  /// The chat a question asked [now] goes to: the current one, unless
  /// nothing was asked or picked for [forget].
  AssistantChat _chatAt(DateTime now) {
    var chat = current;
    if (chat == null || now.difference(_lastAt) > forget) {
      chat = current = AssistantChat(_nextChat++);
    }
    _lastAt = now;
    chats
      ..remove(chat)
      ..insert(0, chat);
    while (chats.length > chatsKept) {
      chats.removeLast();
    }
    return chat;
  }

  int _turn = 0;
  Transcription? _transcription;
  StreamSubscription<Heard>? _heardSub;
  Future<void> _feed = Future.value();
  int _rate = 8000;
  int _bits = 8;

  bool get _on => settings.serviceOn('assistant');

  @visibleForTesting
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case recStart:
        if (m.length > 3 && m[3] == forAssistant) {
          _listen(
            m.length > 1 && m[1] == 16 ? 16 : 8,
            m.length > 2 && m[2] > 0 ? m[2] * 1000 : 8000,
          );
        } else if (_transcription != null) {
          // the sound that follows is another app's (Translate): not to
          // be heard as a question
          _drop();
          state = AssistantState.idle;
          notifyListeners();
        }
      case audioChunk:
        _add(m.sublist(1));
      case audioEnd:
        if (_transcription == null) return;
        _add(m.sublist(1));
        _heardAll();
      case assist:
        _onAssist(m);
      case recDrop:
        // the wearer went back: nothing is asked, an answer on its way is
        // thrown away, and one being read stops
        voice?.stop();
        if (_transcription == null && state == AssistantState.idle) return;
        _drop();
        _turn++;
        state = AssistantState.idle;
        heard = '';
        glazLog(LogKind.assistant, 'dropped on the glasses');
        notifyListeners();
    }
  }

  /// The glasses' Assistant lists the chats, goes on with one, or starts
  /// a new one (`ASSIST`, docs/PROTOCOL.md, "Assistant").
  void _onAssist(List<int> m) {
    final op = m.length > 1 ? m[1] : 0;
    final id = m.length > 3 ? m[2] << 8 | m[3] : 0;
    switch (op) {
      case 1:
        link.callModule('assistant', 'c:${glassesList()}');
      case 2:
        final chat = chats.where((c) => c.id == id).firstOrNull;
        if (chat == null) {
          link.callModule('assistant', 'e:This chat is gone');
          return;
        }
        open(chat);
        link.callModule('assistant', 'a:${lastOnGlasses(chat)}');
      case 3:
        newChat();
    }
  }

  /// The chats as the glasses list them: the id of the one still going
  /// on (0: none), then a line `id|title` each, the title cut to a row.
  @visibleForTesting
  String glassesList() {
    final live = current != null && DateTime.now().difference(_lastAt) <= forget
        ? current!.id
        : 0;
    final out = StringBuffer('$live');
    for (final c in chats.take(glassesChats)) {
      var title = forGlasses(c.title).replaceAll(RegExp(r'[\s|]+'), ' ');
      if (title.length > 24) title = '${title.substring(0, 22)}..';
      out.write('\n${c.id}|$title');
    }
    return out.toString();
  }

  /// A chat's last question and answer, for the glasses' screen.
  static String lastOnGlasses(AssistantChat chat) {
    if (chat.turns.isEmpty) return 'tap = ask';
    final t = chat.turns.last;
    return wrapForGlasses('"${t.question}"\n${t.error ?? t.answer ?? '...'}');
  }

  void _listen(int bits, int rate) {
    voice?.stop(); // a new question: the last answer has been heard enough
    _drop();
    _turn++;
    if (!_on) {
      _show('e:', 'The assistant is off: Glaz > More > Services');
      return;
    }
    final t = transcriber;
    if (t == null) {
      _show('e:', 'No speech recognition on this phone');
      return;
    }
    _bits = bits;
    _rate = rate;
    heard = '';
    state = AssistantState.listening;
    if (_language != settings.assistantLanguage) prepare().ignore();
    final tr = _transcription = t.start(settings.assistantLanguage);
    // only the wearer's second tap ends the question: nothing here guesses
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

  Future<void> _heardAll() async {
    final tr = _transcription!;
    final turn = _turn;
    _transcription = null;
    await _feed;
    String text;
    try {
      await tr.finish();
      text = await tr.done;
    } on TranscriptionError catch (e) {
      glazLog(LogKind.assistant, 'recognition: ${e.message}', problem: true);
      text = e.text;
    } catch (e) {
      glazLog(LogKind.assistant, 'recognition: $e', problem: true);
      text = tr.text;
    }
    if (turn != _turn) return;
    if (text.trim().isEmpty) {
      state = AssistantState.idle;
      notifyListeners();
      _show('e:', 'Did not hear anything. Tap to ask again.');
      return;
    }
    await _ask(text.trim(), turn);
  }

  /// Asks the agent [question] as if it had been said: from the phone's
  /// screen, to try the agent without the glasses.
  /// With [chat], it goes on.
  Future<void> ask(String question, {AssistantChat? chat}) {
    _drop();
    if (chat != null) open(chat);
    return _ask(question, ++_turn);
  }

  Future<void> _ask(String question, int turn) async {
    glazLog(LogKind.assistant, 'asked: $question');
    final chat = _chatAt(DateTime.now());
    final t = AssistantTurn(question);
    chat.turns.add(t);
    heard = '';
    state = AssistantState.thinking;
    notifyListeners();
    link.callModule('assistant', 'h:${wrapForGlasses(question, maxLines: 4)}');

    final agent = _agentFor(settings);
    if (agent == null) {
      _fail(t, turn, 'Set up the agent: Glaz > Menu > Assistant');
      return;
    }

    // the agent's queries answered, until it answers the wearer
    final talk = [AgentMessage('user', question)];
    var reply = '';
    for (var round = 0; ; round++) {
      try {
        reply = await agent.ask([
          AgentMessage('system', systemPrompt(settings)),
          ...chat.history,
          ...talk,
        ]);
      } catch (e) {
        _fail(t, turn, '$e');
        return;
      }
      if (turn != _turn) return;
      final asked = [
        for (final c in splitReply(reply).$2)
          if (queries?.handles(c.name) ?? false) c,
      ];
      if (asked.isEmpty || round == maxRounds) break;
      final calls = [for (final c in asked) ToolCall(c)];
      t.queries = [...t.queries, ...calls];
      notifyListeners();
      final results = <QueryResult>[];
      for (final call in calls) {
        final r = await queries!.run(call.command);
        results.add(r);
        call.result = _brief(r);
        notifyListeners();
      }
      if (turn != _turn) return;
      talk
        ..add(AgentMessage('assistant', reply))
        ..add(
          AgentMessage(
            'user',
            [for (final r in results) r.text].join('\n\n'),
            images: [for (final r in results) ...r.images],
          ),
        );
    }
    final history = chat.history
      ..addAll([for (final m in talk) m.textOnly])
      ..add(AgentMessage('assistant', reply));
    while (history.length > 2 * keep ||
        (history.isNotEmpty && history.first.role != 'user')) {
      history.removeAt(0);
    }

    glazLog(LogKind.assistant, 'answered: $reply');
    final (text, all) = splitReply(reply);
    final commands = [
      for (final c in all)
        if (!(queries?.handles(c.name) ?? false)) c,
    ];
    t
      ..answer = text
      ..commands = commands;
    state = AssistantState.idle;
    notifyListeners();
    _save();
    final opened = await run(commands);
    if (!opened) _show('a:', text.isEmpty ? 'OK' : text);
    await _say(text);
  }

  /// [text] read aloud as well, if the user wants it and headphones are
  /// what it would come out of; said as the agent wrote it, not
  /// transliterated.
  Future<void> _say(String text) async {
    final v = voice;
    if (v == null || text.isEmpty || !settings.assistantSpeaks) return;
    final h = await v.headphones();
    if (!h.ok) {
      glazLog(LogKind.assistant, 'not read aloud: ${h.why ?? 'no headphones'}');
      return;
    }
    if (await v.speak(text, settings.assistantLanguage)) {
      glazLog(LogKind.assistant, 'read aloud in ${h.name ?? 'headphones'}');
    }
  }

  void _fail(AssistantTurn t, int turn, String why) {
    glazLog(LogKind.assistant, why, problem: true);
    if (turn != _turn) return;
    t.error = why;
    state = AssistantState.idle;
    notifyListeners();
    _save();
    _show('e:', why);
  }

  /// What the screen keeps of a query's result: its text, photos counted.
  static String _brief(QueryResult r) {
    var text = r.text.trim();
    if (text.length > ToolCall.kept) {
      text = '${text.substring(0, ToolCall.kept)}...';
    }
    final n = r.images.length;
    return n == 0 ? text : '$text (${n == 1 ? 'a photo' : '$n photos'})';
  }

  /// [text] on the glasses, in the Assistant module, put on screen for it.
  void _show(String kind, String text) =>
      link.openModule('assistant', '$kind${wrapForGlasses(text)}');

  /// Runs [commands] on the glasses; true if one put another app on
  /// screen, so the answer would not be seen there.
  @visibleForTesting
  Future<bool> run(List<GlassesCommand> commands) async {
    var opened = false;
    for (final c in commands) {
      switch (c.name) {
        case 'open':
          final m = _module(c.arg);
          if (m != null && m.id != 'assistant') {
            await link.openModule(m.id);
            opened = true;
          }
        case 'notify':
          if (c.arg.isNotEmpty) {
            await link.send(
              notify,
              NotificationService.encode('Assistant', '', c.arg),
            );
          }
        case 'set':
          _set(c.arg);
        case 'press':
          await _press(c.arg.toLowerCase());
      }
    }
    return opened;
  }

  /// An installed module, by file name or label.
  GlassesModule? _module(String name) {
    final n = name.trim().toLowerCase();
    for (final s in glassesMenu) {
      for (final m in s.modules) {
        if ((m.id == n || m.label.toLowerCase() == n) &&
            settings.installed(m.id)) {
          return m;
        }
      }
    }
    return null;
  }

  /// 'weather.city=Minsk'. Only settings the module has; a choice only to
  /// one of its options.
  void _set(String arg) {
    final m = RegExp(r'^([\w ]+)\.(\w+)\s*=\s*(.*)$').firstMatch(arg);
    if (m == null) return;
    final module = _module(m[1]!);
    if (module == null) return;
    for (final s in module.settings) {
      if (s.key != m[2]) continue;
      final value = m[3]!.trim();
      if (s.text) {
        settings.setConfig(module.id, s.key, value);
      } else {
        final option = s.options.where(
          (o) => o.toLowerCase() == value.toLowerCase(),
        );
        if (option.isNotEmpty) {
          settings.setConfig(module.id, s.key, option.first);
        }
      }
    }
  }

  Future<void> _press(String button) => switch (button) {
    'ok' => link.remoteTaps(1),
    'back' => link.remoteTaps(2),
    'menu' => link.remoteTaps(3),
    'left' || 'up' => link.remoteTilt(next: false),
    'right' || 'down' => link.remoteTilt(next: true),
    _ => Future.value(),
  };

  /// Stops listening without asking: the glasses gone, or a new question.
  void _drop() {
    _heardSub?.cancel();
    _heardSub = null;
    final tr = _transcription;
    _transcription = null;
    if (tr != null) tr.cancel().catchError((_) {});
    if (state == AssistantState.listening) {
      state = AssistantState.idle;
      heard = '';
      notifyListeners();
    }
  }
}
