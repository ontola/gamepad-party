import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/navigation/host_room.dart';

void main() {
  testWidgets('Host on this phone opens the browser host full screen',
      (tester) async {
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
    expect(find.text('Host on a computer'), findsOneWidget);
    await tester.tap(find.text('Host on this phone'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'host');
    expect(calls.single.arguments, {'url': 'https://splitscreen.club/play/?render=540'});
  });
}
