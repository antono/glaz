import 'package:flutter/material.dart';

import '../frame/model.dart';
import '../glasses_menu.dart';
import '../services/services.dart';
import '../theme.dart';
import 'module_settings_screen.dart';
import 'terminal_screen.dart';

/// The second tab: what is in the menu on the glasses.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = Services.instance;
    // the glasses connected, or those of last time (link.dart)
    return ListenableBuilder(
      listenable: services.link,
      builder: (context, _) => _build(context, services.link.model),
    );
  }

  /// Only the apps [model] has a part for (docs/DEVICES.md): the others
  /// are not uploaded to it, so they are not in its menu either.
  Widget _build(BuildContext context, GlassesModel model) {
    final text = Theme.of(context).textTheme;
    final parts = Services.instance.parts;
    final sections = [
      for (final section in glassesMenu)
        (
          section,
          [
            for (final m in section.modules)
              if (parts.has(m.id, model)) m,
          ],
        ),
    ].where((s) => s.$2.isNotEmpty).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            'This is the menu the glasses show. It lives on the glasses; '
            'the phone describes it, and Upload (Glasses tab) sends the apps '
            'switched on here. Tap one marked with sliders for its settings.'
            '${model == GlassesModel.frame ? '' : ' Only the apps that run '
                      'on ${model.label} are listed.'}',
            style: text.bodyMedium?.copyWith(color: FrameColors.grey),
          ),
        ),
        for (final (section, modules) in sections) ...[
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              initiallyExpanded: section == sections.first.$1,
              leading: Icon(section.icon, color: FrameColors.skyBlue),
              title: Text(section.label, style: text.titleMedium),
              subtitle: Text('${modules.length} items'),
              children: [for (final module in modules) _ModuleTile(module)],
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
/// A module: what it is and whether Upload puts it on the glasses. One
/// with settings (or an Internet permission) opens its page when tapped.
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
        return ListTile(
          leading: Icon(
            module.icon,
            color: on ? FrameColors.grey : FrameColors.outline,
          ),
          title: Row(
            children: [
              Flexible(child: Text(module.label)),
              const SizedBox(width: 8),
              _KindChip(module.kind),
              if (module.configurable) ...[
                const SizedBox(width: 4),
                const Icon(Icons.tune, size: 16, color: FrameColors.skyBlue),
              ],
            ],
          ),
          subtitle: Text(module.summary),
          trailing: Switch(
            value: on,
            onChanged: (v) => settings.setInstalled(module.id, v),
          ),
          onTap: module.configurable
              ? () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => _settingsOf(module)))
              : null,
        );
      },
    );
  }
}

/// A module's settings page: its own ([GlassesModule.ownPage]), or the
/// common one.
Widget _settingsOf(GlassesModule module) => switch (module.id) {
  'term' => Scaffold(
    appBar: AppBar(title: const Text('TERMINAL')),
    body: const SafeArea(top: false, child: TerminalScreen()),
  ),
  _ => ModuleSettingsScreen(module),
};

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
