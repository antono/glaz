import 'dart:io';

import 'package:flutter/material.dart';

import '../services/photo_dir.dart';
import '../services/photos.dart';
import '../services/services.dart';

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String dayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final label = '${day.day} ${_months[day.month - 1]}';
  return day.year == now.year ? label : '$label ${day.year}';
}

String _photos(int n) => n == 1 ? '1 photo' : '$n photos';

/// Photos from the glasses, newest day first. Each day shows its Time
/// series folders, with how many photos each holds, then its single shots.
class PhotosScreen extends StatelessWidget {
  const PhotosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Services.instance.photos.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => FutureBuilder<List<PhotoDay>>(
        future: store.days(),
        builder: (context, snap) {
          final days = snap.data;
          if (days == null) return const SizedBox.shrink();
          final now = DateTime.now();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              _Access(onGranted: store.refresh),
              if (days.isEmpty) const _Empty(),
              for (final day in days) ..._day(context, day, now),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _day(BuildContext context, PhotoDay day, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Row(
          children: [
            Text(
              dayLabel(day.date, now),
              style: text.titleSmall?.copyWith(color: scheme.primary),
            ),
            const Spacer(),
            Text(
              _photos(day.count),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      for (final series in day.series)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SeriesTile(series),
        ),
      if (day.photos.isNotEmpty) _Grid(day.photos),
    ];
  }
}

/// Photos from an earlier install of the app stay in Pictures/Glaz, but
/// reading them takes the photos permission; this asks for it. Nothing is
/// shown once it is granted, or where it does not apply.
class _Access extends StatefulWidget {
  const _Access({required this.onGranted});
  final VoidCallback onGranted;

  @override
  State<_Access> createState() => _AccessState();
}

class _AccessState extends State<_Access> {
  late Future<bool> _granted = photoAccess();

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
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photos from before a reinstall'),
              subtitle: const Text(
                'They are kept in Pictures/Glaz; allow access to show them.',
              ),
              trailing: TextButton(
                onPressed: () async {
                  final ok = await photoAccess(request: true);
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_camera_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No photos yet.\nTake one with Camera or Time series '
              'on the glasses.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A series folder: its first photo, when it started, how many photos.
class _SeriesTile extends StatelessWidget {
  const _SeriesTile(this.series);
  final PhotoSeries series;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = series.start;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _Thumb(series.photos.first, size: 56),
            ),
            Positioned(
              right: -4,
              bottom: -4,
              child: Icon(Icons.burst_mode, size: 20, color: scheme.primary),
            ),
          ],
        ),
        title: Text(stampLabel(t)),
        subtitle: const Text('Time series'),
        trailing: Chip(
          label: Text(_photos(series.photos.length)),
          visualDensity: VisualDensity.compact,
        ),
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => _SeriesScreen(series))),
      ),
    );
  }
}

class _SeriesScreen extends StatelessWidget {
  const _SeriesScreen(this.series);
  final PhotoSeries series;

  @override
  Widget build(BuildContext context) {
    final t = series.start;
    return Scaffold(
      appBar: AppBar(
        title: Text(stampLabel(t)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text(_photos(series.photos.length))),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _Grid(series.photos),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid(this.photos);
  final List<File> photos;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: photos.length,
      itemBuilder: (context, i) => GestureDetector(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => _Viewer(photos, i))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _Thumb(photos[i]),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.file, {this.size});
  final File file;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      file,
      width: size,
      height: size,
      fit: BoxFit.cover,
      cacheWidth: 280, // thumbnails do not need the full 512 px
      errorBuilder: (context, _, _) => Container(
        width: size,
        height: size,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

/// One photo full screen, titled with when it was taken; swipe for the
/// others of the same group.
class _Viewer extends StatefulWidget {
  const _Viewer(this.photos, this.index);
  final List<File> photos;
  final int index;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late int _page = widget.index;
  late final _controller = PageController(initialPage: widget.index);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final taken = photoTime(photos[_page]);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(taken == null ? '' : stampLabel(taken)),
      ),
      body: PageView.builder(
        controller: _controller,
        onPageChanged: (i) => setState(() => _page = i),
        itemCount: photos.length,
        itemBuilder: (context, i) =>
            InteractiveViewer(child: Center(child: Image.file(photos[i]))),
      ),
    );
  }
}
