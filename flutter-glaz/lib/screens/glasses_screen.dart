import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../frame/link.dart';
import '../frame/upload.dart';
import '../services/services.dart';

/// The glasses themselves: connection, battery, firmware, and the main.lua
/// on them (Upload, Restart).
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
          Row(
            children: [
              Expanded(
                child: _Stat(
                  _batteryIcon(link.battery),
                  'Battery',
                  link.battery == null ? '--' : '${link.battery}%',
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _Stat(Icons.memory, 'Firmware', link.firmware ?? '--'),
              ),
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
                if (link.busy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${link.task}: ${link.taskStep}'),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: link.taskProgress),
                      ],
                    ),
                  )
                else ...[
                  if (link.taskError != null)
                    ListTile(
                      leading: Icon(Icons.error_outline, color: scheme.error),
                      title: const Text('Last attempt failed'),
                      subtitle: Text(link.taskError!),
                    ),
                  ListTile(
                    enabled: link.connected,
                    leading: const Icon(Icons.upload),
                    title: const Text('Upload'),
                    subtitle: const Text(
                      'main.lua and the apps switched on in Apps',
                    ),
                    onTap: () => _upload(context, link),
                  ),
                  ListTile(
                    enabled: link.connected,
                    leading: const Icon(Icons.restart_alt),
                    title: const Text('Restart'),
                    subtitle: const Text('Start the app on the glasses again'),
                    onTap: () => link.runTask('Restart', restartApp),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _batteryIcon(int? level) => switch (level) {
  null => Icons.battery_unknown,
  <= 15 => Icons.battery_alert,
  <= 50 => Icons.battery_3_bar,
  <= 85 => Icons.battery_5_bar,
  _ => Icons.battery_full,
};

Future<void> _upload(BuildContext context, FrameLink link) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Upload to the glasses?'),
      content: const Text(
        'The app on the glasses stops, the glasses restart, and main.lua '
        'with the apps switched on in Apps is written to them. Takes a '
        'minute or two; keep the glasses close.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Upload'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final settings = Services.instance.settings;
  final files = await luaFiles(rootBundle, settings.installed);
  await link.runTask(
    'Upload',
    (device, report) => uploadApp(device, files, report),
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
