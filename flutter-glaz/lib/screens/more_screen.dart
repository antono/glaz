import 'package:flutter/material.dart';

import '../theme.dart';
import 'about_screen.dart';
import 'app_settings_screen.dart';
import 'assistant_screen.dart';
import 'services_screen.dart';

/// What does not need a tab of its own: the phone's services for the
/// glasses, the assistant's agent, and About.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Route<void> page(String title, Widget body) => MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(top: false, child: body),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.hub, color: FrameColors.skyBlue),
                title: const Text('Services'),
                subtitle: const Text(
                  'Clock, notifications, Internet, photos, location',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context)
                        .push(page('SERVICES', const ServicesScreen())),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.assistant,
                  color: FrameColors.skyBlue,
                ),
                title: const Text('Assistant'),
                subtitle: const Text('The agent the glasses ask'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context)
                        .push(page('ASSISTANT', const AssistantScreen())),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune, color: FrameColors.skyBlue),
                title: const Text('Settings'),
                subtitle: const Text('How the app works with the glasses'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context)
                        .push(page('SETTINGS', const AppSettingsScreen())),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info, color: FrameColors.skyBlue),
                title: const Text('About'),
                subtitle: const Text('Version and open-source licences'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context)
                        .push(page('ABOUT', const AboutScreen())),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
