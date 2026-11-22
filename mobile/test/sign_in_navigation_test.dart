import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:gamenight/screens/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_test.dart' show FakeCloud;

void main() {
  for (final entry in ['code', 'link']) {
    final viaLink = entry == 'link';
    testWidgets('optional profile sign-in by $entry keeps the home route',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cloud = FakeCloud();
      final state = AppState(await SharedPreferences.getInstance(),
          cloud: CloudApi(client: cloud.client));
      final links = StreamController<Uri>();
      addTearDown(links.close);
      await tester.pumpWidget(GameNightApp(state: state, links: links.stream));
      await tester.tap(find.text('You'));
      await tester.pumpAndSettle();
      final email = find.descendant(
          of: find.byType(PlayerScreen),
          matching: find.byKey(const ValueKey('sign-in-email')));
      await tester.scrollUntilVisible(email, 200,
          scrollable: find
              .descendant(
                  of: find.byType(PlayerScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.enterText(email, 'test@example.com');
      // The keyboard's send key emails the code, like the button.
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      if (viaLink) {
        links.add(
            Uri.parse('https://gamenight.ontola.io/auth/app#code=12345678'));
        links.add(
            Uri.parse('https://gamenight.ontola.io/auth/app#code=12345678'));
      } else {
        await tester.enterText(
            find.descendant(
                of: find.byType(PlayerScreen),
                matching: find.byKey(const ValueKey('sign-in-code'))),
            '12345678');
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(state.signedIn, isTrue);
      expect(state.inHostedRoom, isFalse);
      expect(cloud.calls.where((c) => c == 'POST /v1/rooms/join'), isEmpty);
      expect(cloud.calls.where((c) => c == 'POST /auth/email/verify'),
          hasLength(1));
      await tester.tap(find.text('Room'));
      await tester.pumpAndSettle();
      expect(find.text('Scan the QR on the TV'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
