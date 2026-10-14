import 'package:flutter/material.dart';

import '../catalog.dart';
import '../services/services.dart';

/// The apps (modules) on the glasses, grouped like the menu there.
/// Switching one off will remove it from the glasses on the next upload;
/// for now the switch is only remembered. An app that uses the Internet
/// also gets a permission switch, off until the user turns it on.
class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final all = [for (final s in sections) ...s.apps];
        final count = all.where((a) => settings.installed(a.id)).length;

        return Scaffold(
          appBar: AppBar(title: const Text('Apps')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$count of ${all.length} on the glasses',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final section in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Text(
                    section.label,
                    style: text.titleSmall?.copyWith(color: scheme.primary),
                  ),
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final app in section.apps) ...[
                        SwitchListTile(
                          title: Text(app.label),
                          subtitle: Text(app.description),
                          value: settings.installed(app.id),
                          onChanged: (v) => settings.setInstalled(app.id, v),
                        ),
                        if (app.network)
                          CheckboxListTile(
                            dense: true,
                            secondary: Icon(
                              Icons.public,
                              color: settings.netAllowed(app.id)
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            title: const Text('Allow Internet access'),
                            value: settings.netAllowed(app.id),
                            onChanged: (v) =>
                                settings.setNetAllowed(app.id, v ?? false),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
