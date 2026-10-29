import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/screens/agent_screen.dart';
import 'package:glaz/services/agent.dart';
import 'package:glaz/services/agent_history.dart';
import 'package:glaz/services/service_list.dart';
import 'package:glaz/settings.dart';

/// The AI agent service: one agent, set in Glaz > More > Services, which
/// Assistant and Factchecker both ask.
void main() {
  late Settings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
  });

  test('one service for both apps, on by default', () {
    final ids = [for (final s in services) s.id];
    expect(ids, contains('agent'));
    // Assistant and Factchecker have no switches of their own
    expect(ids, isNot(contains('assistant')));
    expect(ids, isNot(contains('factcheck')));
    expect(settings.serviceOn('agent'), isTrue);
  });

  test('no server: no agent, and the glasses are told where to set one', () {
    expect(agentFrom(settings), isNull);
    expect(noAgent(settings), 'Set up the AI agent: Glaz > More > Services');
  });

  test('set up: the agent at that server, with that key and model', () {
    settings
      ..agentUrl = 'https://hermes.tail1234.ts.net'
      ..agentKey = 'k137'
      ..agentModel = 'hermes-agent';
    final agent = agentFrom(settings);
    expect(agent, isA<ChatCompletionsAgent>());
    agent as ChatCompletionsAgent;
    expect(agent.url, 'https://hermes.tail1234.ts.net');
    expect(agent.key, 'k137');
    expect(agent.model, 'hermes-agent');
  });

  test('switched off: no agent, though it is set up', () {
    settings
      ..agentUrl = 'https://hermes.tail1234.ts.net'
      ..setService('agent', false);
    expect(agentFrom(settings), isNull);
    expect(noAgent(settings), 'The AI agent is off: Glaz > More > Services');
  });

  group('history', () {
    ChatCompletionsAgent agent(AgentHistory h, http.Client client) =>
        ChatCompletionsAgent(
          url: 'https://hermes.tail1234.ts.net',
          key: 'k',
          model: 'hermes-agent',
          who: 'Factchecker',
          history: h,
          client: client,
        );

    final answers = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Minsk has a metro: 137 stations? No.'},
            },
          ],
        }),
        200,
      ),
    );

    test('each request: who, what, the answer, how long', () async {
      final h = AgentHistory();
      await agent(h, answers).ask([
        const AgentMessage('system', 'prompt'),
        const AgentMessage('user', 'В Минске нет метро'),
      ]);
      final c = h.calls.single;
      expect(c.who, 'Factchecker');
      expect(c.asked, 'В Минске нет метро');
      expect(c.answer, startsWith('Minsk has a metro'));
      expect(c.error, isNull);
      expect(c.done, isTrue);
    });

    test('what went wrong is kept too', () async {
      final h = AgentHistory();
      final refused = MockClient((_) async => http.Response('', 401));
      await expectLater(
        agent(h, refused).ask([const AgentMessage('user', 'q')]),
        throwsA(isA<AgentError>()),
      );
      expect(h.calls.single.error, 'the agent refused the key (401)');
    });

    test('newest first, the newest 50, long text cut', () async {
      final h = AgentHistory();
      for (var i = 0; i < 55; i++) {
        h.end(h.start('Assistant', 'q$i ${'x' * 400}'), answer: 'a');
      }
      expect(h.calls, hasLength(AgentHistory.kept));
      expect(h.calls.first.asked, startsWith('q54'));
      expect(h.calls.first.asked.length, AgentHistory.textMax);
    });

    test(
      'kept on the phone; one waited for when the app went is ended',
      () async {
        final dir = Directory.systemTemp.createTempSync('glaz_agent');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/agent_history.json');
        final h = AgentHistory();
        await h.attach(file);
        h.end(h.start('Assistant', 'one'), answer: 'yes');
        h.start('Factchecker', 'two'); // never answered
        await h.saved;

        final again = AgentHistory();
        await again.attach(file);
        expect([for (final c in again.calls) c.asked], ['two', 'one']);
        expect(again.calls.last.answer, 'yes');
        expect(again.calls.first.error, 'the app stopped meanwhile');
      },
    );
  });

  test("the apps' pages say which agent, or why none", () {
    expect(AgentLink.state(false, 'https://h.ts.net'), startsWith('Off'));
    expect(AgentLink.state(true, ''), 'Not set up yet');
    expect(
      AgentLink.state(true, 'https://hermes.tail1234.ts.net/v1'),
      'hermes.tail1234.ts.net',
    );
  });
}
