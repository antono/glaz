import 'package:flutter/material.dart';

import '../services/agent_history.dart';
import '../services/photos.dart';
import '../services/services.dart';
import '../theme.dart';

/// The AI agent's settings: its server, key and model. On its page
/// ([AgentScreen]), from Glaz > More > Services and from Assistant's and
/// Factchecker's pages. Phone only: none of it goes to the glasses.
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

/// The AI agent's page: its settings, then what it was asked.
class AgentScreen extends StatelessWidget {
  const AgentScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI agent')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [const AgentSettings(), AgentRequests(AgentHistory.instance)],
    ),
  );
}

/// What the AI agent was asked, newest first: who asked, when, how long it
/// took, and the start of the answer or what went wrong; a tap shows all
/// that is kept of it.
class AgentRequests extends StatelessWidget {
  const AgentRequests(this.history, {super.key});
  final AgentHistory history;

  static String took(AgentCall c) {
    final t = c.took;
    if (t == null) return 'waiting..';
    return t.inSeconds >= 1 ? '${t.inSeconds} s' : '${t.inMilliseconds} ms';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 0, 8),
            child: Row(
              children: [
                Expanded(child: Text('Requests', style: text.titleMedium)),
                if (history.calls.isNotEmpty)
                  TextButton(
                    onPressed: history.clear,
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
          if (history.calls.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: Text(
                'Nothing asked yet. Assistant and Factchecker requests are '
                'listed here, the newest ${AgentHistory.kept}.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final c in history.calls)
                    ListTile(
                      leading: Icon(
                        !c.done
                            ? Icons.hourglass_empty
                            : c.error == null
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color: c.done && c.error != null
                            ? scheme.error
                            : scheme.primary,
                      ),
                      title: Text(
                        '${c.who.isEmpty ? 'Agent' : c.who} · '
                        '${stampLabel(c.at)} · ${took(c)}',
                      ),
                      subtitle: Text(
                        '${c.asked}\n'
                        '${c.error ?? c.answer ?? ''}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _show(context, c),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _show(BuildContext context, AgentCall c) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${c.who.isEmpty ? 'Agent' : c.who} · ${took(c)}'),
      content: SingleChildScrollView(
        child: SelectableText(
          'Asked:\n${c.asked}\n\n'
          '${c.error != null ? 'Went wrong:\n${c.error}' : 'Answered:\n${c.answer ?? '..'}'}',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
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
