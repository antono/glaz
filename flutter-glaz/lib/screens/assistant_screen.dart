import 'package:flutter/material.dart';

import '../services/assistant.dart';
import '../services/photos.dart';
import '../services/speech.dart';
import '../services/voice.dart';
import '../services/services.dart';
import '../theme.dart';
import 'assistant_chat_screen.dart';

/// The agent the glasses' Assistant asks, the language it hears, and the
/// chats with it: on Assistant's page in the Menu tab, under its
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
    super.dispose();
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
          _Chats(_assistant),
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

/// The chats kept on the phone, the one asked last first: a tap goes on
/// with one, from the phone and from the glasses.
class _Chats extends StatelessWidget {
  const _Chats(this.assistant);
  final AssistantService assistant;

  void _open(BuildContext context, AssistantChat? chat) {
    if (chat == null) {
      assistant.newChat();
    } else {
      assistant.open(chat);
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => AssistantChatScreen(chat)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Text('Chats', style: text.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'The glasses ask in the chat picked here, or in a new one after '
            '${AssistantService.forget.inMinutes} minutes of silence.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('New chat'),
                subtitle: const Text('Ask in writing, as if said aloud'),
                onTap: () => _open(context, null),
              ),
              for (final c in assistant.chats)
                ListTile(
                  leading: Icon(
                    c == assistant.current
                        ? Icons.chat_bubble
                        : Icons.chat_bubble_outline,
                    color: FrameColors.skyBlue,
                  ),
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${stampLabel(c.lastAt)} · ${c.turns.length} '
                    '${c.turns.length == 1 ? 'question' : 'questions'}'
                    '${c == assistant.current ? ' · current' : ''}',
                  ),
                  onTap: () => _open(context, c),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
