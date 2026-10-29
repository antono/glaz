import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/screens/agent_screen.dart';
import 'package:glaz/services/agent.dart';
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

  test('a service of its own, on by default, before its apps', () {
    final ids = [for (final s in services) s.id];
    expect(ids, contains('agent'));
    expect(ids.indexOf('agent'), lessThan(ids.indexOf('assistant')));
    expect(ids.indexOf('agent'), lessThan(ids.indexOf('factcheck')));
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

  test("the apps' pages say which agent, or why none", () {
    expect(AgentLink.state(false, 'https://h.ts.net'), startsWith('Off'));
    expect(AgentLink.state(true, ''), 'Not set up yet');
    expect(
      AgentLink.state(true, 'https://hermes.tail1234.ts.net/v1'),
      'hermes.tail1234.ts.net',
    );
  });
}
