import 'package:flutter/material.dart';

import '../glasses_menu.dart';
import '../services/service_list.dart';
import '../services/services.dart';

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

  static String _subtitle(Services s, GlazService service) {
    switch (service.id) {
      case 'notifications':
        if (!s.notifications.supported) return 'Android only';
        if (!s.notifications.permission) {
          return 'Needs permission to read notifications';
        }
        return s.notifications.forwarded == 0
            ? service.description
            : '${s.notifications.forwarded} sent to the glasses';
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
