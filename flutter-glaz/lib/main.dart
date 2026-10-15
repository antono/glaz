import 'package:flutter/material.dart';

import 'screens/about_screen.dart';
import 'screens/home_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/photos_screen.dart';
import 'screens/services_screen.dart';
import 'services/services.dart';
import 'theme.dart';

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

class _HomeShellState extends State<HomeShell> {
  static const _tabs = [
    (Icons.visibility_outlined, Icons.visibility, 'Glasses', HomeScreen()),
    (
      Icons.photo_library_outlined,
      Icons.photo_library,
      'Photos',
      PhotosScreen(),
    ),
    (Icons.menu_outlined, Icons.menu, 'Menu', MenuScreen()),
    (Icons.hub_outlined, Icons.hub, 'Services', ServicesScreen()),
    (Icons.info_outline, Icons.info, 'About', AboutScreen()),
  ];

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_tabs[_index].$3.toUpperCase())),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _index,
          children: [for (final tab in _tabs) tab.$4],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, selected, label, _) in _tabs)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selected),
              label: label,
            ),
        ],
      ),
    );
  }
}
