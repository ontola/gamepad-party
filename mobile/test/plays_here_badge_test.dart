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

  Future<void> card(WidgetTester tester, {required bool playsHere}) =>
      tester.pumpWidget(MaterialApp(
          theme: gameNightTheme(),
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 160,
                      child: GameCard(
                          game: game, onOpen: () {}, playsHere: playsHere))))));

  testWidgets('a game this device runs gets the purple play badge',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await card(tester, playsHere: true);
    expect(find.byKey(const ValueKey('plays-here')), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byTooltip('Plays on this tablet'), findsOneWidget);
  });

  testWidgets('other games have no badge', (tester) async {
    await card(tester, playsHere: false);
    expect(find.byKey(const ValueKey('plays-here')), findsNothing);
  });

  testWidgets('a game the room has but cannot start says why', (tester) async {
    Future<void> room({String? unavailable}) => tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 160,
                    child: GameCard(
                        game: game,
                        onOpen: () {},
                        inRoom: true,
                        playsHere: true,
                        unavailable: unavailable))))));
    await room(unavailable: 'Needs 2 players');
    expect(find.text('Needs 2 players'), findsOneWidget);
    expect(find.text('Not on this Splitscreen Club'), findsNothing);
    await room();
    expect(find.text('Not on this Splitscreen Club'), findsOneWidget);
  });
}
