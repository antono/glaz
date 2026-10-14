import 'package:flutter/material.dart';

import '../glasses_menu.dart';
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
            'the phone only describes it.',
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

class _ModuleTile extends StatelessWidget {
  const _ModuleTile(this.module);
  final GlassesModule module;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(module.icon, color: FrameColors.grey),
      title: Text(module.label),
      subtitle: Text(module.summary),
      trailing: _KindChip(module.kind),
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
