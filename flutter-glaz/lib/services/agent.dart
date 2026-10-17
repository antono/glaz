import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One message of a conversation, as chat APIs take them.
class AgentMessage {
  const AgentMessage(this.role, this.content, {this.images = const []});
  final String role; // 'system', 'user' or 'assistant'
  final String content;

  /// JPEGs that go with a user message.
  final List<Uint8List> images;

  /// Without its pictures: what the conversation keeps of it.
  AgentMessage get textOnly => images.isEmpty
      ? this
      : AgentMessage(role, '$content\n(${images.length} photo(s) were here)');

  Map<String, Object> toJson() => {
    'role': role,
    'content': images.isEmpty
        ? content
        : [
            {'type': 'text', 'text': content},
            for (final jpeg in images)
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64.encode(jpeg)}',
                },
              },
          ],
  };
}

/// The agent did not answer; [message] says why, for the glasses.
class AgentError implements Exception {
  AgentError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What the assistant asks: anything that takes a conversation and answers
/// it with text.
abstract class Agent {
  Future<String> ask(List<AgentMessage> messages);
}

/// An OpenAI-compatible chat completions endpoint: Hermes Agent's API
/// server (`hermes gateway`, model 'hermes-agent'), or any other. Hermes
/// runs its own tools on its own host; what the glasses can do comes back
/// as commands in the text (services/assistant.dart).
class ChatCompletionsAgent implements Agent {
  ChatCompletionsAgent({
    required this.url,
    required this.key,
    required this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// The server's address, with or without the trailing /v1:
  /// https://hermes.tail1234.ts.net or http://hermes.tail1234.ts.net:8642.
  final String url;
  final String key;
  final String model;
  final http.Client _client;

  /// An agent may run tools before it answers.
  static const timeout = Duration(seconds: 120);

  /// Where the requests go, from [url].
  static Uri endpoint(String url) {
    var base = url.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.endsWith('/v1')) base = '$base/v1';
    return Uri.parse('$base/chat/completions');
  }

  @override
  Future<String> ask(List<AgentMessage> messages) async {
    final http.Response r;
    try {
      r = await _client
          .post(
            endpoint(url),
            headers: {
              'Content-Type': 'application/json',
              if (key.isNotEmpty) 'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'messages': [for (final m in messages) m.toJson()],
            }),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw AgentError('no answer in ${timeout.inSeconds} s');
    } catch (e) {
      throw AgentError('cannot reach the agent: $e');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw AgentError('the agent refused the key (${r.statusCode})');
    }
    if (r.isRedirect || (r.statusCode >= 300 && r.statusCode < 400)) {
      // a POST is not sent on to another address; the user fixes the one
      // they gave: http:// for an https:// server, say
      final to = r.headers['location'];
      throw AgentError(
        'the server sends elsewhere (${r.statusCode})'
        '${to == null ? '' : ': $to'}; put that in Server',
      );
    }
    if (r.statusCode != 200) throw AgentError('agent error ${r.statusCode}');
    try {
      final json = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final message = (json['choices'] as List).first['message'] as Map;
      return (message['content'] as String? ?? '').trim();
    } catch (_) {
      throw AgentError('the agent answered something else');
    }
  }
}
