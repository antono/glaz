import 'package:flutter/material.dart';

import '../glasses_menu.dart';
import '../services/services.dart';
import '../theme.dart';
import 'assistant_screen.dart';
import 'reader_screen.dart';

/// A module's own page in the Menu tab: on the glasses or not, its
/// settings, and for one that uses the Internet, the permission.
class ModuleSettingsScreen extends StatelessWidget {
  const ModuleSettingsScreen(this.module, {super.key});
  final GlassesModule module;

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(module.label.toUpperCase())),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                module.summary,
                style: text.bodyMedium?.copyWith(color: FrameColors.grey),
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: Icon(module.icon, color: FrameColors.skyBlue),
                    title: const Text('On the glasses'),
                    subtitle: const Text('Sent by Upload (Glasses tab)'),
                    value: settings.installed(module.id),
                    onChanged: (v) => settings.setInstalled(module.id, v),
                  ),
                  if (module.location)
                    SwitchListTile(
                      secondary: const Icon(
                        Icons.my_location,
                        color: FrameColors.skyBlue,
                      ),
                      title: const Text('Location access'),
                      subtitle: const Text('Where the phone is, when it asks'),
                      value: settings.locAllowed(module.id),
                      onChanged: (v) => settings.setLocAllowed(module.id, v),
                    ),
                  if (module.network)
                    SwitchListTile(
                      secondary: const Icon(
                        Icons.public,
                        color: FrameColors.skyBlue,
                      ),
                      title: const Text('Internet access'),
                      subtitle: const Text('The phone fetches for it'),
                      value: settings.netAllowed(module.id),
                      onChanged: (v) => settings.setNetAllowed(module.id, v),
                    ),
                ],
              ),
            ),
            if (module.settings.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
                child: Text('Settings', style: text.titleMedium),
              ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final s in module.settings)
                      s.text
                          ? _TextSetting(module, s)
                          : _ChoiceSetting(module, s),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Sent to the glasses as you change them, and on every '
                  'connect; they keep them until the next change.',
                  style: text.bodySmall?.copyWith(color: FrameColors.grey),
                ),
              ),
            ],
            // the phone's side of the assistant: its agent, its language
            if (module.id == 'assistant') const AssistantSettings(),
            // the texts it reads, kept on the phone
            if (module.id == 'reader') const ReaderLibrary(),
          ],
        ),
      ),
    );
  }
}

class _ChoiceSetting extends StatelessWidget {
  const _ChoiceSetting(this.module, this.setting);
  final GlassesModule module;
  final ModuleSetting setting;

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final value = settings.config(module.id, setting.key) ?? setting.initial;
    return ListTile(
      title: Text(setting.label),
      subtitle: setting.help == null ? null : Text(setting.help!),
      trailing: DropdownButton<String>(
        value: setting.options.contains(value) ? value : setting.initial,
        underline: const SizedBox.shrink(),
        items: [
          for (final o in setting.options)
            DropdownMenuItem(value: o, child: Text(setting.labelOf(o))),
        ],
        onChanged: (v) {
          if (v != null) settings.setConfig(module.id, setting.key, v);
        },
      ),
    );
  }
}

class _TextSetting extends StatefulWidget {
  const _TextSetting(this.module, this.setting);
  final GlassesModule module;
  final ModuleSetting setting;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final _controller = TextEditingController(
    text:
        Services.instance.settings.config(
          widget.module.id,
          widget.setting.key,
        ) ??
        widget.setting.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: widget.setting.label,
          helperText: widget.setting.help,
        ),
        textCapitalization: TextCapitalization.words,
        onChanged: (v) => Services.instance.settings.setConfig(
          widget.module.id,
          widget.setting.key,
          v,
        ),
      ),
    );
  }
}
