import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../glasses_menu.dart';
import '../services/location.dart';
import '../services/service_list.dart';
import '../services/services.dart';
import 'agent_screen.dart';

/// What the phone does for Lua apps on the glasses.
class ServicesScreen extends StatelessWidget {
  const ServicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        s.settings,
        s.link,
        s.network,
        s.notifications,
        s.location,
        s.keys,
        s.flipperRemote,
      ]),
      builder: (context, _) => _build(context, s),
    );
  }

  Widget _build(BuildContext context, Services s) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            s.link.connected
                ? 'The phone does these for apps on the glasses.'
                : 'The phone does these for apps on the glasses, '
                      'while they are connected.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final service in services)
                if (service.id == 'agent')
                  // its page holds its settings and what it was asked
                  ListTile(
                    title: Text(service.label),
                    subtitle: Text(_subtitle(s, service)),
                    trailing: Switch(
                      value: s.settings.serviceOn(service.id),
                      onChanged: (v) => _toggle(context, s, service.id, v),
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AgentScreen(),
                      ),
                    ),
                  )
                else
                  SwitchListTile(
                    title: Row(
                      children: [
                        Text(service.label),
                        if (!service.ready) ...[
                          const SizedBox(width: 8),
                          const _Badge('Planned'),
                        ],
                      ],
                    ),
                    subtitle: Text(_subtitle(s, service)),
                    value: service.ready && s.settings.serviceOn(service.id),
                    onChanged: service.ready
                        ? (v) => _toggle(context, s, service.id, v)
                        : null,
                  ),
            ],
          ),
        ),
        if (s.notifications.supported) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: s.link.connected ? s.notifications.sendTest : null,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Send a test notification'),
            ),
          ),
        ],
        if (_keysForeground(s)) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: s.keys.openSettings,
              icon: const Icon(Icons.keyboard_outlined),
              label: const Text('Keyboard remote in the background'),
            ),
          ),
        ],
        if (s.settings.serviceOn('flipper_remote')) ..._flipper(context, s),
        if (s.network.log.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
            child: Text(
              'Recent Internet requests',
              style: text.titleSmall?.copyWith(color: scheme.primary),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final e in s.network.log)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      e.status >= 200 && e.status < 300
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: e.status >= 200 && e.status < 300
                          ? scheme.primary
                          : scheme.error,
                    ),
                    title: Text(
                      '${e.module}: ${e.method} ${e.url}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      e.status == 0 ? 'no answer' : 'status ${e.status}',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The Flipper remote: Android pairs a Flipper here, through the
  /// system's companion chooser, and lists those paired; elsewhere the
  /// phone looks for one each time.
  static List<Widget> _flipper(BuildContext context, Services s) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final remote = s.flipperRemote;
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
          child: Text(
            'The Flipper is found while its Glaz app runs.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }
    return [
      if (remote.paired.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text(
            'Paired Flipper',
            style: text.titleSmall?.copyWith(color: scheme.primary),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final f in remote.paired)
                ListTile(
                  leading: Icon(
                    remote.connected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                  ),
                  title: Text(f.name ?? f.address),
                  subtitle: f.name == null ? null : Text(f.address),
                  trailing: IconButton(
                    tooltip: 'Forget',
                    icon: const Icon(Icons.link_off),
                    onPressed: () => remote.forget(f.address),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            "On Android 12 and later, glaz starts by itself when the "
            "Flipper's Glaz app is open nearby",
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          // the notification that says glaz holds the links, once paired
          onPressed: () async {
            if (await remote.pair()) await s.hold.askNotifications();
          },
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Pair Flipper'),
        ),
      ),
    ];
  }

  /// The keyboard remote is on but works only with Glaz on screen.
  static bool _keysForeground(Services s) =>
      defaultTargetPlatform == TargetPlatform.android &&
      !kIsWeb &&
      s.settings.serviceOn('keys') &&
      !s.keys.background;

  static String _subtitle(Services s, GlazService service) {
    switch (service.id) {
      case 'agent':
        return s.settings.agentUrl.isEmpty
            ? 'Not set up yet: tap to set it up'
            : 'Assistant and Factchecker ask '
                  '${AgentLink.state(true, s.settings.agentUrl)}';
      case 'keys':
        return _keysForeground(s)
            ? 'Only with Glaz on screen: turn it on in Accessibility '
                  'for the background'
            : service.description;
      case 'flipper_remote':
        if (!s.settings.serviceOn('flipper_remote')) {
          return service.description;
        }
        if (s.flipperRemote.connected) {
          return 'Connected to ${s.flipperRemote.name ?? 'the Flipper'}';
        }
        return defaultTargetPlatform == TargetPlatform.android &&
                !kIsWeb &&
                s.flipperRemote.paired.isEmpty
            ? 'No Flipper paired yet: Pair Flipper below'
            : 'Not connected: start Glaz on the Flipper';
      case 'notifications':
        if (!s.notifications.supported) return 'Android only';
        if (!s.notifications.permission) {
          return 'Needs permission to read notifications';
        }
        return s.notifications.forwarded == 0
            ? service.description
            : '${s.notifications.forwarded} sent to the glasses';
      case 'location':
        final allowed = [
          for (final sec in glassesMenu)
            for (final a in sec.modules)
              if (a.location && s.settings.locAllowed(a.id)) a.label,
        ];
        return allowed.isEmpty
            ? 'No app allowed yet: Menu tab'
            : 'Allowed: ${allowed.join(', ')}';
      case 'network':
        final allowed = [
          for (final sec in glassesMenu)
            for (final a in sec.modules)
              if (a.network && s.settings.netAllowed(a.id)) a.label,
        ];
        return allowed.isEmpty
            ? 'No app allowed yet: Menu tab'
            : 'Allowed: ${allowed.join(', ')}';
      default:
        return service.description;
    }
  }

  static Future<void> _toggle(
    BuildContext context,
    Services s,
    String id,
    bool on,
  ) async {
    if (id == 'notifications' && on && !s.notifications.permission) {
      // the system page comes up; the switch stays off unless it is granted
      if (!await s.notifications.requestPermission()) return;
    }
    if (id == 'flipper_remote' && on) {
      // the notification that says glaz holds the links; a no is fine
      await s.hold.askNotifications();
    }
    if (id == 'location' && on && !await LocationService.permitted()) {
      // the phone's own permission, asked here and never from the glasses
      if (!await s.location.requestPermission()) return;
    }
    s.settings.setService(id, on);
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}
