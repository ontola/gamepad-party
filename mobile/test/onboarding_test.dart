import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/link.dart';
import 'package:gamenight/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hosted room nobody has pressed A in yet: the phone waits for a player.
class EmptyRoom {
  String status = 'waiting';
  Map<String, dynamic>? profile;
  Map<String, dynamic> get room => {
        'status': status,
        'guest': true,
        'room_code': 'ABC234',
        'players': status == 'connected' ? 1 : 0,
        'fresh': true,
        'seat': status == 'connected'
            ? {'index': 0, 'player': 'player-0', 'revision': 0}
            : null,
        'seats': [],
        'discovery': {
          'games': [],
          'playlist': {'entries': []}
        },
      };
  MockClient client() => MockClient((r) async {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/rooms/guest':
            return http.Response(
                jsonEncode(
                    {'token': 'room-token', 'status': room, 'profile': {}}),
                200);
          case 'PUT /v1/rooms/guest/profile':
            profile = jsonDecode(r.body) as Map<String, dynamic>;
            return http.Response('{}', 200);
          case 'GET /v1/rooms/status':
            return http.Response(jsonEncode(room), 200);
          case 'GET /v1/rooms/companion':
            return http.Response('{}', 200);
          case 'GET /auth/session':
            return http.Response('{}', 401);
        }
        return http.Response('{}', 404);
      });
}

final _preview = GlobalKey();
final _previewDirectory = Platform.environment['ONBOARDING_PREVIEW_DIR'];

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = _previewDirectory;
  if (directory == null) return;
  await tester.pump();
  final boundary =
      _preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Platform.environment['ONBOARDING_PREVIEW_FONTS'];
    if (fonts == null) return;
    final roboto = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(File('$fonts/Roboto-$weight.ttf')
          .readAsBytes()
          .then(ByteData.sublistView));
    }
    await roboto.load();
    final outfit = FontLoader('Outfit');
    for (final weight in [400, 500, 600, 700, 800]) {
      outfit.addFont(rootBundle.load('assets/fonts/Outfit-$weight.ttf'));
    }
    await outfit.load();
    final bungee = FontLoader('Bungee')
      ..addFont(rootBundle.load('assets/fonts/Bungee-Regular.ttf'));
    await bungee.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('a new player is told to press A, then meets their player',
      (tester) async {
    SharedPreferences.setMockInitialValues({'chose_name': true});
    final server = EmptyRoom();
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(client: server.client()));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
        key: _preview,
        child: GameNightApp(
            state: state,
            initialLink: Uri.parse('$hostedOrigin/app/?room=ABC234'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('press-a')), findsOneWidget);
    expect(find.text('Grab a controller\nand press A'), findsOneWidget);
    expect(find.byKey(const ValueKey('meet-player')), findsNothing);
    await _capture(tester, 'press-a');

    // Someone pressed A and took this phone's player.
    server.status = 'connected';
    await state.refreshHostedRoom();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('press-a')), findsNothing);
    expect(find.byKey(const ValueKey('meet-player')), findsOneWidget);
    expect(find.text('This is you on the TV'), findsOneWidget);
    await _capture(tester, 'meet-player');

    await tester.enterText(
        find.byKey(const ValueKey('meet-player-name')), 'Joep');
    await tester.pump();
    expect(state.name, 'Joep');
    await tester.tap(find.text('Looks good'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('meet-player')), findsNothing);
    expect(state.metPlayer, isTrue);
    await _capture(tester, 'after-banner');
    expect(tester.takeException(), isNull);
    state.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
