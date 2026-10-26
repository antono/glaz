import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/photo_dir.dart';
import '../services/photos.dart';
import '../services/services.dart';
import '../widgets/media_access.dart';

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
        // the viewer swipes through every day's single shots, not one day's
        final singles = [for (final day in days) ...day.photos];
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: MediaAccess(
                      check: photoAccess,
                      icon: Icons.photo_library_outlined,
                      title: 'Show older photos',
                      why:
                          'Photos from an earlier install of the app stay in '
                          'Pictures/Glaz. Allow access to see them here too.',
                      onGranted: _store.refresh,
                    ),
                  ),
                  if (days.isEmpty) const SliverToBoxAdapter(child: _Empty()),
                  for (final day in days) ..._day(context, day, now, singles),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _day(
    BuildContext context,
    PhotoDay day,
    DateTime now,
    List<File> singles,
  ) {
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
      if (day.photos.isNotEmpty) _grid(day.photos, swipe: singles),
    ];
  }
}

/// Photos from an earlier install of the app stay in Pictures/Glaz, but
/// reading them takes the photos permission; this asks for it. Nothing is
/// shown once it is granted, or where it does not apply.
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

/// One series as a grid. Read again when a photo goes, and closed once
/// the last one has.
class _SeriesScreen extends StatefulWidget {
  const _SeriesScreen(this.series);
  final PhotoSeries series;

  @override
  State<_SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<_SeriesScreen> {
  PhotoStore get _store => Services.instance.photos.store;
  late List<File> _files = widget.series.photos;

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

  Future<void> _reread() async {
    final photos = await _store.seriesPhotos(widget.series.dir);
    if (!mounted) return;
    if (photos.isEmpty) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _files = photos);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.series.start;
    return Scaffold(
      appBar: AppBar(
        title: Text(stampLabel(t)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text(_photos(_files.length))),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: _grid(_files),
          ),
        ],
      ),
    );
  }
}

/// [photos] as a grid of thumbnails, each made as it scrolls into view;
/// a tap opens the viewer there, swiping through [swipe] (by default
/// [photos] themselves), which holds them.
Widget _grid(List<File> photos, {List<File>? swipe}) => SliverGrid.builder(
  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 140,
    mainAxisSpacing: 4,
    crossAxisSpacing: 4,
  ),
  itemCount: photos.length,
  itemBuilder: (context, i) => GestureDetector(
    onTap: () {
      final all = swipe ?? photos;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoViewer(all, all.indexOf(photos[i])),
        ),
      );
    },
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
/// others it was opened with. Share hands it to the phone's own share
/// dialog; Delete asks first, then shows the next one.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer(this.photos, this.index, {super.key});
  final List<File> photos;
  final int index;

  @override
  State<PhotoViewer> createState() => _ViewerState();
}

class _ViewerState extends State<PhotoViewer> {
  late final _photos = [...widget.photos];
  late int _page = widget.index;
  late final _controller = PageController(initialPage: widget.index);

  // share_plus shares no files on Linux
  static final _canShare = !Platform.isLinux;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final photo = _photos[_page];
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(photo.path, mimeType: 'image/jpeg')],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _delete() async {
    final photo = _photos[_page];
    final taken = photoTime(photo);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete photo?'),
        content: taken == null ? null : Text(stampLabel(taken)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Services.instance.photos.store.delete(photo);
    if (!mounted) return;
    if (_photos.length == 1) {
      Navigator.of(context).pop();
      return;
    }
    // the last one: step back first, while that page still exists
    if (_page == _photos.length - 1) _controller.jumpToPage(--_page);
    setState(() => _photos.remove(photo));
  }

  @override
  Widget build(BuildContext context) {
    final taken = photoTime(_photos[_page]);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(taken == null ? '' : stampLabel(taken)),
        actions: [
          if (_canShare)
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.share_outlined),
              onPressed: _share,
            ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        onPageChanged: (i) => setState(() => _page = i),
        itemCount: _photos.length,
        itemBuilder: (context, i) => InteractiveViewer(
          key: ValueKey(_photos[i].path),
          child: Center(child: Image.file(_photos[i])),
        ),
      ),
    );
  }
}
