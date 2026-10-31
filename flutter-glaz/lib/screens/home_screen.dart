import 'dart:async';

import 'package:flutter/material.dart';

import '../frame/link.dart';
import '../frame/model.dart';
import '../frame/pairing.dart';
import '../frame/upload.dart';
import '../services/app_check.dart';
import '../services/services.dart';
import '../theme.dart';
import '../widgets/pixel_logo.dart';
import 'about_screen.dart';
import 'firmware_screen.dart';
import 'glasses_files_screen.dart';

/// The first tab: the glasses' status and how to drive them.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        const Center(child: PixelLogo()),
        const SizedBox(height: 12),
        Center(child: Text('[ glaz ]', style: text.headlineMedium)),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'companion for Frame glasses',
            style: text.bodyMedium?.copyWith(color: FrameColors.grey),
          ),
        ),
        const SizedBox(height: 2),
        Center(
          child: Text(
            'v$appVersion',
            style: text.bodySmall?.copyWith(
              color: FrameColors.grey.withValues(alpha: 0.5),
              fontFamily: monoFamily,
            ),
          ),
        ),
        const SizedBox(height: 28),
        const _ConnectionCard(),
        const SizedBox(height: 16),
        const _GlassesAppCard(),
        const SizedBox(height: 16),
        const _GesturesCard(),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context, link),
    );
  }

  static (Color, String) _state(FrameLink link) => switch (link.state) {
    LinkState.connected => (FrameColors.lightGreen, 'Connected'),
    LinkState.connecting when link.waitingForGlasses => (
      FrameColors.yellow,
      'Waiting for the glasses...',
    ),
    LinkState.connecting when link.connects > 0 => (
      FrameColors.yellow,
      'Reconnecting...',
    ),
    LinkState.connecting => (FrameColors.yellow, 'Connecting...'),
    LinkState.scanning => (FrameColors.yellow, 'Looking for the glasses...'),
    LinkState.disconnected => (FrameColors.grey, 'Not connected'),
  };

  Widget _build(BuildContext context, FrameLink link) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: FrameColors.grey);
    final (color, title) = _state(link);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // connected: the dot, the glasses' name and the battery; the
            // firmware is in the Software card below
            Row(
              children: [
                _StatusDot(color: color),
                const SizedBox(width: 12),
                if (link.connected) ...[
                  Expanded(
                    child: Text(
                      link.name ?? 'Connected',
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _Reading(
                    Icons.battery_std,
                    link.battery == null ? '--' : '${link.battery}%',
                    color: (link.battery ?? 100) <= 15
                        ? FrameColors.red
                        : FrameColors.skyBlue,
                  ),
                ] else
                  Expanded(child: Text(title, style: text.titleMedium)),
              ],
            ),
            if (link.waitingForGlasses) ...[
              const SizedBox(height: 12),
              Text(
                'They connect by themselves once in range and awake. '
                'Asleep, a tap on the arm wakes them.',
                style: muted,
              ),
            ] else if (!link.connected) ...[
              const SizedBox(height: 12),
              Text(
                link.error != null
                    ? link.wanted
                          ? 'Trying again. Last: ${link.error}'
                          : 'Failed: ${link.error}'
                    : 'The glasses work on their own; connected, they also '
                          'get the time, phone notifications, the Internet for '
                          'the apps you allow, and send their photos here.',
                style: link.error != null
                    ? muted?.copyWith(color: FrameColors.red)
                    : muted,
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: link.state == LinkState.disconnected
                  ? FilledButton.icon(
                      onPressed: link.connect,
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text('Connect'),
                    )
                  : OutlinedButton.icon(
                      onPressed: link.busy ? null : link.disconnect,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: Text(link.connected ? 'Disconnect' : 'Cancel'),
                    ),
            ),
            if (link.pairing != PairingTrouble.none) ...[
              const SizedBox(height: 12),
              _PairingTrouble(link),
            ] else if (!link.connected &&
                link.error != null &&
                link.canForgetPairing) ...[
              // not recognised, but worth a try when connecting fails
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _confirmForget(context, link),
                child: const Text('Pairing trouble? Forget it on this phone'),
              ),
            ],
            _LinkDetails(link),
          ],
        ),
      ),
    );
  }
}

/// The link in numbers, folded away: what to look at -- and send along
/// with the log -- when the glasses keep dropping.
class _LinkDetails extends StatefulWidget {
  const _LinkDetails(this.link);
  final FrameLink link;

  @override
  State<_LinkDetails> createState() => _LinkDetailsState();
}

class _LinkDetailsState extends State<_LinkDetails> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _open(bool open) {
    _tick?.cancel();
    _tick = open
        ? Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}))
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final now = DateTime.now();
    String ago(DateTime? t) =>
        t == null ? '--' : '${linkSpan(now.difference(t))} ago';
    final up = link.upSince;
    final down = link.downSince;
    final next = link.nextAttempt;
    final rows = [
      (
        'State',
        link.waitingForGlasses ? 'waiting for the glasses' : link.state.name,
      ),
      if (up != null) ('Up for', linkSpan(now.difference(up))),
      if (up == null && down != null)
        ('Down for', linkSpan(now.difference(down))),
      ('Links, drops', '${link.connects}, ${link.drops}'),
      ('Last drop', link.lastDrop ?? '--'),
      if (!link.connected) ('Attempt', '${link.attempt}'),
      if (next != null && next.isAfter(now))
        ('Next attempt', 'in ${linkSpan(next.difference(now))}'),
      ('Heard from glasses', ago(link.lastHeard)),
      ('Signal', link.rssi == null ? '--' : '${link.rssi} dBm'),
      ('MTU', link.mtu == null ? '--' : '${link.mtu}'),
      ('Unanswered packets', '${link.ackTimeouts}'),
      ('Glasses id', link.knownId ?? '--'),
    ];
    final text = Theme.of(context).textTheme;
    return Theme(
      // no lines above and below: it is part of the card
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: Text('Connection details', style: text.bodyMedium),
        onExpansionChanged: _open,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: text.bodySmall?.copyWith(color: FrameColors.grey),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      value,
                      style: text.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Forgets this phone's pairing, after asking: the glasses then have to be
/// paired again, and that is the phone's own dialog, so say so first.
Future<void> _confirmForget(BuildContext context, FrameLink link) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Forget the pairing?'),
      content: const Text(
        'This phone forgets the glasses and pairs with them again. Android '
        'asks to pair: tap Pair. The glasses must be ready to pair -- reset '
        'on the charger, with nothing paired.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Forget and pair'),
        ),
      ],
    ),
  );
  if (ok == true) await link.forgetPairing();
}

/// The pairing no longer holds: what happened, and the way out.
class _PairingTrouble extends StatelessWidget {
  const _PairingTrouble(this.link);
  final FrameLink link;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final phone = link.pairing == PairingTrouble.phoneStale;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: FrameColors.yellow),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link_off, color: FrameColors.yellow),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  phone
                      ? 'The glasses forgot this phone'
                      : 'The glasses are paired with another phone',
                  style: text.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            phone
                ? 'Their pairing was reset -- on the charger, say -- but this '
                      'phone still holds the old one, so the glasses turn it '
                      'away. Forget it here and pair again.'
                : 'Or with this phone before it forgot them. Only the glasses '
                      'can let go: put them on the charger and press its '
                      'button, then connect again.',
            style: text.bodyMedium?.copyWith(color: FrameColors.grey),
          ),
          const SizedBox(height: 12),
          if (phone && link.canForgetPairing)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: FrameColors.red,
                foregroundColor: FrameColors.white,
              ),
              onPressed: () => _confirmForget(context, link),
              icon: const Icon(Icons.link_off),
              label: const Text('Forget and pair again'),
            )
          else
            OutlinedButton.icon(
              onPressed: link.connect,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Connect again'),
            ),
        ],
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading(this.icon, this.value, {this.color = FrameColors.skyBlue});
  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 6),
      Text(
        value,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(fontFamily: monoFamily),
      ),
    ],
  );
}

/// The app on the glasses (main.lua) and their firmware: what the phone
/// can put on them.
class _GlassesAppCard extends StatelessWidget {
  const _GlassesAppCard();

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    final check = Services.instance.appCheck;
    return ListenableBuilder(
      listenable: Listenable.merge([link, check]),
      builder: (context, _) => _build(context, link, check.app),
    );
  }

  Widget _build(BuildContext context, FrameLink link, GlassesApp app) {
    final text = Theme.of(context).textTheme;
    final ready = link.connected && !link.busy;
    final halo = link.connected && link.model == GlassesModel.halo;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Software', style: text.titleMedium),
          ),
          if (link.busy && link.task != 'Firmware')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${link.task}: ${link.taskStep}'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: link.taskProgress),
                ],
              ),
            ),
          if (!link.busy && link.taskDone != null)
            ListTile(
              leading: const Icon(Icons.check_circle, color: FrameColors.green),
              title: const Text('Done'),
              subtitle: Text(link.taskDone!),
            ),
          if (!link.busy && link.taskError != null)
            ListTile(
              leading: const Icon(Icons.error_outline, color: FrameColors.red),
              title: const Text('Last attempt failed'),
              subtitle: Text(link.taskError!),
            ),
          if (halo)
            const ListTile(
              leading: Icon(Icons.info_outline, color: FrameColors.yellow),
              title: Text('Halo support is new'),
              subtitle: Text(
                'Tried in the Halo emulator, not yet on a Halo: the menu and '
                'a few apps (docs/HALO.md)',
              ),
            ),
          if (ready && app == GlassesApp.missing)
            const ListTile(
              leading: Icon(Icons.warning_amber, color: FrameColors.yellow),
              title: Text('No app on the glasses'),
              subtitle: Text('Upload puts it on them'),
            )
          else if (ready && app == GlassesApp.stopped)
            const ListTile(
              leading: Icon(Icons.warning_amber, color: FrameColors.yellow),
              title: Text('The app on the glasses is not running'),
              subtitle: Text('Restart it, or Upload it again'),
            ),
          ListTile(
            enabled: ready,
            leading: const Icon(Icons.upload, color: FrameColors.skyBlue),
            title: const Text('Upload'),
            subtitle: const Text('main.lua and the apps switched on in Menu'),
            onTap: () => _upload(context, link),
          ),
          ListTile(
            enabled: ready,
            leading: const Icon(Icons.restart_alt, color: FrameColors.skyBlue),
            title: const Text('Restart'),
            subtitle: const Text('Start the app on the glasses again'),
            onTap: () => link.runTask('Restart', restartApp),
          ),
          ListTile(
            enabled: ready,
            leading: const Icon(Icons.folder_open, color: FrameColors.skyBlue),
            title: const Text('Files'),
            subtitle: const Text('Look at what is stored on the glasses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GlassesFilesScreen()),
            ),
          ),
          // open for Halo too: it lists only the firmware for the glasses
          // at hand, none yet for Halo (firmware_screen.dart)
          ListTile(
            leading: const Icon(Icons.memory, color: FrameColors.skyBlue),
            title: const Text('Firmware'),
            subtitle: Text(link.firmware ?? 'Install another version'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const FirmwareScreen())),
          ),
        ],
      ),
    );
  }

  Future<void> _upload(BuildContext context, FrameLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upload to the glasses?'),
        content: const Text(
          'The app on the glasses stops, the glasses restart, and main.lua '
          'with the apps switched on in Menu is written to them. Takes a '
          'minute or two; keep the glasses close.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Services.instance.appCheck.upload();
    // the card says it too, but may be scrolled away
    final done = link.taskDone;
    if (done != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Done. $done')));
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Frame has no buttons: everything is a tap on the arm or a head tilt.
class _GesturesCard extends StatelessWidget {
  const _GesturesCard();

  // As glaz.lua handles them (its header comment, "Taps")
  static const _gestures = [
    (Icons.looks_one_outlined, '1 tap', 'select, or bring back the last app'),
    (
      Icons.looks_two_outlined,
      '2 taps',
      'back, one level up; on a blank screen, the menu; wakes the glasses',
    ),
    (Icons.looks_3_outlined, '3 taps', 'sleep, from anywhere'),
    (
      Icons.swap_horiz,
      'tilt head',
      'toward a shoulder and back to scroll; in an app, its own cursor',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Gestures', style: text.titleMedium),
            ),
            for (final (icon, gesture, meaning) in _gestures)
              ListTile(
                dense: true,
                leading: Icon(icon, color: FrameColors.skyBlue),
                title: Text(
                  gesture,
                  style: text.bodyLarge?.copyWith(fontFamily: monoFamily),
                ),
                subtitle: Text(meaning),
              ),
          ],
        ),
      ),
    );
  }
}
