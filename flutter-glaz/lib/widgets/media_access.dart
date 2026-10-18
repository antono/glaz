import 'package:flutter/material.dart';

/// A card asking for access to the photos or recordings an earlier install
/// of the app left in the shared folders (services/photo_dir.dart); gone
/// once granted. [check]: photoAccess or recordingAccess.
class MediaAccess extends StatefulWidget {
  const MediaAccess({
    super.key,
    required this.check,
    required this.icon,
    required this.title,
    required this.why,
    required this.onGranted,
  });

  final Future<bool> Function({bool request}) check;
  final IconData icon;
  final String title;
  final String why;
  final VoidCallback onGranted;

  @override
  State<MediaAccess> createState() => _MediaAccessState();
}

class _MediaAccessState extends State<MediaAccess> {
  late Future<bool> _granted = widget.check();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _granted,
      builder: (context, snap) {
        if (snap.data != false) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Card(
            child: ListTile(
              leading: Icon(widget.icon),
              title: Text(widget.title),
              subtitle: Text(widget.why),
              trailing: TextButton(
                onPressed: () async {
                  final ok = await widget.check(request: true);
                  setState(() => _granted = Future.value(ok));
                  if (ok) widget.onGranted();
                },
                child: const Text('Allow'),
              ),
            ),
          ),
        );
      },
    );
  }
}
