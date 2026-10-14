import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../frame/dfu.dart';
import '../frame/firmware.dart';
import '../frame/link.dart';
import '../services/services.dart';

/// Pick a firmware package and install it over Bluetooth. The packages are
/// the DFU zips in assets/firmware/: the newest official releases and our
/// own builds (tool/fetch_firmware.sh).
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key});

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  late final Future<List<FirmwarePackage>> _packages = firmwarePackages(
    rootBundle,
  );
  FirmwarePackage? _picked;

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    return Scaffold(
      appBar: AppBar(title: const Text('Firmware')),
      body: ListenableBuilder(
        listenable: link,
        builder: (context, _) => FutureBuilder(
          future: _packages,
          builder: (context, snap) {
            final packages = snap.data;
            if (packages == null) return const SizedBox.shrink();
            return _body(context, link, packages);
          },
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    FrameLink link,
    List<FirmwarePackage> packages,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final installed = link.firmware;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: Text(installed ?? 'Unknown'),
            subtitle: Text(
              link.connected ? 'On the glasses now' : 'Connect to read it',
            ),
          ),
        ),
        if (link.task == 'Firmware') ...[
          const SizedBox(height: 16),
          Text(link.taskStep),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: link.taskProgress),
          const SizedBox(height: 8),
          Text(
            'Keep the glasses close and this screen open.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ] else if (link.taskError != null) ...[
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: Icon(Icons.error_outline, color: scheme.error),
              title: const Text('Last attempt failed'),
              subtitle: Text(
                '${link.taskError}\n\nThe glasses leave update mode by '
                'themselves within 3 minutes; installing an official '
                'version undoes a bad build.',
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text(
            'Available',
            style: text.titleSmall?.copyWith(color: scheme.primary),
          ),
        ),
        if (packages.isEmpty)
          const Text('None. Run tool/fetch_firmware.sh and rebuild the app.'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: RadioGroup<FirmwarePackage>(
            groupValue: _picked,
            onChanged: link.busy ? (_) {} : (p) => setState(() => _picked = p),
            child: Column(
              children: [
                for (final p in packages)
                  RadioListTile<FirmwarePackage>(
                    value: p,
                    enabled: !link.busy,
                    title: Text(p.version),
                    subtitle: Text(
                      [
                        p.official ? 'Official release' : 'Custom build',
                        if (p.version == installed) 'installed',
                      ].join(' - '),
                    ),
                    secondary: p.official
                        ? null
                        : Icon(Icons.construction, color: scheme.tertiary),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _picked == null || !link.connected || link.busy
              ? null
              : () => _install(context, link, _picked!),
          icon: const Icon(Icons.system_update_alt),
          label: Text(
            _picked == null ? 'Pick a version' : 'Install ${_picked!.version}',
          ),
        ),
      ],
    );
  }

  Future<void> _install(
    BuildContext context,
    FrameLink link,
    FirmwarePackage package,
  ) async {
    final low = (link.battery ?? 100) < 30;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${package.version}?'),
        content: Text(
          'The glasses restart into update mode, take the new firmware '
          '(a minute or two), and restart again. Your apps on them should '
          'stay; if the menu does not come back, Upload again.'
          '${package.official ? '' : '\n\nThis is a custom build.'}'
          '${low ? '\n\nThe battery is at ${link.battery}%: charge first.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await link.runTask(
      'Firmware',
      (device, report) => installFirmware(device, package, report),
    );
  }
}
