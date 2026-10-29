import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/factcheck.dart';
import '../services/photos.dart';
import '../services/services.dart';
import '../theme.dart';
import 'agent_screen.dart';

/// A verdict's colour, as on the glasses.
Color verdictColor(Verdict v) => switch (v) {
  Verdict.checking => FrameColors.white,
  Verdict.right => FrameColors.lightGreen,
  Verdict.wrong => FrameColors.red,
  Verdict.partly => FrameColors.yellow,
  Verdict.unknown => FrameColors.grey,
};

IconData _verdictIcon(Verdict v) => switch (v) {
  Verdict.checking => Icons.hourglass_empty,
  Verdict.right => Icons.check_circle,
  Verdict.wrong => Icons.cancel,
  Verdict.partly => Icons.adjust,
  Verdict.unknown => Icons.help_outline,
};

/// The agent it asks, and the way in to the checks kept on the phone: on
/// Factchecker's page in the Menu tab, under its settings for the glasses.
class FactChecks extends StatelessWidget {
  const FactChecks({super.key});

  @override
  Widget build(BuildContext context) {
    final factcheck = Services.instance.factcheck;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const AgentLink(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text('Checks', style: text.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'The AI agent pulls the claims out of what was said and checks '
            "each on the web; speech is heard in the Assistant's language.",
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(
            listenable: factcheck,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.fact_check, color: FrameColors.skyBlue),
              title: const Text('Checks'),
              subtitle: Text(
                factcheck.sessions.isEmpty
                    ? 'None yet'
                    : '${factcheck.sessions.length} kept, the newest '
                          '${stampLabel(factcheck.sessions.first.at)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const FactCheckScreen(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sessions of Factchecker, newest first.
class FactCheckScreen extends StatelessWidget {
  const FactCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final factcheck = Services.instance.factcheck;
    return Scaffold(
      appBar: AppBar(title: const Text('Factchecker')),
      body: ListenableBuilder(
        listenable: factcheck,
        builder: (context, _) {
          if (factcheck.sessions.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nothing checked yet. Open Factchecker on the glasses and '
                  'tap when something worth checking was said.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final s in factcheck.sessions)
                ListTile(
                  leading: Icon(
                    s == factcheck.current && factcheck.listening
                        ? Icons.hearing
                        : Icons.fact_check_outlined,
                    color: FrameColors.skyBlue,
                  ),
                  title: Text(stampLabel(s.at)),
                  subtitle: Text(_counts(s)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => FactSessionScreen(s),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _counts(FactSession s) {
    if (s.facts.isEmpty) return 'No facts';
    final by = <Verdict, int>{};
    for (final f in s.facts) {
      by[f.verdict] = (by[f.verdict] ?? 0) + 1;
    }
    return [
      for (final v in Verdict.values)
        if (by[v] != null) '${by[v]} ${v.label.toLowerCase()}',
    ].join(' · ');
  }
}

/// One session: its facts, coloured by verdict, and what was said.
class FactSessionScreen extends StatelessWidget {
  const FactSessionScreen(this.session, {super.key});
  final FactSession session;

  Future<void> _delete(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this fact check?'),
        content: Text(stampLabel(session.at)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    Services.instance.factcheck.remove(session);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final factcheck = Services.instance.factcheck;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(stampLabel(session.at)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () => _delete(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: factcheck,
        builder: (context, _) => ListView(
          children: [
            if (session.facts.isEmpty)
              const ListTile(title: Text('No facts in what was said')),
            for (final f in session.facts.reversed)
              ListTile(
                leading: Icon(
                  _verdictIcon(f.verdict),
                  color: verdictColor(f.verdict),
                ),
                title: Text(
                  f.claim,
                  style: TextStyle(color: verdictColor(f.verdict)),
                ),
                subtitle: Text(f.verdict.label),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => FactScreen(f))),
              ),
            if (session.segments.isNotEmpty)
              ExpansionTile(
                leading: const Icon(Icons.notes),
                title: const Text('What was said'),
                children: [
                  for (final s in session.segments)
                    ListTile(
                      title: SelectableText(s.text),
                      subtitle: Text(stampLabel(s.at), style: text.bodySmall),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// One fact: its verdict, what the check found and where.
class FactScreen extends StatelessWidget {
  const FactScreen(this.fact, {super.key});
  final Fact fact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(fact.verdict.label)),
      body: ListenableBuilder(
        listenable: Services.instance.factcheck,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Icon(
                  _verdictIcon(fact.verdict),
                  color: verdictColor(fact.verdict),
                ),
                const SizedBox(width: 8),
                Text(
                  fact.verdict.label,
                  style: text.titleMedium?.copyWith(
                    color: verdictColor(fact.verdict),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(fact.claim, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(stampLabel(fact.at), style: text.bodySmall),
            if (fact.summary.isNotEmpty) ...[
              const SizedBox(height: 16),
              SelectableText(fact.summary),
            ],
            if (fact.sources.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Sources', style: text.titleSmall),
              for (final url in fact.sources)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link, color: FrameColors.seaBlue),
                  title: SelectableText(url),
                  subtitle: Text(FactCheckService.site(url)),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
