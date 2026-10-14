import 'package:flutter/material.dart';

import '../frame/link.dart';
import '../services/services.dart';

/// The glasses themselves: connection, battery, and the main.lua on them.
/// The connection is real; battery, firmware and upload are not wired yet.
class GlassesScreen extends StatelessWidget {
  const GlassesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context, link),
    );
  }

  static String _status(FrameLink link) => switch (link.state) {
    LinkState.connected => 'Connected',
    LinkState.connecting => 'Connecting...',
    LinkState.scanning => 'Looking for the glasses...',
    LinkState.disconnected =>
      link.error == null ? 'Not connected' : 'Failed: ${link.error}',
  };

  Widget _build(BuildContext context, FrameLink link) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Glaz')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        child: const Icon(Icons.visibility, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(link.name ?? 'Frame', style: text.titleLarge),
                            Text(
                              _status(link),
                              style: text.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: link.state == LinkState.disconnected
                        ? FilledButton.icon(
                            onPressed: link.connect,
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('Connect'),
                          )
                        : OutlinedButton.icon(
                            onPressed: link.disconnect,
                            icon: const Icon(Icons.bluetooth_disabled),
                            label: Text(
                              link.connected ? 'Disconnect' : 'Cancel',
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              Expanded(child: _Stat(Icons.battery_unknown, 'Battery', '--')),
              SizedBox(width: 16),
              Expanded(child: _Stat(Icons.memory, 'Firmware', '--')),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.description_outlined),
                  title: Text('main.lua'),
                  subtitle: Text('The menu app that runs on the glasses'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.upload),
                  title: const Text('Upload'),
                  subtitle: const Text('main.lua and the installed apps'),
                  onTap: () => _notYet(context),
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('Restart'),
                  onTap: () => _notYet(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _notYet(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text('Not wired to the glasses yet')),
    );
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(height: 12),
            Text(value, style: text.headlineSmall),
            Text(
              label,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
