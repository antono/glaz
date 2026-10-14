import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/glasses_menu.dart';

/// The phone's description of the menu must match the glasses' own MENU
/// tree in ../frame_app.lua and the labels in ../modules/*.lua.
void main() {
  final lua = File('../frame_app.lua').readAsStringSync();

  test('sections and items match frame_app.lua', () {
    final tree = RegExp(r'local MENU = \{(.*?)\n\}', dotAll: true)
        .firstMatch(lua)!
        .group(1)!;
    final sections = RegExp(r"\{ label = '([^']+)',([^}]*)\}")
        .allMatches(tree)
        .map((m) => [
              m.group(1)!,
              ...RegExp(r"'([^']+)'").allMatches(m.group(2)!).map((i) => i.group(1)!),
            ])
        .toList();

    expect(
      [for (final s in glassesMenu) [s.label, ...s.modules.map((m) => m.id)]],
      sections,
    );
  });

  test('labels match the modules', () {
    for (final module in glassesMenu.expand((s) => s.modules)) {
      final src = File('../modules/${module.id}.lua').readAsStringSync();
      final label = RegExp(r"_M\.label = '([^']+)'").firstMatch(src)!.group(1);
      expect(module.label, label, reason: 'modules/${module.id}.lua');
    }
  });
}
