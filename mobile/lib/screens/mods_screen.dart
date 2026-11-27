import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../assistant.dart';
import '../app_update.dart';
import '../layout.dart';
import '../link.dart';
import '../room_controls.dart';
import '../storage/own_games.dart';
import '../storage/phone_store.dart';
import '../theme.dart';
import 'host_screen.dart';
import '../api.dart' show ApiError;
import '../widgets/email_sign_in.dart';

/// The games a mod can be made of: Warp games in Luau, which a host copies
/// into the player's drive and Claude changes while they play.
const moddableGames = {'neon-siege-warp': 'Neon Siege'};

/// What a new game ("Make a game") starts from: Warp's templates, which a
/// host with the Warp runtime writes for it. A game is a mod of one of these.
const gameTemplates = {
  'warp-template-platformer': (
    title: 'Platformer',
    about: 'Coin Climb: race up ledges for coins, 1 to 4 players.'
  ),
  'warp-template-fps': (
    title: 'Shooter',
    about: 'Frag Yard: a first-person deathmatch in split screen, with bots.'
  ),
  'warp-template-blank': (
    title: 'Blank',
    about: 'Almost nothing yet: say what it should become.'
  ),
};

/// The template that fits what the player described: a shooter or a
/// platformer when their words say so, otherwise the plain starter.
String startFor(String idea) {
  final words = idea.toLowerCase();
  bool any(List<String> keys) => keys.any(words.contains);
  if (any([
    'shoot',
    'gun',
    'fps',
    'deathmatch',
    'first-person',
    'first person',
    'schiet'
  ])) {
    return 'warp-template-fps';
  }
  if (any(['platform', 'jump', 'climb', 'coins', 'munten', 'spring'])) {
    return 'warp-template-platformer';
  }
  return 'warp-template-blank';
}

/// A first name for a game: the start of what the player described.
String titleFor(String idea) {
  final words = idea
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .split(' ')
      .where((w) => w.isNotEmpty)
      .take(4)
      .toList();
  if (words.isEmpty) return 'My game';
  final title = words.join(' ');
  final cut = title.length > 40 ? title.substring(0, 40).trim() : title;
  return cut[0].toUpperCase() + cut.substring(1);
}

/// Whether this mod is a game of the player's own, made from a template.
bool isOwnGame(GameMod mod) => gameTemplates.containsKey(mod.base);

String _baseTitle(String base) =>
    moddableGames[base] ?? gameTemplates[base]?.title ?? gameTitle(base);

String _origin(GameMod mod) => isOwnGame(mod)
    ? 'Your game, started as ${_baseTitle(mod.base)}'
    : 'Mod of ${_baseTitle(mod.base)}';

/// What the room this phone plays in has of a mod right now.
class _Room {
  final Set<String> shelf;
  final String? playing;
  const _Room(this.shelf, this.playing);
  static const none = _Room({}, null);
}

Future<_Room?> _room(AppState state) async {
  final controls = roomControlsFor(state);
  if (controls == null) return null;
  try {
    final games = await controls.games();
    final playlist = await controls.playlist();
    return _Room({for (final g in games) g.id}, playlist.playing);
  } catch (_) {
    return _Room.none;
  }
}

String _status(GameMod mod, _Room? room) {
  if (room == null) return 'Join a room to play it';
  if (room.playing == mod.game) return 'Playing now';
  if (room.shelf.contains(mod.game)) return 'On the shelf';
  if (isOwnGame(mod)) {
    return 'Waiting for the host to set it up (it needs the Warp runtime)';
  }
  return 'Waiting for the host to make it from ${_baseTitle(mod.base)}';
}

/// The player's own mods: copies of a game in their account that Claude
/// changes on request while they play, and that go wherever they sit.
class ModsScreen extends StatefulWidget {
  final AppState state;
  const ModsScreen({super.key, required this.state});

  static Future<void> open(BuildContext context, AppState state) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'mods'),
          builder: (_) => ModsScreen(state: state)));

  @override
  State<ModsScreen> createState() => _ModsScreenState();
}

class _ModsScreenState extends State<ModsScreen> {
  List<GameMod>? _mods;
  _Room? _roomNow;
  String? _error;
  Timer? _timer;

  OwnGames? get _store => OwnGames.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh(sync: true));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool sync = false}) async {
    final store = _store;
    if (store == null || !store.signedIn) return;
    try {
      if (sync) await store.syncNow();
      final mods = [
        for (final m in await store.mods())
          if (!isOwnGame(m)) m
      ];
      final room = await _room(widget.state);
      if (!mounted) return;
      setState(() {
        _mods = mods;
        _roomNow = room;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _new() async {
    final made = await showDialog<(String, String)>(
        context: context, builder: (_) => const _NewModDialog());
    final store = _store;
    if (made == null || store == null) return;
    try {
      final id = await store.newMod(made.$1, made.$2);
      await _refresh();
      if (!mounted) return;
      final mod = _mods?.where((m) => m.id == id).firstOrNull;
      if (mod != null) await ModScreen.open(context, widget.state, mod);
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final children = <Widget>[];
    if (store == null) {
      children.add(const GetTheApp());
    } else if (!store.signedIn) {
      children.add(const Hint(
          'Sign in to make mods. They are kept in your account, so you can play them wherever you sit.'));
    } else {
      children.add(const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Hint(
            'A mod is your own copy of a game. Play it and tell the Assistant what should change: '
            'it changes the code while you play, and the mod stays in your account.'),
      ));
      if (_error != null) {
        children
            .add(Text(_error!, style: const TextStyle(color: GnColors.warn)));
      }
      final mods = _mods;
      if (mods == null) {
        children.add(const Hint('Loading…'));
      } else if (mods.isEmpty) {
        children.add(const Hint('No mods yet.'));
      }
      for (final mod in mods ?? const <GameMod>[]) {
        children.add(Card(
          child: ListTile(
            key: ValueKey('mod-${mod.id}'),
            leading: const Icon(Icons.extension_outlined),
            title: Text(mod.title),
            subtitle: Text('${_origin(mod)} · ${_status(mod, _roomNow)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ModScreen.open(context, widget.state, mod);
              await _refresh();
            },
          ),
        ));
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Mods')),
      floatingActionButton: store != null && store.signedIn
          ? FloatingActionButton.extended(
              key: const ValueKey('new-mod'),
              onPressed: _new,
              icon: const Icon(Icons.add),
              label: const Text('New mod'))
          : null,
      body: ContentWidth(
        child: RefreshIndicator(
          onRefresh: () => _refresh(sync: true),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: children),
        ),
      ),
    );
  }
}

class _NewModDialog extends StatefulWidget {
  const _NewModDialog();
  @override
  State<_NewModDialog> createState() => _NewModDialogState();
}

class _NewModDialogState extends State<_NewModDialog> {
  String _base = moddableGames.keys.first;
  late final _name =
      TextEditingController(text: 'My ${_baseTitle(moddableGames.keys.first)}');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New mod'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _base,
            decoration: const InputDecoration(labelText: 'Game'),
            items: [
              for (final e in moddableGames.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value))
            ],
            onChanged: (v) => setState(() => _base = v ?? _base),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('mod-name'),
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('make-mod'),
              onPressed: () {
                final name = _name.text.trim();
                if (name.isNotEmpty) Navigator.pop(context, (_base, name));
              },
              child: const Text('Make')),
        ],
      );
}

/// One game of the player's own (or a mod): a chat with the Assistant that
/// builds it, its progress live, and a big Play button. Works with or
/// without a room: when the game runs in the player's room, the Assistant
/// changes it live there (and can look at it); otherwise it builds it in
/// the player's account, ready for the next room.
class ModScreen extends StatefulWidget {
  final AppState state;
  final GameMod mod;

  /// For a game just made: what the player wants it to become, sent as the
  /// first message right away.
  final String? idea;
  const ModScreen(
      {super.key, required this.state, required this.mod, this.idea});

  static Future<void> open(BuildContext context, AppState state, GameMod mod,
          {String? idea}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'mod'),
          builder: (_) => ModScreen(state: state, mod: mod, idea: idea)));

  @override
  State<ModScreen> createState() => _ModScreenState();
}

class _ModScreenState extends State<ModScreen> {
  late GameMod _mod = widget.mod;
  List<ChatEntry> _chat = const [];
  bool _restoring = false;
  _Room? _roomNow;
  Timer? _timer;
  bool _starting = false;
  final _draft = TextEditingController();
  final _scroll = ScrollController();

  /// What the Assistant is doing now: null when idle.
  String? _working;
  List<String> _steps = const [];
  String? _error;
  Assistant? _live;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh().then((_) => _resume()));
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    final idea = widget.idea?.trim() ?? '';
    if (idea.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(idea));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.dispose();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final store = OwnGames.instance;
    if (store == null) return;
    final mods = await store.mods();
    final room = await _room(widget.state);
    final mod = mods.where((m) => m.id == _mod.id).firstOrNull;
    List<ChatEntry>? chat;
    try {
      chat = await store.chat(_mod.id);
    } catch (error) {
      debugPrint('Could not read the chat: $error');
    }
    if (!mounted) return;
    final grew = chat != null && chat.length != _chat.length;
    setState(() {
      if (mod != null) _mod = mod;
      if (chat != null) _chat = chat;
      _roomNow = room;
    });
    if (grew) _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut);
        }
      });

  bool get _inRoom => _roomNow != null;
  bool get _playing => _roomNow?.playing == _mod.game;
  bool get _onShelf => _roomNow?.shelf.contains(_mod.game) ?? false;

  /// A build the cloud is still doing (say the app was closed meanwhile).
  Future<void> _resume() async {
    try {
      final now = await widget.state.cloud
          .request('GET', '/v1/me/games/${_mod.id}/build');
      if (now is Map && now['state'] == 'working' && mounted) {
        setState(() => _working = 'Working on your game…');
        await _follow(now['id'] as String);
      }
    } catch (_) {/* Nothing running, or offline: the chat is enough. */}
  }

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty || _working != null) return;
    _draft.clear();
    setState(() {
      _error = null;
      _steps = const [];
      _working =
          _playing ? 'Changing it live in your room…' : 'Working on your game…';
    });
    _toEnd();
    try {
      if (_playing) {
        await _sendLive(text);
      } else {
        await _sendBuild(text);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _working = null);
      await _refresh();
    }
  }

  /// The game runs in the player's room: the host changes it with the
  /// game's own live tools, and the chat follows the Assistant's requests.
  Future<void> _sendLive(String text) async {
    final live = _live ??= Assistant(widget.state.cloud);
    await live.refresh();
    live.setDraft(text);
    await live.send();
    if (live.error case final error?) throw error;
    while (mounted && live.waiting) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await live.refresh();
    }
  }

  /// No room (or the game is not running there): the cloud builds it in
  /// the player's account. The question goes in the chat now, the answer
  /// when it is done.
  Future<void> _sendBuild(String text) async {
    final store = OwnGames.instance;
    if (store == null) throw 'Your games are not on this phone yet.';
    await store.addChat(_mod.id, 'user', text);
    await _refresh();
    final id = assistantId();
    // A game just made reaches the account on the next sync.
    for (var attempt = 0;; attempt++) {
      try {
        await widget.state.cloud
            .request('POST', '/v1/me/games/${_mod.id}/build', body: {
          'request_id': id,
          'text': text
        }, errors: {
          409: 'The Assistant is still working on your last request.',
          503: 'The Assistant is not available right now.',
        });
        break;
      } on ApiError catch (error) {
        if (error.status != 404 || attempt >= 4) {
          await store.addChat(_mod.id, 'assistant', error.message, ok: false);
          rethrow;
        }
        await store.syncNow();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    await _follow(id);
  }

  Future<void> _follow(String id) async {
    final store = OwnGames.instance;
    while (mounted) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final now = await widget.state.cloud
          .request('GET', '/v1/me/games/${_mod.id}/build');
      if (now is! Map || now['id'] != id) return;
      final steps = [
        for (final s in now['steps'] as List? ?? []) '${(s as Map)['text']}'
      ];
      if (mounted) setState(() => _steps = steps);
      if (now['state'] != 'working') {
        final ok = now['state'] == 'complete';
        await store?.addChat(
            _mod.id,
            'assistant',
            now['result']?.toString() ??
                (ok ? 'Done.' : 'That did not work. Try again.'),
            ok: ok);
        unawaited(store?.syncNow());
        return;
      }
    }
  }

  Future<void> _play() async {
    if (!_inRoom) return _whereToPlay();
    final controls = roomControlsFor(widget.state);
    if (controls == null) return;
    setState(() => _starting = true);
    try {
      await controls.playNext(_mod.game, start: true);
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Not in a room: host one (this phone, a computer or a TV) or join one.
  Future<void> _whereToPlay() => showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Play your game',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    const Hint(
                        'Your game plays in a room, on a TV or computer, with '
                        'controllers or phones. It is on the shelf of every '
                        'room you join.'),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        key: const ValueKey('play-host'),
                        onPressed: () {
                          Navigator.pop(sheet);
                          unawaited(HostScreen.open(context, widget.state.cloud,
                              project: () =>
                                  playToken(widget.state.cloud, _mod.id)));
                        },
                        icon: const Icon(Icons.tv),
                        label: const Text('Host a room')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        key: const ValueKey('play-join'),
                        onPressed: () {
                          Navigator.pop(sheet);
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          widget.state.showRoomTab?.call();
                        },
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Join a room')),
                  ]),
            ),
          ));

  /// Put the game back as the answer `index` left it. A note goes in the
  /// chat first, so the version from before going back can be found too.
  Future<void> _restore(int index) async {
    final at = versionAfter(_chat, index);
    final store = OwnGames.instance;
    if (at == null || store == null) return;
    final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Go back to this version?'),
              content: const Text(
                  'Your game becomes what it was after this answer. Nothing is lost: you can go back to any later version from the chat too.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Go back')),
              ],
            ));
    if (sure != true) return;
    setState(() => _restoring = true);
    try {
      await store.addChat(_mod.id, 'assistant',
          'Went back to the version after: “${_cutText(_chat[index].text, 80)}”',
          ok: true);
      final changed = await store.restoreMod(_mod.id, at);
      if (mounted) {
        toast(
            context,
            changed == 0
                ? 'It already was that version.'
                : 'Back to that version. A running game picks it up in a moment.');
      }
    } catch (error) {
      if (mounted) toast(context, '$error');
    } finally {
      if (mounted) setState(() => _restoring = false);
      await _refresh();
    }
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: _mod.title);
    final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Rename'),
              content:
                  TextField(controller: name, autofocus: true, maxLength: 80),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, name.text.trim()),
                    child: const Text('Rename')),
              ],
            ));
    name.dispose();
    if (title == null || title.isEmpty || title == _mod.title) return;
    try {
      await OwnGames.instance?.renameMod(_mod.id, title);
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Delete ${_mod.title}?'),
              content: const Text(
                  'It goes off every shelf and out of your account.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: GnColors.danger),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ));
    if (sure != true) return;
    try {
      await OwnGames.instance?.removeMod(_mod.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  /// A new game is playable once the Assistant made its first version (a
  /// mod is a copy of a game that plays already).
  bool get _playable =>
      !isOwnGame(_mod) || _playing || _chat.any((e) => !e.mine && e.ok == true);

  Widget _playBar() {
    if (!_playable) {
      return _working == null
          ? const SizedBox.shrink()
          : const Hint('Play shows up here once the first version is ready.');
    }
    if (_playing) {
      return const Row(children: [
        Icon(Icons.circle, size: 12, color: GnColors.ok),
        SizedBox(width: 8),
        Expanded(
            child: Text('Playing on the TV now. Changes show up live.',
                style: TextStyle(color: GnColors.ok))),
      ]);
    }
    final waiting = _inRoom && !_onShelf;
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
          key: const ValueKey('play-mod'),
          style: FilledButton.styleFrom(
              textStyle:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          onPressed: _starting || waiting ? null : _play,
          icon: _starting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow, size: 28),
          label: Text(waiting
              ? 'Reaching the TV in a moment…'
              : _inRoom
                  ? 'Play on the TV'
                  : 'Play')),
    );
  }

  Widget _workingBubble() => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey('assistant-working'),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: GnColors.field, borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Flexible(child: Text(_working ?? '')),
            ]),
            for (final step
                in _steps.skip(_steps.length > 4 ? _steps.length - 4 : 0))
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 26),
                child: Text(step,
                    style:
                        const TextStyle(color: GnColors.muted, fontSize: 13)),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final empty = _chat.isEmpty && _working == null;
    return Scaffold(
      appBar: AppBar(title: Text(_mod.title), actions: [
        PopupMenuButton<String>(
            onSelected: (v) => v == 'rename' ? _rename() : _delete(),
            itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ]),
      ]),
      body: SafeArea(
        child: ContentWidth(
          maxWidth: 850,
          child: Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _playBar()),
            Expanded(
              child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (empty) ...[
                      const SizedBox(height: 24),
                      Text(
                          isOwnGame(_mod)
                              ? 'What should your game be?'
                              : 'What should change?',
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Hint(_inRoom
                          ? 'The Assistant builds it while you play it on the TV.'
                          : 'The Assistant builds it in your account. Play it in any room.'),
                    ],
                    for (final (i, entry) in _chat.indexed)
                      _ChatBubble(
                          entry: entry,
                          onRestore: !entry.mine &&
                                  entry.ok == true &&
                                  (OwnGames.instance?.canRestore ?? false) &&
                                  versionAfter(_chat, i) != null &&
                                  !_restoring &&
                                  _working == null
                              ? () => _restore(i)
                              : null),
                    if (_working != null) _workingBubble(),
                    if (_error case final error?)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(error,
                              style: const TextStyle(color: GnColors.warn))),
                  ]),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: GnColors.border))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                      key: const ValueKey('game-chat-draft'),
                      controller: _draft,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                          counterText: '',
                          hintText: _chat.isEmpty
                              ? 'Describe your game…'
                              : 'Ask for a change…'),
                      onSubmitted: _send),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                    key: const ValueKey('game-chat-send'),
                    tooltip: 'Send',
                    onPressed:
                        _working != null ? null : () => _send(_draft.text),
                    icon: const Icon(Icons.arrow_upward)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

String _cutText(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// One message in a game's chat: the player's on the right, the Assistant's
/// on the left with, for a change that worked, a way back to that version.
class _ChatBubble extends StatelessWidget {
  final ChatEntry entry;
  final VoidCallback? onRestore;
  const _ChatBubble({required this.entry, this.onRestore});

  @override
  Widget build(BuildContext context) {
    final mine = entry.mine;
    final failed = entry.ok == false;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color:
                mine ? GnColors.accent.withValues(alpha: 0.18) : GnColors.field,
            borderRadius: BorderRadius.circular(12),
            border: failed ? Border.all(color: GnColors.warn) : null,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.text),
            if (failed)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('This change did not work.',
                    style: TextStyle(color: GnColors.warn, fontSize: 12)),
              ),
            if (onRestore != null)
              TextButton.icon(
                  key: ValueKey('restore-${entry.key}'),
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact),
                  onPressed: onRestore,
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Back to this version')),
          ]),
        ),
      ),
    );
  }
}

/// Shown in the browser, where mods cannot be kept: the reason to install
/// the app, with a download for every platform and the visitor's own first.
class GetTheApp extends StatelessWidget {
  final String title;
  final String text;
  const GetTheApp(
      {super.key,
      this.title = 'Make your own games in the app',
      this.text = 'Your own games and mods are made by the Assistant while you '
          'play. They live in the Splitscreen Club app on your phone or '
          'computer, so install it to make one.'});

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    void open(Uri url) =>
        unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
    final android = (
      key: 'get-android',
      label: 'Download for Android',
      icon: Icons.android,
      url: AppUpdate.apk,
      mine: platform == TargetPlatform.android,
    );
    final windows = (
      key: 'get-windows',
      label: 'Download for Windows',
      icon: Icons.desktop_windows_outlined,
      url: Uri.parse('$hostedOrigin/download/Splitscreen-Club-Setup.exe'),
      mine: platform == TargetPlatform.windows,
    );
    final mac = (
      key: 'get-mac',
      label: 'Download for Mac',
      icon: Icons.laptop_mac,
      url: Uri.parse('$hostedOrigin/download/Splitscreen-Club.dmg'),
      mine: platform == TargetPlatform.macOS,
    );
    final links = [android, windows, mac]
      ..sort((a, b) => (b.mine ? 1 : 0) - (a.mine ? 1 : 0));
    return Card(
      key: const ValueKey('get-the-app'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Hint(text),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final link in links)
                link.mine
                    ? FilledButton.icon(
                        key: ValueKey(link.key),
                        onPressed: () => open(link.url),
                        icon: Icon(link.icon, size: 18),
                        label: Text(link.label))
                    : OutlinedButton.icon(
                        key: ValueKey(link.key),
                        onPressed: () => open(link.url),
                        icon: Icon(link.icon, size: 18),
                        label: Text(link.label)),
            ]),
            const SizedBox(height: 10),
            Hint(platform == TargetPlatform.iOS
                ? 'The iPhone app is in testing. Ask for an invite.'
                : 'On iPhone? The app is in testing. Ask for an invite.'),
          ],
        ),
      ),
    );
  }
}

/// Make a game: what it takes, the player's own games, and a new one from
/// a template. The Assistant then builds it while the player plays it.
class MakeGameScreen extends StatefulWidget {
  final AppState state;
  const MakeGameScreen({super.key, required this.state});

  static Future<void> open(BuildContext context, AppState state) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'make-game'),
          builder: (_) => MakeGameScreen(state: state)));

  @override
  State<MakeGameScreen> createState() => _MakeGameScreenState();
}

class _MakeGameScreenState extends State<MakeGameScreen> {
  List<GameMod>? _games;
  _Room? _roomNow;
  String? _error;
  Timer? _timer;

  OwnGames? get _store => OwnGames.instance;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    unawaited(_refresh(sync: true));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _timer?.cancel();
    _idea.dispose();
    super.dispose();
  }

  late bool _wasSignedIn = widget.state.signedIn;

  /// The link in the sign-in email can finish signing in on this page.
  void _onState() {
    if (widget.state.signedIn == _wasSignedIn) return;
    _wasSignedIn = widget.state.signedIn;
    unawaited(_signedIn());
  }

  /// Signed in, but this phone's store never reached the account's drive
  /// (say the hub was unreachable at sign-in): try again here, and say so
  /// when it fails instead of waiting forever.
  bool _connecting = false;
  String? _connectError;
  Future<void> _connect() async {
    final store = _store;
    if (store == null || _connecting || !widget.state.signedIn) return;
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    final error = await store
        .connect(widget.state.cloud)
        .timeout(const Duration(seconds: 30), onTimeout: () => 'timed out');
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _connectError = error == null
          ? null
          : 'Could not reach your saved games. Check your connection and try again.';
    });
    if (error == null) await _refresh(sync: true);
  }

  Future<void> _refresh({bool sync = false}) async {
    final store = _store;
    if (store == null) return;
    if (!store.signedIn) {
      if (widget.state.signedIn && _connectError == null) await _connect();
      return;
    }
    try {
      if (sync) await store.syncNow();
      final games = [
        for (final m in await store.mods())
          if (isOwnGame(m)) m
      ];
      final room = await _room(widget.state);
      if (!mounted) return;
      setState(() {
        _games = games;
        _roomNow = room;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  final _idea = TextEditingController();
  String? _start;
  bool _making = false;

  /// A new game from what the player wrote: the starting point they picked,
  /// or one that fits their words, named after them. The game's chat opens
  /// and sends their words as the first request.
  Future<void> _make() async {
    final idea = _idea.text.trim();
    final store = _store;
    if (idea.isEmpty || store == null || _making) return;
    setState(() => _making = true);
    try {
      final id = await store.newMod(_start ?? startFor(idea), titleFor(idea));
      await store.syncNow();
      await _refresh();
      if (!mounted) return;
      final game = _games?.where((m) => m.id == id).firstOrNull;
      if (game != null) {
        _idea.clear();
        await ModScreen.open(context, widget.state, game, idea: idea);
      }
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  Widget _composer() => Card(
        key: const ValueKey('make-game-chat'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const ValueKey('game-idea'),
              controller: _idea,
              minLines: 2,
              maxLines: 6,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  border: InputBorder.none,
                  counterText: '',
                  hintText: 'Describe the game you want to make…'),
              onChanged: (_) => setState(() {}),
            ),
            Row(children: [
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in gameTemplates.entries)
                    ChoiceChip(
                      key: ValueKey('template-${e.key}'),
                      label: Text(e.value.title),
                      tooltip: e.value.about,
                      selected: _start == e.key,
                      onSelected: (on) =>
                          setState(() => _start = on ? e.key : null),
                    ),
                ]),
              ),
              IconButton.filled(
                  key: const ValueKey('make-game'),
                  tooltip: 'Make it',
                  onPressed:
                      _making || _idea.text.trim().isEmpty ? null : _make,
                  icon: _making
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.arrow_upward)),
            ]),
          ]),
        ),
      );

  Future<void> _signedIn() async {
    if (mounted) setState(() {});
    await _refresh(sync: true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final children = <Widget>[
      const Text('What game do you want to make?',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Hint('Describe it and the Assistant builds it. Play it in any '
          'room, and keep asking for changes. It is kept in your account.'),
      const SizedBox(height: 16),
    ];
    if (!widget.state.signedIn) {
      children.add(Card(
        key: const ValueKey('make-game-sign-in'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: GnColors.accent, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Sign in to make a game',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Hint('Your games are kept in your account.'),
            const SizedBox(height: 14),
            EmailSignIn(state: widget.state, onSignedIn: _signedIn),
          ]),
        ),
      ));
      children.add(const SizedBox(height: 16));
    }
    if (store == null) {
      children.add(const GetTheApp());
    } else if (!store.signedIn) {
      if (widget.state.signedIn) {
        if (_connectError case final error?) {
          children
              .add(Text(error, style: const TextStyle(color: GnColors.warn)));
          children.add(Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  key: const ValueKey('make-game-retry'),
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'))));
        } else {
          children.add(const Hint('Getting your games…'));
        }
      }
    } else if (!widget.state.assistantAvailable) {
      children.add(const Hint(
          'Making games is not open for your account yet. We are letting '
          'people in step by step.'));
    } else {
      children.add(_composer());
      children.add(const SizedBox(height: 8));
      children.add(Wrap(spacing: 8, runSpacing: 8, children: [
        for (final idea in const [
          'Penguins push each other off an ice floe',
          'A racing game with jumps for 4 players',
          'Co-op: defend a castle against waves of slimes',
        ])
          ActionChip(
              label: Text(idea),
              onPressed: () => setState(() => _idea.text = idea)),
      ]));
      children.add(const SizedBox(height: 24));
      if (_error != null) {
        children
            .add(Text(_error!, style: const TextStyle(color: GnColors.warn)));
      }
      final games = _games;
      if (games != null && games.isNotEmpty) {
        children.add(const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('Your games',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ));
      }
      for (final game in games ?? const <GameMod>[]) {
        children.add(Card(
          child: ListTile(
            key: ValueKey('own-game-${game.id}'),
            leading: const Icon(Icons.videogame_asset_outlined),
            title: Text(game.title),
            subtitle: Text(_status(game, _roomNow)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ModScreen.open(context, widget.state, game);
              await _refresh();
            },
          ),
        ));
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Make a game')),
      body: ContentWidth(
        child: RefreshIndicator(
          onRefresh: () => _refresh(sync: true),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: children),
        ),
      ),
    );
  }
}

/// The top of the games catalog for a player who may make games: their own
/// games first, then the way to make a new one.
class MakeGameCard extends StatefulWidget {
  final AppState state;
  const MakeGameCard({super.key, required this.state});

  @override
  State<MakeGameCard> createState() => _MakeGameCardState();
}

class _MakeGameCardState extends State<MakeGameCard> {
  List<GameMod> _games = const [];

  /// The account the games were loaded for: the list waits for the account
  /// (on a fresh page load it often comes after this card), and follows a
  /// change of account.
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_accountChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.state.removeListener(_accountChanged);
    super.dispose();
  }

  void _accountChanged() {
    if (widget.state.cloud.token != _loadedFor) unawaited(_load());
  }

  Future<void> _load() async {
    final store = OwnGames.instance;
    final account = widget.state.cloud.token;
    if (store == null || !store.signedIn || account == null) {
      _loadedFor = null;
      if (_games.isNotEmpty && mounted) setState(() => _games = const []);
      return;
    }
    if (account == _loadedFor) return;
    _loadedFor = account;
    try {
      final games = [
        for (final m in await store.mods())
          if (isOwnGame(m)) m
      ];
      if (mounted) setState(() => _games = games);
    } catch (_) {/* No games shown; making one still works. */}
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_games.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Your games',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          for (final game in _games)
            Card(
              child: ListTile(
                key: ValueKey('own-game-${game.id}'),
                leading:
                    const Icon(Icons.videogame_asset, color: GnColors.accent),
                title: Text(game.title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Made by you'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await ModScreen.open(context, widget.state, game);
                  await _load();
                },
              ),
            ),
        ],
        Card(
          key: const ValueKey('make-a-game'),
          child: ListTile(
            leading: const Icon(Icons.auto_awesome, color: GnColors.accent),
            title: const Text('Make a game',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle:
                const Text('Describe a game and the Assistant builds it.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await MakeGameScreen.open(context, widget.state);
              await _load();
            },
          ),
        ),
      ]);
}
