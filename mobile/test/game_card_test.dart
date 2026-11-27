import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/screens/catalog_view.dart';
import 'package:gamenight/theme.dart';

void main() {
  final data = jsonDecode(
          File('../catalog/games/bubble-buddies.json').readAsStringSync())
      as Map<String, dynamic>;
  data['screenshot'] = null;
  data['media'] = <String, dynamic>{};
  final game = CatalogGame.fromJson(data)!;

  Future<void> card(WidgetTester tester, GameCard card) =>
      tester.pumpWidget(MaterialApp(
          theme: gameNightTheme(),
          home: Scaffold(
              body: Center(child: SizedBox(width: 180, child: card)))));

  testWidgets('outside a room a game this device runs has Play only',
      (tester) async {
    var played = 0;
    await card(
        tester,
        GameCard(
            game: game,
            onOpen: () {},
            playsHere: true,
            onPlay: () => played++));
    expect(find.byKey(const ValueKey('card-queue')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('card-play')));
    expect(played, 1);
  });

  testWidgets('outside a room other games have no buttons', (tester) async {
    await card(tester, GameCard(game: game, onOpen: () {}));
    expect(find.byKey(const ValueKey('card-play')), findsNothing);
  });

  testWidgets('in a room a playable game has Play and Queue', (tester) async {
    var played = 0, queued = 0;
    await card(
        tester,
        GameCard(
            game: game,
            onOpen: () {},
            inRoom: true,
            playable: true,
            playsHere: true,
            onPlay: () => played++,
            onAdd: () => queued++));
    await tester.tap(find.byKey(const ValueKey('card-play')));
    await tester.tap(find.byKey(const ValueKey('card-queue')));
    expect((played, queued), (1, 1));
  });

  testWidgets('a game the room has but cannot start says why', (tester) async {
    await card(
        tester,
        GameCard(
            game: game,
            onOpen: () {},
            inRoom: true,
            unavailable: 'Needs 2 players'));
    expect(find.text('Needs 2 players'), findsOneWidget);
    expect(find.byKey(const ValueKey('card-play')), findsNothing);
    await card(tester, GameCard(game: game, onOpen: () {}, inRoom: true));
    expect(find.text('Not on this Splitscreen Club'), findsOneWidget);
  });
}
