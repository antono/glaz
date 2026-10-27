import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../frame/dfu.dart';
import '../frame/firmware.dart';
import '../frame/link.dart';
import '../frame/model.dart';
import '../frame/upload.dart';
import '../services/services.dart';

/// Pick a firmware package and install it over Bluetooth. The packages are
/// the DFU zips in assets/firmware/: the newest official releases and our
/// own builds (tool/fetch_firmware.sh). Only those for the glasses at hand
/// -- connected, or of last time -- are offered: Frame's never to a Halo,
/// nor the other way round.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key});

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  // by the glasses they are for, read once each
  final _packages = <GlassesModel, Future<List<FirmwarePackage>>>{};
  FirmwarePackage? _armed; // the version whose Install is open

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    return Scaffold(
      appBar: AppBar(title: const Text('Firmware')),
      body: ListenableBuilder(
        listenable: link,
        builder: (context, _) {
          final model = link.model;
          return FutureBuilder(
            future: _packages[model] ??= firmwarePackages(rootBundle, model),
            builder: (context, snap) {
              final packages = snap.data;
              if (packages == null) return const SizedBox.shrink();
              return _body(context, link, model, packages);
            },
          );
        },
      ),
    );
  }

  Widget _body(
    BuildContext context,
    FrameLink link,
    GlassesModel model,
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
            'Available for ${model.label}',
            style: text.titleSmall?.copyWith(color: scheme.primary),
          ),
        ),
        if (packages.isEmpty)
          Text(
            model == GlassesModel.frame
                ? 'None. Run tool/fetch_firmware.sh and rebuild the app.'
                : 'None: ${model.label} takes its updates over MCUmgr, '
                      'which this app does not do yet (docs/HALO.md).',
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final p in packages)
                  _version(context, link, p, installed: p.version == installed),
              ],
            ),
          ),
      ],
    );
  }

  /// One version: a small install button on it; a tap opens the big
  /// "Install firmware" under it, with what that does, and a tap on that
  /// installs. Two taps, so one by mistake does nothing.
  Widget _version(
    BuildContext context,
    FrameLink link,
    FirmwarePackage p, {
    required bool installed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // only onto the glasses it is for, connected
    final ready = link.connected && !link.busy && link.model == p.model;
    final open = _armed == p && ready;
    final low = (link.battery ?? 100) < 30;
    void toggle() => setState(() => _armed = open ? null : p);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            enabled: ready,
            onTap: toggle,
            leading: p.official
                ? const Icon(Icons.verified_outlined)
                : Icon(Icons.construction, color: scheme.tertiary),
            title: Text(p.version),
            subtitle: Text(
              [
                p.official ? 'Official release' : 'Custom build',
                if (installed) 'installed',
              ].join(' - '),
            ),
            trailing: open
                ? IconButton(
                    tooltip: 'Cancel',
                    onPressed: toggle,
                    icon: const Icon(Icons.close),
                  )
                : IconButton.filledTonal(
                    tooltip: 'Install ${p.version}',
                    onPressed: ready ? toggle : null,
                    icon: const Icon(Icons.system_update_alt),
                  ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'The glasses restart into update mode, take the new '
                    'firmware (a minute or two), and restart again. The '
                    'update wipes the apps on them, so they are uploaded '
                    'again right after.'
                    '${p.official ? '' : ' This is a custom build.'}'
                    '${low ? ' The battery is at ${link.battery}%: charge first.' : ''}',
                    style: text.bodySmall?.copyWith(
                      color: low ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: () => _install(link, p),
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('Install firmware'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _install(FrameLink link, FirmwarePackage package) async {
    setState(() => _armed = null);
    // Nordic DFU, Frame's; and never onto other glasses than its own
    if (package.model != GlassesModel.frame || link.model != package.model) {
      return;
    }
    // the update wipes the glasses' files; the app goes back on after it
    final services = Services.instance;
    final installed = services.settings.installed;
    final app = await luaFiles(rootBundle, installed, model: package.model);
    final sent = services.parts.sentTo(package.model, installed);
    await link.runTask('Firmware', (device, report) async {
      // before the update, not after it: the glasses would be left bare
      needBytecode(app, package.model);
      await installFirmware(link, device, package, app, report);
      services.settings.setUploaded(package.model.name, sent);
    });
  }
}
