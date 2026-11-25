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
import '../storage/phone_store.dart';
import '../theme.dart';
import 'assistant_screen.dart';
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

  PhoneStore? get _store => PhoneStore.instance;

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

/// One mod: play it, ask for a change while it runs, see what changed,
/// rename or delete it.
class ModScreen extends StatefulWidget {
  final AppState state;
  final GameMod mod;

  /// For a game just made: what the player wants it to become, the first
  /// request for the Assistant.
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
  late String? _idea = widget.idea;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final store = PhoneStore.instance;
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
    setState(() {
      if (mod != null) _mod = mod;
      if (chat != null) _chat = chat;
      _roomNow = room;
    });
  }

  /// Put the game back as the answer `index` left it. A note goes in the
  /// chat first, so the version from before going back can be found too.
  Future<void> _restore(int index) async {
    final at = versionAfter(_chat, index);
    final store = PhoneStore.instance;
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

  bool get _playing => _roomNow?.playing == _mod.game;

  Future<void> _play() async {
    final controls = roomControlsFor(widget.state);
    if (controls == null) return;
    setState(() => _starting = true);
    try {
      await controls.playNext(_mod.game, start: true);
    } catch (error) {
      if (mounted) toast(context, '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Changing a mod is what the Assistant does: ask it while the mod runs.
  Future<void> _assistant() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'assistant'),
        builder: (_) =>
            AssistantScreen(state: widget.state, initialDraft: _idea)));
    _idea = null;
    await _refresh();
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: _mod.title);
    final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Rename mod'),
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
      await PhoneStore.instance?.renameMod(_mod.id, title);
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
      await PhoneStore.instance?.removeMod(_mod.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = _roomNow;
    final onShelf = room?.shelf.contains(_mod.game) ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(_mod.title), actions: [
        IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _rename),
        IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete),
      ]),
      body: ContentWidth(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('${_origin(_mod)} · ${_status(_mod, room)}',
              style: const TextStyle(color: GnColors.muted)),
          const SizedBox(height: 12),
          if (!_playing && onShelf)
            FilledButton.icon(
                key: const ValueKey('play-mod'),
                onPressed: _starting ? null : _play,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play now')),
          const SizedBox(height: 20),
          Hint(isOwnGame(_mod)
              ? (_playing
                  ? 'Tell the Assistant what your game should be or what should change: it writes the code while you play, and keeps it in your account.'
                  : 'Play your game, then tell the Assistant what it should become.')
              : (_playing
                  ? 'Tell the Assistant what should change: it changes the code while you play, and keeps it in your mod.'
                  : 'Play your mod, then tell the Assistant what should change.')),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
                key: const ValueKey('mod-assistant'),
                onPressed: _assistant,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Assistant')),
          ),
          if (_chat.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('Chat',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            for (final (i, entry) in _chat.indexed)
              _ChatBubble(
                  entry: entry,
                  onRestore: !entry.mine &&
                          entry.ok == true &&
                          versionAfter(_chat, i) != null &&
                          !_restoring
                      ? () => _restore(i)
                      : null),
          ] else if (_mod.changes.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('Changes',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            for (final change in _mod.changes.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    change.ok
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: change.ok ? GnColors.ok : GnColors.warn),
                title: Text(change.asked),
                subtitle: Text(change.answer),
              ),
          ],
        ]),
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

  PhoneStore? get _store => PhoneStore.instance;
  bool get _ready =>
      _store != null && _store!.signedIn && widget.state.assistantAvailable;

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

  Future<void> _new() async {
    final made = await showDialog<({String base, String name, String idea})>(
        context: context, builder: (_) => const _NewGameDialog());
    final store = _store;
    if (made == null || store == null) return;
    try {
      final id = await store.newMod(made.base, made.name);
      await _refresh();
      if (!mounted) return;
      final game = _games?.where((m) => m.id == id).firstOrNull;
      if (game != null) {
        await ModScreen.open(context, widget.state, game,
            idea: made.idea.isEmpty ? null : made.idea);
      }
      await _refresh();
    } catch (error) {
      if (mounted) toast(context, '$error');
    }
  }

  Future<void> _signedIn() async {
    if (mounted) setState(() {});
    await _refresh(sync: true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final children = <Widget>[
      const Text('Make your own game',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Hint(
          'Pick a starting point and say what your game should be. Play it on '
          'the TV while the Assistant writes the code, and ask for changes as '
          'you go.'),
      const SizedBox(height: 12),
      const _HowItWorks(),
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
      floatingActionButton: _ready
          ? FloatingActionButton.extended(
              key: const ValueKey('new-game'),
              onPressed: _new,
              icon: const Icon(Icons.add),
              label: const Text('New game'))
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

/// The short version of what making a game takes.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: GnColors.muted),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ]),
        );
    return Card(
      key: const ValueKey('make-game-how'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row(Icons.person_outline,
              'You need an account. Your games are kept in it.'),
          row(
              Icons.toll_outlined,
              'The Assistant uses AI tokens for every change, and they run '
              'out. Ask for a few big changes rather than many small ones.'),
          row(
              Icons.tv,
              'Join a room on a computer with Splitscreen Club. Your game '
              'shows up on its shelf, and you play it there while it is made.'),
          row(
              Icons.ios_share,
              'When you are done, your game is saved. Play it wherever you '
              'sit, and share it with others.'),
        ]),
      ),
    );
  }
}

class _NewGameDialog extends StatefulWidget {
  const _NewGameDialog();
  @override
  State<_NewGameDialog> createState() => _NewGameDialogState();
}

class _NewGameDialogState extends State<_NewGameDialog> {
  String _base = gameTemplates.keys.first;
  final _name = TextEditingController(text: 'My game');
  final _idea = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _idea.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New game'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in gameTemplates.entries)
              RadioListTile<String>(
                key: ValueKey('template-${e.key}'),
                contentPadding: EdgeInsets.zero,
                value: e.key,
                // ignore: deprecated_member_use
                groupValue: _base,
                // ignore: deprecated_member_use
                onChanged: (v) => setState(() => _base = v ?? _base),
                title: Text(e.value.title),
                subtitle: Text(e.value.about),
              ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('game-name'),
              controller: _name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              key: const ValueKey('game-idea'),
              controller: _idea,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                  labelText: 'What should it be? (optional)',
                  hintText: 'Four penguins push each other off an ice floe'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('make-game'),
              onPressed: () {
                final name = _name.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context,
                      (base: _base, name: name, idea: _idea.text.trim()));
                }
              },
              child: const Text('Make')),
        ],
      );
}

/// The way into Make a game, at the top of the games catalog.
class MakeGameCard extends StatelessWidget {
  final AppState state;
  const MakeGameCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Card(
        key: const ValueKey('make-a-game'),
        child: ListTile(
          leading: const Icon(Icons.auto_awesome, color: GnColors.accent),
          title: const Text('Make a game',
              style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text(
              'Describe a game, play it while the Assistant builds it.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => MakeGameScreen.open(context, state),
        ),
      );
}
