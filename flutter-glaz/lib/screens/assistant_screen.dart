import 'package:flutter/material.dart';

import '../services/assistant.dart';
import '../services/speech.dart';
import '../services/voice.dart';
import '../services/services.dart';
import '../theme.dart';

/// The agent the glasses' Assistant asks, the language it hears, and what
/// it was asked lately: on Assistant's page in the Menu tab, under its
/// settings for the glasses. Phone only: none of it goes to the glasses.
class AssistantSettings extends StatefulWidget {
  const AssistantSettings({super.key});

  @override
  State<AssistantSettings> createState() => _AssistantSettingsState();
}

class _AssistantSettingsState extends State<AssistantSettings> {
  final _settings = Services.instance.settings;
  final _assistant = Services.instance.assistant;
  late final _url = TextEditingController(text: _settings.agentUrl);
  late final _key = TextEditingController(text: _settings.agentKey);
  late final _model = TextEditingController(text: _settings.agentModel);
  final _question = TextEditingController();
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _assistant.prepare().ignore();
  }

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
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
            child: Text('Agent', style: text.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              'The phone transcribes what you ask and asks your agent: any '
              'server that speaks the OpenAI chat API; for Hermes Agent, '
              'its API server (hermes gateway) on your tailnet. Kept on the '
              'phone, never sent to the glasses.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
          _Language(_assistant),
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
          _ReadAloud(_assistant),
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

/// Whether answers are read aloud too, and where they would go now: only
/// headphones will do.
class _ReadAloud extends StatefulWidget {
  const _ReadAloud(this.assistant);
  final AssistantService assistant;

  @override
  State<_ReadAloud> createState() => _ReadAloudState();
}

class _ReadAloudState extends State<_ReadAloud> {
  late Future<Headphones>? _now = widget.assistant.voice?.headphones();

  void _check() => setState(() => _now = widget.assistant.voice?.headphones());

  @override
  Widget build(BuildContext context) {
    final settings = widget.assistant.settings;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Column(
          children: [
            SwitchListTile(
              secondary: const Icon(
                Icons.headphones,
                color: FrameColors.skyBlue,
              ),
              title: const Text('Read answers aloud'),
              subtitle: const Text(
                'In headphones only -- never the phone\'s speaker or a '
                'Bluetooth speaker. Off: on the glasses\' screen only.',
              ),
              value: settings.assistantSpeaks,
              onChanged: (on) {
                settings.assistantSpeaks = on;
                _check();
              },
            ),
            if (settings.assistantSpeaks && _now != null)
              FutureBuilder<Headphones>(
                future: _now,
                builder: (context, snap) {
                  final h = snap.data;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      h == null
                          ? Icons.hourglass_empty
                          : h.ok
                          ? Icons.check_circle_outline
                          : Icons.volume_off,
                      color: h?.ok == true ? scheme.primary : scheme.outline,
                    ),
                    title: Text(
                      h == null
                          ? 'Checking...'
                          : h.ok
                          ? 'Now: ${h.name ?? 'headphones'}'
                          : 'Now silent: ${h.why ?? 'no headphones'}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _check,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// The language questions are heard in, and whether it is on the phone.
class _Language extends StatelessWidget {
  const _Language(this.assistant);
  final AssistantService assistant;

  @override
  Widget build(BuildContext context) {
    final settings = assistant.settings;
    final scheme = Theme.of(context).colorScheme;
    final down = assistant.downloading;
    final status = assistant.transcriber == null
        ? 'No speech recognition on this phone'
        : assistant.modelError != null
        ? 'Could not get the language: ${assistant.modelError}'
        : down != null
        ? 'Downloading the language: ${(down * 100).round()}%'
        : switch (assistant.model) {
            SpeechModel.available => 'Ready, on the phone',
            SpeechModel.unavailable => 'This phone cannot recognize it',
            SpeechModel.downloadable ||
            SpeechModel.downloading => 'Waiting to download',
            null => 'Checking...',
          };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: settings.assistantLanguage,
              decoration: const InputDecoration(
                labelText: 'Language you ask in',
              ),
              items: [
                for (final (tag, name) in speechLanguages)
                  DropdownMenuItem(value: tag, child: Text(name)),
              ],
              onChanged: (v) {
                if (v != null) settings.assistantLanguage = v;
              },
            ),
            const SizedBox(height: 8),
            if (down != null) LinearProgressIndicator(value: down),
            SelectableText(
              status,
              style: TextStyle(
                color: assistant.modelError != null
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
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
              // selectable: an error is what one copies to ask about it
              SelectableText(turn.error!, style: TextStyle(color: scheme.error))
            else if (turn.answer == null)
              const Text('...')
            else ...[
              if (turn.answer!.isNotEmpty) SelectableText(turn.answer!),
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
