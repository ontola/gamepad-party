import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/screens/mods_screen.dart';
import 'package:gamenight/theme.dart';

Future<void> _show(WidgetTester tester) => tester.pumpWidget(MaterialApp(
    theme: gameNightTheme(),
    home: const Scaffold(
        body: Padding(padding: EdgeInsets.all(16), child: GetTheApp()))));

void main() {
  testWidgets('without the app, Mods links to every download', (tester) async {
    await _show(tester);
    for (final key in ['get-android', 'get-windows', 'get-mac']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(find.textContaining('Ask for an invite'), findsOneWidget);
  });

  testWidgets("the visitor's own platform comes first and stands out",
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _show(tester);
    final android = find.byKey(const ValueKey('get-android'));
    expect(tester.widget(android), isA<FilledButton>());
    expect(tester.widget(find.byKey(const ValueKey('get-mac'))),
        isA<OutlinedButton>());
    expect(
        tester.getTopLeft(android).dx,
        lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('get-windows'))).dx));
    debugDefaultTargetPlatformOverride = null;
  });
}
