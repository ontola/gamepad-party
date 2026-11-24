import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/navigation/browser_host_stub.dart';
import 'package:gamenight/navigation/host_room.dart';
import 'package:gamenight/screens/host_screen.dart';
import 'package:gamenight/theme.dart';

Future<void> _show(WidgetTester tester, BrowserHostBlocker? blocker) =>
    tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: HostScreen.testing(cloud: CloudApi(), blocker: blocker)));

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(800, 1600);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first.reset();
  });

  testWidgets('Host a room opens a page; Android hosts on this phone',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gamenight/apps'), (call) async {
      calls.add(call);
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
            onPressed: () => hostRoom(context, CloudApi()),
            child: const Text('Host a room')),
      ),
    ));
    await tester.tap(find.text('Host a room'));
    await tester.pumpAndSettle();
    expect(find.byType(HostScreen), findsOneWidget);
    expect(find.text('Play right in your browser'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-elsewhere')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-phone')));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'host');
    expect(calls.single.arguments,
        {'url': 'https://splitscreen.club/play/?render=540'});
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a browser that runs the host starts it right here',
      (tester) async {
    await _show(tester, null);
    expect(find.byKey(const ValueKey('host-here')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-elsewhere')), findsNothing);
    expect(find.byKey(const ValueKey('host-download')), findsOneWidget);
  });

  testWidgets('elsewhere it names the address and why', (tester) async {
    await _show(tester, BrowserHostBlocker.browser);
    expect(find.byKey(const ValueKey('host-here')), findsNothing);
    expect(find.text('gamenight.ontola.io/play'), findsOneWidget);
    expect(find.textContaining('has no WebGPU'), findsWidgets);
    await _show(tester, BrowserHostBlocker.phone);
    expect(find.textContaining('A phone is too slow'), findsOneWidget);
  });
}
