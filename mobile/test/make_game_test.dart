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

  test('a new game starts from what the player describes', () {
    expect(startFor('A deathmatch with laser guns'), 'warp-template-fps');
    expect(startFor('Penguins jump between ice floes'),
        'warp-template-platformer');
    expect(startFor('A racing game for 4'), 'warp-template-blank');
    expect(titleFor('penguins push each other off an ice floe!'),
        'Penguins push each other');
    expect(titleFor('   '), 'My game');
  });

  testWidgets('Make a game in the catalog starts with what to make',
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
    expect(find.text('What game do you want to make?'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('game-idea')), findsNothing);
  });

  testWidgets('a game is a chat with a big Play button, also without a room',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: ModScreen(state: state, mod: _mod('warp-template-blank'))));
    await tester.pump();
    expect(find.text('What should your game be?'), findsOneWidget);
    expect(find.byKey(const ValueKey('game-chat-draft')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('play-mod')));
    await tester.pumpAndSettle();
    // Not in a room: host one or join one.
    expect(find.byKey(const ValueKey('play-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('play-join')), findsOneWidget);
  });
}
