import 'package:flutter/material.dart';

import '../services/services.dart';
import '../theme.dart';

/// The app's own settings, the ones no module or service owns.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Remote', style: text.titleMedium),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              secondary: const Icon(
                Icons.do_not_touch_outlined,
                color: FrameColors.skyBlue,
              ),
              title: const Text('Glasses gestures off'),
              subtitle: const Text(
                'While the Remote tab is open, the glasses ignore tilts and '
                'taps on the arm, except a triple tap to sleep and one or '
                'two taps on a blank screen. While a keyboard remote is '
                'connected, all but the triple tap.',
              ),
              value: settings.remoteHandsOff,
              onChanged: (on) => settings.remoteHandsOff = on,
            ),
          ),
        ],
      ),
    );
  }
}
