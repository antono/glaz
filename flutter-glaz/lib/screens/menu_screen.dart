import 'package:flutter/material.dart';

import '../glasses_menu.dart';
import '../services/services.dart';
import '../theme.dart';

/// The second tab: what is in the menu on the glasses.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            'This is the menu the glasses show. It lives on the glasses; '
            'the phone describes it, and Upload (Glasses tab) sends the apps '
            'switched on here.',
            style: text.bodyMedium?.copyWith(color: FrameColors.grey),
          ),
        ),
        for (final section in glassesMenu) ...[
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              initiallyExpanded: section == glassesMenu.first,
              leading: Icon(section.icon, color: FrameColors.skyBlue),
              title: Text(section.label, style: text.titleMedium),
              subtitle: Text('${section.modules.length} items'),
              children: [
                for (final module in section.modules) _ModuleTile(module),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// A module: what it is, whether Upload puts it on the glasses, and -- for
/// one that uses the Internet -- whether the phone fetches for it.
class _ModuleTile extends StatelessWidget {
  const _ModuleTile(this.module);
  final GlassesModule module;

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final on = settings.installed(module.id);
        return Column(
          children: [
            ListTile(
              leading: Icon(
                module.icon,
                color: on ? FrameColors.grey : FrameColors.outline,
              ),
              title: Row(
                children: [
                  Flexible(child: Text(module.label)),
                  const SizedBox(width: 8),
                  _KindChip(module.kind),
                ],
              ),
              subtitle: Text(module.summary),
              trailing: Switch(
                value: on,
                onChanged: (v) => settings.setInstalled(module.id, v),
              ),
            ),
            if (module.network && on)
              CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: const Text('Allow Internet access'),
                value: settings.netAllowed(module.id),
                onChanged: (v) => settings.setNetAllowed(module.id, v ?? false),
              ),
          ],
        );
      },
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip(this.kind);
  final ModuleKind kind;

  Color get _color => switch (kind) {
    ModuleKind.info => FrameColors.grey,
    ModuleKind.app => FrameColors.skyBlue,
    ModuleKind.background => FrameColors.yellow,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: _color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        kind.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: _color),
      ),
    );
  }
}
