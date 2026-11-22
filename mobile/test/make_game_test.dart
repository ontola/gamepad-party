import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/screens/mods_screen.dart';
import 'package:gamenight/storage/phone_store.dart';
import 'package:gamenight/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

GameMod _mod(String base) => GameMod(
    id: '$base-mod-1a2b3c4d',
    title: 'Penguin Push',
    base: base,
    game: 'project-$base-mod-1a2b3c4d-865370577');

void main() {
  test('a game made from a template is a game of your own, not a mod', () {
    expect(isOwnGame(_mod('warp-template-platformer')), isTrue);
    expect(isOwnGame(_mod('warp-template-blank')), isTrue);
    expect(isOwnGame(_mod('neon-siege-warp')), isFalse);
    // The host makes every template a base under this prefix.
    expect(gameTemplates.keys.every((k) => k.startsWith('warp-template-')),
        isTrue);
  });

  testWidgets('Make a game in the catalog explains what it takes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: Padding(
                padding: const EdgeInsets.all(16),
                child: MakeGameCard(state: state)))));
    await tester.tap(find.byKey(const ValueKey('make-a-game')));
    await tester.pumpAndSettle();
    expect(find.text('Make your own game'), findsOneWidget);
    expect(find.textContaining('You need an account'), findsOneWidget);
    expect(find.textContaining('they run out'), findsOneWidget);
    expect(find.textContaining('share it with others'), findsOneWidget);
    // Signed out, the email field to sign in is right on the page.
    expect(find.byKey(const ValueKey('make-game-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('sign-in-email')), findsOneWidget);
    // Without the app's store (here, as in a browser) it points to the app.
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('get-the-app')), 200,
        scrollable: find
            .descendant(
                of: find.byType(MakeGameScreen),
                matching: find.byType(Scrollable))
            .first);
    expect(find.byKey(const ValueKey('get-the-app')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-game')), findsNothing);
  });
}
