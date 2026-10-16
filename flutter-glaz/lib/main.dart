import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/photos_screen.dart';
import 'screens/recordings_screen.dart';
import 'screens/more_screen.dart';
import 'screens/remote_screen.dart';
import 'services/services.dart';
import 'theme.dart';
import 'widgets/recording.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Services.start();
  runApp(const GlazApp());
}

class GlazApp extends StatelessWidget {
  const GlazApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'glaz',
      debugShowCheckedModeBanner: false,
      theme: glazTheme(),
      // recording on the glasses shows over every screen
      builder: (context, child) => RecordingBanner(child: child!),
      home: const HomeShell(),
    );
  }
}

/// Bottom navigation between the tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// A tab of the bottom bar.
typedef Tab = ({
  String id,
  IconData icon,
  IconData selected,
  String label,
  Widget screen,
});

/// The tabs, in their default order. Each screen keeps its place in the
/// IndexedStack whatever the bar shows, so rearranging loses no state.
const tabs = <Tab>[
  (
    id: 'glasses',
    icon: Icons.visibility_outlined,
    selected: Icons.visibility,
    label: 'Glasses',
    screen: HomeScreen(),
  ),
  (
    id: 'photos',
    icon: Icons.photo_library_outlined,
    selected: Icons.photo_library,
    label: 'Photos',
    screen: PhotosScreen(),
  ),
  (
    id: 'recordings',
    icon: Icons.mic_none,
    selected: Icons.mic,
    label: 'Voice',
    screen: RecordingsScreen(),
  ),
  (
    id: 'remote',
    icon: Icons.gamepad_outlined,
    selected: Icons.gamepad,
    label: 'Remote',
    screen: RemoteScreen(),
  ),
  (
    id: 'menu',
    icon: Icons.menu_outlined,
    selected: Icons.menu,
    label: 'Menu',
    screen: MenuScreen(),
  ),
  (
    id: 'more',
    icon: Icons.more_horiz,
    selected: Icons.more_horiz,
    label: 'More',
    screen: MoreScreen(),
  ),
];

/// [saved] made safe to use: every tab once, unknown ids dropped, new tabs
/// appended -- an order saved by an older version still works.
List<String> tabOrderFrom(List<String>? saved) {
  final ids = [for (final t in tabs) t.id];
  final order = [
    for (final id in saved ?? const <String>[])
      if (ids.contains(id)) id,
  ];
  return [
    ...order.toSet(),
    for (final id in ids)
      if (!order.contains(id)) id,
  ];
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  String _current = tabs.first.id;
  bool _editing = false;
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Services.instance.settings.addListener(_handsOff);
  }

  @override
  void dispose() {
    Services.instance.settings.removeListener(_handsOff);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive is still on screen: a dialog, the shade, an unfocused window
    _shown =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _handsOff();
  }

  // the Remote tab in front: the glasses take few gestures of their own
  void _handsOff() => Services.instance.link.remoteHandsOff =
      _shown &&
      _current == 'remote' &&
      Services.instance.settings.remoteHandsOff;

  List<String> get _order => tabOrderFrom(Services.instance.settings.tabOrder);

  Tab _tab(String id) => tabs.firstWhere((t) => t.id == id);

  void _edit(bool on) {
    if (on) HapticFeedback.heavyImpact();
    setState(() => _editing = on);
  }

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final recorder = Services.instance.recorder;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, recorder]),
      builder: (context, _) {
        final order = _order;
        // a red dot on Recordings while the glasses record
        Widget icon(String id, IconData data) => Badge(
          isLabelVisible: id == 'recordings' && recorder.recording,
          backgroundColor: FrameColors.red,
          child: Icon(data),
        );
        return PopScope(
          // back leaves the editing mode first
          canPop: !_editing,
          onPopInvokedWithResult: (popped, _) {
            if (!popped) _edit(false);
          },
          child: Scaffold(
            appBar: AppBar(title: Text(_tab(_current).label.toUpperCase())),
            body: SafeArea(
              top: false,
              child: IndexedStack(
                index: tabs.indexWhere((t) => t.id == _current),
                children: [for (final t in tabs) t.screen],
              ),
            ),
            bottomNavigationBar: _editing
                ? _EditBar(
                    order: [for (final id in order) _tab(id)],
                    onReorder: (from, to) {
                      final ids = [...order];
                      ids.insert(to, ids.removeAt(from));
                      HapticFeedback.selectionClick();
                      settings.tabOrder = ids;
                    },
                    onReset: () => settings.tabOrder = null,
                    onDone: () => _edit(false),
                  )
                : GestureDetector(
                    // hold anywhere on the bar to rearrange it
                    onLongPress: () => _edit(true),
                    child: NavigationBar(
                      selectedIndex: order.indexOf(_current),
                      onDestinationSelected: (i) {
                        setState(() => _current = order[i]);
                        _handsOff();
                      },
                      destinations: [
                        for (final id in order)
                          NavigationDestination(
                            icon: icon(id, _tab(id).icon),
                            selectedIcon: icon(id, _tab(id).selected),
                            label: _tab(id).label,
                            // no tooltip: it would take the long press that
                            // opens the editing mode
                            tooltip: '',
                          ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

/// The bar while it is being rearranged: lit up, its icons rocking gently,
/// a line saying what to do, and Done. Each icon drags straight away.
class _EditBar extends StatefulWidget {
  const _EditBar({
    required this.order,
    required this.onReorder,
    required this.onReset,
    required this.onDone,
  });

  final List<Tab> order;
  final void Function(int from, int to) onReorder;
  final VoidCallback onReset;
  final VoidCallback onDone;

  @override
  State<_EditBar> createState() => _EditBarState();
}

class _EditBarState extends State<_EditBar>
    with SingleTickerProviderStateMixin {
  late final _rock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _rock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: FrameColors.surface,
          border: Border(
            top: BorderSide(color: FrameColors.lightGreen, width: 2),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(
                  Icons.open_with,
                  size: 16,
                  color: FrameColors.lightGreen,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Drag the icons to move them',
                    style: text.bodySmall?.copyWith(
                      color: FrameColors.lightGreen,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onReset,
                  child: const Text('Reset'),
                ),
                FilledButton(
                  onPressed: widget.onDone,
                  child: const Text('Done'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (context, box) {
                final width = box.maxWidth / widget.order.length;
                return SizedBox(
                  height: 64,
                  child: ReorderableListView(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    onReorderItem: widget.onReorder,
                    proxyDecorator: (child, _, _) => Material(
                      color: Colors.transparent,
                      child: Transform.scale(scale: 1.15, child: child),
                    ),
                    children: [
                      for (var i = 0; i < widget.order.length; i++)
                        ReorderableDragStartListener(
                          key: ValueKey(widget.order[i].id),
                          index: i,
                          child: SizedBox(
                            width: width,
                            child: _rocking(i, _slot(widget.order[i])),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // neighbours rock in opposite directions, like a row of loose tiles
  Widget _rocking(int i, Widget child) => AnimatedBuilder(
    animation: _rock,
    builder: (context, child) => Transform.rotate(
      angle: (i.isEven ? 1 : -1) * (_rock.value - 0.5) * 0.08,
      child: child,
    ),
    child: child,
  );

  Widget _slot(Tab t) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: FrameColors.green.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: FrameColors.lightGreen),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(t.icon, color: FrameColors.white),
        const SizedBox(height: 2),
        Text(
          t.label,
          style: Theme.of(context).textTheme.labelSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}
