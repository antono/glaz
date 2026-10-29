import 'package:flutter/material.dart';

import '../services/services.dart';
import '../theme.dart';

/// The AI agent's settings: its server, key and model. In Glaz > More >
/// Services under the AI agent's switch, and on a page of its own from
/// Assistant's and Factchecker's pages. Phone only: none of it goes to
/// the glasses.
class AgentSettings extends StatefulWidget {
  const AgentSettings({super.key});

  @override
  State<AgentSettings> createState() => _AgentSettingsState();
}

class _AgentSettingsState extends State<AgentSettings> {
  final _settings = Services.instance.settings;
  late final _url = TextEditingController(text: _settings.agentUrl);
  late final _key = TextEditingController(text: _settings.agentKey);
  late final _model = TextEditingController(text: _settings.agentModel);
  bool _showKey = false;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text('AI agent', style: text.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'Assistant and Factchecker ask it: any server that speaks the '
            'OpenAI chat API; for Hermes Agent, its API server (hermes '
            'gateway) on your tailnet. Kept on the phone, never sent to '
            'the glasses.',
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
      ],
    );
  }
}

/// The AI agent's settings on a page of their own.
class AgentScreen extends StatelessWidget {
  const AgentScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI agent')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: const [AgentSettings()],
    ),
  );
}

/// The agent an app asks, in a row: its server, or why there is none; a
/// tap opens its settings. On Assistant's and Factchecker's pages.
class AgentLink extends StatelessWidget {
  const AgentLink({super.key});

  /// What the row says of the agent now.
  static String state(bool on, String url) {
    if (!on) return 'Off: Glaz > More > Services';
    if (url.isEmpty) return 'Not set up yet';
    return Uri.tryParse(url)?.host.isNotEmpty == true
        ? Uri.parse(url).host
        : url;
  }

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListTile(
          leading: const Icon(Icons.hub_outlined, color: FrameColors.skyBlue),
          title: const Text('AI agent'),
          subtitle: Text(state(settings.serviceOn('agent'), settings.agentUrl)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const AgentScreen())),
        ),
      ),
    );
  }
}
