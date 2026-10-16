import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/pixel_logo.dart';

/// Kept equal to `version:` in pubspec.yaml by test/version_test.dart.
const appVersion = '2.5.0';

/// The third tab: what this is, versions, licences.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: FrameColors.grey);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        const Center(child: PixelLogo(size: 96, alive: false)),
        const SizedBox(height: 12),
        Center(child: Text('glaz $appVersion', style: text.titleMedium)),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'glaz is a menu and a set of small apps for the Brilliant Labs '
              'Frame smart glasses. They run on the glasses, in Lua, and are '
              'driven by taps and head tilts. This app is the phone side: '
              'it connects over Bluetooth, keeps their photos, sets their '
              'clock, forwards notifications, fetches from the Internet for '
              'the apps you allow, and puts new apps and firmware on them.',
              style: muted,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.visibility, color: FrameColors.skyBlue),
                title: Text('Glasses'),
                subtitle: Text('Brilliant Labs Frame'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.gavel, color: FrameColors.skyBlue),
                title: const Text('Open source licences'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'glaz',
                  applicationVersion: appVersion,
                  applicationIcon: const Padding(
                    padding: EdgeInsets.all(8),
                    child: PixelLogo(size: 64, alive: false),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
