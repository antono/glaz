import 'package:flutter/material.dart';

import '../services/services.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              'Theme',
              style: text.titleSmall?.copyWith(color: scheme.primary),
            ),
          ),
          ListenableBuilder(
            listenable: Services.instance.settings,
            builder: (context, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode),
                  label: Text('Dark'),
                ),
              ],
              selected: {Services.instance.settings.themeMode},
              onSelectionChanged: (s) =>
                  Services.instance.settings.themeMode = s.first,
            ),
          ),
          const SizedBox(height: 24),
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Glaz'),
              subtitle: Text('Companion app for the Frame glasses'),
            ),
          ),
        ],
      ),
    );
  }
}
