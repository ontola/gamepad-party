import 'package:flutter/foundation.dart' show kIsWeb;

import '../account.dart';
import 'phone_store.dart';

/// Where a player's own games (and mods) are read and changed: the phone's
/// Atomic store ([PhoneStore]), which syncs with the account's drive, or, in
/// the web app, which has no store, the cloud's copy of that drive
/// ([CloudGames]). Both are the same records, so a game made in one shows
/// in the other.
abstract class OwnGames {
  static OwnGames? _web;

  /// The web app reads its games from `cloud`.
  static void useCloud(CloudApi cloud) {
    if (kIsWeb) _web = CloudGames(cloud);
  }

  static OwnGames? get instance => PhoneStore.instance ?? _web;

  bool get signedIn;

  /// Whether a game can go back to an earlier version here (the phone's
  /// store keeps each file's history).
  bool get canRestore;

  /// Reach the account's games; the error, or null.
  Future<String?> connect(CloudApi cloud);
  Future<bool> syncNow();
  Future<List<GameMod>> mods();
  Future<String> newMod(String base, String title);
  Future<void> renameMod(String id, String title);
  Future<void> removeMod(String id);
  Future<List<ChatEntry>> chat(String id);
  Future<void> addChat(String id, String role, String text, {bool? ok});
  Future<int> restoreMod(String id, DateTime at);
}

/// The account's games through the cloud (`/v1/me/games`), for the web app.
class CloudGames implements OwnGames {
  CloudGames(this.cloud);
  final CloudApi cloud;

  @override
  bool get signedIn => cloud.signedIn;

  @override
  bool get canRestore => false;

  @override
  Future<String?> connect(CloudApi cloud) async => null;

  @override
  Future<bool> syncNow() async => true;

  @override
  Future<List<GameMod>> mods() async {
    final got = await cloud.request('GET', '/v1/me/games');
    return [
      for (final g in (got is Map ? got['games'] as List? : null) ?? const [])
        GameMod.fromJson(g as Map)
    ];
  }

  @override
  Future<String> newMod(String base, String title) async {
    final made = await cloud.request('POST', '/v1/me/games',
        body: {'base': base, 'title': title},
        errors: {403: 'Making games is not open for your account yet.'});
    return (made as Map)['id'] as String;
  }

  @override
  Future<void> renameMod(String id, String title) =>
      cloud.request('PATCH', '/v1/me/games/${Uri.encodeComponent(id)}',
          body: {'title': title});

  @override
  Future<void> removeMod(String id) =>
      cloud.request('DELETE', '/v1/me/games/${Uri.encodeComponent(id)}');

  @override
  Future<List<ChatEntry>> chat(String id) async {
    final got = await cloud.request(
        'GET', '/v1/me/games/${Uri.encodeComponent(id)}/chat');
    return [
      for (final e in (got is Map ? got['entries'] as List? : null) ?? const [])
        ChatEntry.fromJson(e as Map)
    ];
  }

  @override
  Future<void> addChat(String id, String role, String text, {bool? ok}) =>
      cloud.request('POST', '/v1/me/games/${Uri.encodeComponent(id)}/chat',
          body: {'role': role, 'text': text, if (ok != null) 'ok': ok});

  @override
  Future<int> restoreMod(String id, DateTime at) =>
      throw 'Going back to an earlier version works in the phone app.';
}

/// A link a host page plays the player's own game `id` from (12 hours).
Future<String> playToken(CloudApi cloud, String id) async {
  final link = await cloud.request(
      'POST', '/v1/me/games/${Uri.encodeComponent(id)}/link');
  return (link as Map)['token'] as String;
}

/// A link that tells a host page whose room it is (12 hours): the
/// signed-in player's own profile hosts it, so their phone sees the room.
Future<String> hostToken(CloudApi cloud) async {
  final link = await cloud.request('POST', '/v1/me/host-link');
  return (link as Map)['token'] as String;
}
