import 'package:flutter/material.dart';

import '../services/assistant.dart';
import '../services/services.dart';
import '../theme.dart';

/// The agent the glasses' Assistant asks, and what it was asked lately.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _settings = Services.instance.settings;
  final _assistant = Services.instance.assistant;
  late final _url = TextEditingController(text: _settings.agentUrl);
  late final _key = TextEditingController(text: _settings.agentKey);
  late final _model = TextEditingController(text: _settings.agentModel);
  final _question = TextEditingController();
  bool _showKey = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _question.dispose();
    super.dispose();
  }

  void _ask() {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    _question.clear();
    _assistant.ask(q);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _assistant,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              'Open Assistant on the glasses and ask aloud: the phone '
              'transcribes it and asks your agent. Any server that speaks '
              'the OpenAI chat API will do; for Hermes Agent, its API '
              'server (hermes gateway) on your tailnet.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server',
                      hintText: 'https://hermes.tail1234.ts.net',
                      helperText: 'With tailscale serve, or http://...:8642',
                    ),
                    onChanged: (v) => _settings.agentUrl = v,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    obscureText: !_showKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Key',
                      helperText: "Hermes: API_SERVER_KEY in the server's .env",
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showKey ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ),
                    onChanged: (v) => _settings.agentKey = v,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _model,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      helperText: 'Hermes: hermes-agent',
                    ),
                    onChanged: (v) => _settings.agentModel = v,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListenableBuilder(
              listenable: _settings,
              builder: (context, _) => SwitchListTile(
                secondary: const Icon(
                  Icons.photo_library_outlined,
                  color: FrameColors.skyBlue,
                ),
                title: const Text('Photos and recordings'),
                subtitle: const Text(
                  "The agent may see Glaz's photos, read the recordings' "
                  'transcripts and take a photo with the glasses.',
                ),
                value: _settings.agentFiles,
                onChanged: (on) => _settings.agentFiles = on,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _question,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _ask(),
            decoration: InputDecoration(
              labelText: 'Ask in writing',
              helperText: 'As if said aloud; the answer goes to the glasses',
              suffixIcon: IconButton(
                icon: const Icon(Icons.send),
                onPressed: _ask,
              ),
            ),
          ),
          if (_assistant.state != AssistantState.idle)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _assistant.state == AssistantState.listening
                          ? 'Listening: ${_assistant.heard}'
                          : 'Thinking...',
                    ),
                  ),
                ],
              ),
            ),
          if (_assistant.turns.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
              child: Text(
                'Lately',
                style: text.titleSmall?.copyWith(color: scheme.primary),
              ),
            ),
            for (final t in _assistant.turns) _Turn(t),
          ],
        ],
      ),
    );
  }
}

class _Turn extends StatelessWidget {
  const _Turn(this.turn);
  final AssistantTurn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              turn.question,
              style: const TextStyle(color: FrameColors.skyBlue),
            ),
            for (final q in turn.queries)
              Text(
                'asked $q',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 6),
            if (turn.error != null)
              Text(turn.error!, style: TextStyle(color: scheme.error))
            else if (turn.answer == null)
              const Text('...')
            else ...[
              if (turn.answer!.isNotEmpty) Text(turn.answer!),
              for (final c in turn.commands)
                Text(
                  '$c',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
