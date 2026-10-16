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
///
/// The folders are read when a photo comes in or access changes, not on
/// every rebuild, and thumbnails are made only as they scroll into view.
class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  PhotoStore get _store => Services.instance.photos.store;
  late Future<List<PhotoDay>> _days = _store.days();

  @override
  void initState() {
    super.initState();
    _store.addListener(_reread);
  }

  @override
  void dispose() {
    _store.removeListener(_reread);
    super.dispose();
  }

  void _reread() {
    if (mounted) setState(() => _days = _store.days());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PhotoDay>>(
      future: _days,
      builder: (context, snap) {
        final days = snap.data;
        if (days == null) return const SizedBox.shrink();
        final now = DateTime.now();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(child: _Access(onGranted: _store.refresh)),
                  if (days.isEmpty) const SliverToBoxAdapter(child: _Empty()),
                  for (final day in days) ..._day(context, day, now),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _day(BuildContext context, PhotoDay day, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return [
      SliverToBoxAdapter(
        child: Padding(
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
      ),
      SliverList.builder(
        itemCount: day.series.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SeriesTile(day.series[i]),
        ),
      ),
      if (day.photos.isNotEmpty) _grid(day.photos),
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
              title: const Text('Show older photos'),
              subtitle: const Text(
                'Photos from an earlier install of the app stay in '
                'Pictures/Glaz. Allow access to see them here too.',
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
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: _grid(series.photos),
          ),
        ],
      ),
    );
  }
}

/// [photos] as a grid of thumbnails, each made as it scrolls into view;
/// a tap opens the viewer there.
Widget _grid(List<File> photos) => SliverGrid.builder(
  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 140,
    mainAxisSpacing: 4,
    crossAxisSpacing: 4,
  ),
  itemCount: photos.length,
  itemBuilder: (context, i) => GestureDetector(
    onTap: () =>
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => PhotoViewer(photos, i))),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: _Thumb(photos[i]),
    ),
  ),
);

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
class PhotoViewer extends StatefulWidget {
  const PhotoViewer(this.photos, this.index, {super.key});
  final List<File> photos;
  final int index;

  @override
  State<PhotoViewer> createState() => _ViewerState();
}

class _ViewerState extends State<PhotoViewer> {
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
