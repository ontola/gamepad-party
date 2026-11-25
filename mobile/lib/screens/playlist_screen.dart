import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import '../layout.dart';
import 'game_detail_screen.dart';
import 'settings_panel.dart';

/// Tonight's queue: drag to reorder, remove, or replay an earlier game. A tap
/// on a game opens it: start it now, change its settings or see it in the
/// store.
class PlaylistScreen extends StatefulWidget {
  final AppState state;
  final VoidCallback onJoin;
  const PlaylistScreen({super.key, required this.state, required this.onJoin});

  /// The whole playlist as its own page over the room.
  static Future<void> open(BuildContext context, AppState state) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (context) => Scaffold(
              appBar: AppBar(),
              body: PlaylistScreen(
                  state: state, onJoin: () => Navigator.of(context).pop()))));

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  PlaylistView? _view;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  AppState get state => widget.state;
  bool get _linked => state.inHostedRoom
      ? state.hostedRoom?.connected ?? false
      : state.session?.linked ?? false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = roomControlsFor(state);
    if (api == null || !_linked || _busy) return;
    try {
      final view = await api.playlist();
      if (mounted && !_busy) {
        setState(() {
          _view = view;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _edit(
      Future<PlaylistView> Function(RoomControls api, PlaylistView view) change,
      {PlaylistView? optimistic}) async {
    final api = roomControlsFor(state), view = _view;
    if (api == null || view == null || _busy) return;
    setState(() {
      _busy = true;
      if (optimistic != null) _view = optimistic;
    });
    try {
      final next = await change(api, view);
      if (mounted) setState(() => _view = next);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _view = view);
        toast(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (!_linked) {
          return ListView(padding: const EdgeInsets.all(16), children: [
            Section(title: 'Tonight’s playlist', children: [
              const Hint('Join a room to see and change its playlist.'),
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: widget.onJoin, child: const Text('Join a room')),
            ]),
          ]);
        }
        if (_view == null) {
          unawaited(_load());
          return Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Hint(_error!));
        }
        return ContentWidth(maxWidth: 1040, child: _list(_view!));
      },
    );
  }

  Widget _list(PlaylistView view) {
    final start = view.current ?? 0;
    final upcoming = [for (var i = start; i < view.entries.length; i++) i];
    final past = [for (var i = 0; i < start; i++) i];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(children: [
          const Expanded(
            child: Text('Tonight’s playlist',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          if (_busy)
            const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 4),
        Hint(view.entries.isEmpty
            ? 'No games queued yet.'
            : 'Drag to reorder. Tap a game for options.'),
        const SizedBox(height: 8),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) {
            final a = upcoming[from];
            final b = upcoming[to];
            if (a == b || a == view.current || b == view.current) return;
            _edit((api, v) => api.movePlaylistEntry(v, a, b));
          },
          children: [
            for (final (row, i) in upcoming.indexed)
              _row(view, i, row, key: ValueKey('${view.entries[i].game}-$i')),
          ],
        ),
        if (past.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Previous games'),
            children: [for (final i in past) _pastRow(view, i)],
          ),
      ],
    );
  }

  Widget _row(PlaylistView view, int i, int row, {required Key key}) {
    final entry = view.entries[i];
    final playing = view.current == i;
    final upcoming = (view.current ?? -1) + 1;
    final badges = [
      if (playing) 'Playing',
      if (view.next == entry.game && !playing) 'Up next',
      if (!playing) i < upcoming + view.queued ? 'Queued' : 'Autoplay',
    ];
    return Card(
      key: key,
      child: ListTile(
        onTap: () => _open(view, i),
        leading: playing
            ? const Icon(Icons.play_circle, color: GnColors.ok)
            : ReorderableDragStartListener(
                index: row,
                enabled: !_busy,
                child: const Icon(Icons.drag_indicator, color: GnColors.muted),
              ),
        title: Text(entry.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: badges.isEmpty ? null : Text(badges.join(' · ')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          GameSettingsButton(
              state: state,
              game: entry.game,
              title: entry.title,
              playing: playing),
          if (!playing)
            IconButton(
              tooltip: 'Remove ${entry.title}',
              icon: const Icon(Icons.close),
              onPressed: _busy ? null : () => _remove(i),
            ),
        ]),
      ),
    );
  }

  void _remove(int i) => _edit((api, v) => api.removePlaylistEntry(v, i));

  Widget _pastRow(PlaylistView view, int i) {
    final entry = view.entries[i];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _open(view, i),
      title: Text(entry.title, style: const TextStyle(color: GnColors.muted)),
      trailing: TextButton(
        onPressed: _busy ? null : () => _play(entry),
        child: const Text('+ Queue'),
      ),
    );
  }

  /// Play [entry] now, or add it to the players' queue.
  Future<void> _play(PlaylistEntry entry, {bool start = false}) async {
    final controls = roomControlsFor(state);
    if (controls == null) return;
    setState(() => _busy = true);
    try {
      if (start) {
        await controls.playNext(entry.game, start: true);
      } else {
        await controls.addToQueue(entry.game);
      }
      if (mounted) {
        toast(
            context,
            start
                ? '${entry.title} starts as soon as it has loaded'
                : '${entry.title} is in the queue');
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  void _open(PlaylistView view, int i) {
    final entry = view.entries[i];
    final status = entryStatus(view, i);
    final playing = status == EntryStatus.playing;
    final current = view.current == null ? null : view.entries[view.current!];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => PlaylistGameSheet(
        entry: entry,
        status: status,
        controls: roomControlsFor(state),
        playingTitle: playing ? null : current?.title,
        onStart: () {
          Navigator.of(sheet).pop();
          _play(entry, start: true);
        },
        onQueue: () {
          Navigator.of(sheet).pop();
          _play(entry);
        },
        onRemove: status != EntryStatus.playing && status != EntryStatus.played
            ? () {
                Navigator.of(sheet).pop();
                _remove(i);
              }
            : null,
      ),
    );
  }
}

/// [queued] games a player picked; [autoplay] ones the host picked.
enum EntryStatus { playing, upNext, queued, autoplay, played }

/// Where entry [i] stands in [view].
EntryStatus entryStatus(PlaylistView view, int i) {
  final upcoming = (view.current ?? -1) + 1;
  if (view.current == i) return EntryStatus.playing;
  if (view.next == view.entries[i].game) return EntryStatus.upNext;
  if (i < upcoming) return EntryStatus.played;
  return i < upcoming + view.queued ? EntryStatus.queued : EntryStatus.autoplay;
}

/// What a game says when it has no settings to show (yet).
String noSettingsHint(String title, {required bool playing}) => playing
    ? 'This game has no settings to change.'
    : '$title has not shared its settings with this Splitscreen Club yet. '
        'They show up here once it has loaded one time.';

/// The settings of one game, current or still in the queue, in a sheet:
/// its buttons (only while it plays), your own settings, then the room's.
Future<void> showGameSettings(BuildContext context, AppState state,
    {String? game, required String title, bool playing = false}) {
  final controls = roomControlsFor(state);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (playing && controls != null)
            GameActionsSection(
                key: const ValueKey('game-actions'), controls: controls),
          if (controls != null)
            MySettingsSection(
                key: ValueKey('my-settings-${game ?? ''}'),
                controls: controls,
                game: game,
                store: PhoneSettingsStore(state.prefs),
                signedIn: state.signedIn),
          SettingsSection(
              key: ValueKey('settings-${game ?? ''}'),
              controls: controls,
              game: game,
              title: title,
              showEmpty: true,
              emptyHint: noSettingsHint(title, playing: playing)),
        ]),
      ),
    ),
  );
}

/// The gear next to a game: opens its settings. Shown only once the game
/// is known to have something to set (room settings, your own, or buttons
/// while it plays), and never for guests or phones that cannot change the
/// room.
class GameSettingsButton extends StatefulWidget {
  final AppState state;
  final String? game;
  final String title;
  final bool playing;
  const GameSettingsButton(
      {super.key,
      required this.state,
      required this.game,
      required this.title,
      this.playing = false});

  @override
  State<GameSettingsButton> createState() => _GameSettingsButtonState();
}

class _GameSettingsButtonState extends State<GameSettingsButton> {
  bool _has = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    // A game shares its settings once it loads: look again until it has.
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_has) _check();
    });
  }

  @override
  void didUpdateWidget(GameSettingsButton old) {
    super.didUpdateWidget(old);
    if (old.game != widget.game || old.playing != widget.playing) {
      _has = false;
      _check();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final controls = roomControlsFor(widget.state);
    if (controls == null || widget.state.isGuest) return;
    final game = widget.game;
    var has = false;
    try {
      has = await controls.settings(game: game) != null ||
          await controls.playerSettings(game: game) != null;
      if (!has && widget.playing) {
        final actions = await controls.actions();
        has = actions != null &&
            actions.actions.isNotEmpty &&
            (game == null || actions.game == game);
      }
    } catch (_) {
      return; // Keep what we showed; the next check tries again.
    }
    if (mounted && game == widget.game && has != _has) {
      setState(() => _has = has);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_has ||
        widget.state.isGuest ||
        roomControlsFor(widget.state) == null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: ValueKey('settings-button-${widget.game ?? ''}'),
      tooltip: '${widget.title} settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => showGameSettings(context, widget.state,
          game: widget.game, title: widget.title, playing: widget.playing),
    );
  }
}

/// A small square picture of a game: its icon from the store, else its
/// cover, else a tile in its colour with its first letter.
class GameThumbnail extends StatelessWidget {
  final CatalogGame? game;
  final String title;
  final double size;
  const GameThumbnail(
      {super.key, required this.game, required this.title, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final game = this.game;
    Widget letter([BuildContext? _, Object? __, StackTrace? ___]) => ColoredBox(
          color: game?.color ??
              HSLColor.fromAHSL(1, (title.hashCode % 360).toDouble(), 0.45, 0.4)
                  .toColor(),
          child: Center(
            child: Text(
                title.isEmpty ? '?' : title.characters.first.toUpperCase(),
                style: TextStyle(
                    fontSize: size * 0.45,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
        );
    final icon = game?.icon;
    final Widget image;
    if (icon?.bytes != null) {
      image = Image.memory(icon!.bytes!,
          fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: letter);
    } else if (icon?.url != null) {
      image = Image.network(icon!.url.toString(),
          fit: BoxFit.cover, errorBuilder: letter);
    } else if (game?.coverBytes != null) {
      image = Image.memory(game!.coverBytes!,
          fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: letter);
    } else if (game?.coverUrl != null) {
      image = Image.network(game!.coverUrl.toString(),
          fit: BoxFit.cover, errorBuilder: letter);
    } else {
      image = letter();
    }
    return Semantics(
      label: title,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: SizedBox.square(dimension: size, child: image),
      ),
    );
  }
}

/// One game from the playlist: start it now, make it the next game, change
/// its settings, or open its store page.
class PlaylistGameSheet extends StatefulWidget {
  final PlaylistEntry entry;
  final EntryStatus status;
  final RoomControls? controls;

  /// The game on screen, when it is another one: starting ends it.
  final String? playingTitle;

  final VoidCallback onStart;
  final VoidCallback onQueue;
  final VoidCallback? onRemove;

  const PlaylistGameSheet({
    super.key,
    required this.entry,
    required this.status,
    required this.controls,
    this.playingTitle,
    required this.onStart,
    required this.onQueue,
    this.onRemove,
  });

  @override
  State<PlaylistGameSheet> createState() => _PlaylistGameSheetState();
}

class _PlaylistGameSheetState extends State<PlaylistGameSheet> {
  bool _opening = false;

  PlaylistEntry get entry => widget.entry;

  Future<void> _start() async {
    final other = widget.playingTitle;
    if (other != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Play ${entry.title} now?'),
          content: Text(
              'This ends $other for everyone as soon as ${entry.title} has loaded.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialog).pop(false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(dialog).pop(true),
                child: const Text('Play now')),
          ],
        ),
      );
      if (ok != true) return;
    }
    widget.onStart();
  }

  Future<void> _store() async {
    final controls = widget.controls;
    setState(() => _opening = true);
    try {
      final games = await Catalog.instance.games();
      final game = games.where((g) => g.id == entry.game).firstOrNull;
      if (!mounted) return;
      if (game == null) {
        toast(context, '${entry.title} has no page in the store.');
        return;
      }
      // Like the Games tab: in the room, games the host has can be queued again.
      final host = controls == null
          ? const <HostGame>[]
          : await controls.games().catchError((_) => const <HostGame>[]);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => GameDetailScreen(
                game: game,
                games: games,
                host: host.isEmpty ? null : {for (final g in host) g.id: g},
                onAdd: controls == null ? null : _queue,
              )));
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _queue(CatalogGame game) async {
    try {
      await widget.controls!.addToQueue(game.id);
      if (mounted) toast(context, '${game.title} is in the queue');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final label = switch (status) {
      EntryStatus.playing => 'Playing now',
      EntryStatus.upNext => 'Up next',
      EntryStatus.queued => 'In the queue',
      EntryStatus.autoplay => 'Autoplay pick',
      EntryStatus.played => 'Played earlier tonight',
    };
    final emptyHint = switch (status) {
      EntryStatus.playing => 'This game has no settings to change.',
      EntryStatus.upNext =>
        'No settings to change yet. They show up here once ${entry.title} has loaded, '
            'if it has any.',
      _ => noSettingsHint(entry.title, playing: false),
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(entry.title,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: status == EntryStatus.playing
                      ? GnColors.ok
                      : GnColors.muted,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    status == EntryStatus.playing || widget.controls == null
                        ? null
                        : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                    status == EntryStatus.playing ? 'Playing' : 'Play now'),
              ),
            ),
            if (status == EntryStatus.autoplay ||
                status == EntryStatus.played) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.controls == null ? null : widget.onQueue,
                  icon: const Icon(Icons.queue),
                  label: const Text('Queue'),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 4),
          SettingsSection(
            key: ValueKey('sheet-settings-${entry.game}'),
            controls: widget.controls,
            game: entry.game,
            title: entry.title,
            showEmpty: true,
            emptyHint: emptyHint,
          ),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: const Text('View in the store'),
                subtitle: const Text('Videos, screenshots and details'),
                trailing: _opening
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right),
                onTap: _opening ? null : _store,
              ),
              if (widget.onRemove != null)
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline,
                      color: Color(0xFFF87171)),
                  title: const Text('Remove from the playlist'),
                  onTap: widget.onRemove,
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The game on the TV and what comes after it, in one card: each with a gear
/// for its settings, so a game can be set up before it starts. A tap on a
/// game opens it (play now, queue, store page); the whole playlist is one
/// tap further.
class NowAndNext extends StatefulWidget {
  final AppState state;

  /// One line instead of a card, above a game's phone screen.
  final bool compact;
  const NowAndNext({super.key, required this.state, this.compact = false});

  @override
  State<NowAndNext> createState() => _NowAndNextState();
}

class _NowAndNextState extends State<NowAndNext> {
  PlaylistView? _view;
  Timer? _timer;
  var _catalog = const <String, CatalogGame>{};

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
    if (!widget.compact) _loadCatalog();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Pictures for the games: the store's catalog, loaded once.
  Future<void> _loadCatalog() async {
    try {
      final games = await Catalog.instance.games();
      if (mounted) setState(() => _catalog = {for (final g in games) g.id: g});
    } catch (_) {
      // No pictures: the tiles show the games' first letters.
    }
  }

  Future<void> _load() async {
    final api = roomControlsFor(state);
    if (api == null) return;
    try {
      final view = await api.playlist();
      if (mounted) setState(() => _view = view);
    } on ApiError {
      // Keep what we showed; the next poll tries again.
    }
  }

  Future<void> _openAll() async {
    await PlaylistScreen.open(context, state);
    unawaited(_load());
  }

  Future<void> _play(PlaylistEntry entry, {bool start = false}) async {
    final controls = roomControlsFor(state);
    if (controls == null) return;
    try {
      if (start) {
        await controls.playNext(entry.game, start: true);
      } else {
        await controls.addToQueue(entry.game);
      }
      if (mounted) {
        toast(
            context,
            start
                ? '${entry.title} starts as soon as it has loaded'
                : '${entry.title} is in the queue');
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      unawaited(_load());
    }
  }

  Future<void> _remove(PlaylistView view, int i) async {
    final controls = roomControlsFor(state);
    if (controls == null) return;
    try {
      final next = await controls.removePlaylistEntry(view, i);
      if (mounted) setState(() => _view = next);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      unawaited(_load());
    }
  }

  void _open(PlaylistView view, int i) {
    final entry = view.entries[i];
    final status = entryStatus(view, i);
    final playing = view.playing == null
        ? null
        : view.entries
            .where((e) => e.game == view.playing)
            .map((e) => e.title)
            .firstOrNull;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => PlaylistGameSheet(
        entry: entry,
        status: status,
        controls: roomControlsFor(state),
        playingTitle: status == EntryStatus.playing ? null : playing,
        onStart: () {
          Navigator.of(sheet).pop();
          _play(entry, start: true);
        },
        onQueue: () {
          Navigator.of(sheet).pop();
          _play(entry);
        },
        onRemove: status != EntryStatus.playing && status != EntryStatus.played
            ? () {
                Navigator.of(sheet).pop();
                _remove(view, i);
              }
            : null,
      ),
    );
  }

  /// The entry on the TV now, if a game is being played.
  int? _playingIndex(PlaylistView view) {
    final c = view.current;
    if (c == null || view.playing == null) return null;
    return view.entries[c].game == view.playing ? c : null;
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final playing = view == null ? null : _playingIndex(view);
    final start = view == null ? 0 : (view.current ?? -1) + 1;
    final upcoming = view == null
        ? const <int>[]
        : [for (var i = start; i < view.entries.length; i++) i];
    final shown = upcoming.take(3).toList();
    final more = upcoming.length - shown.length;
    if (widget.compact) {
      final titles = [for (final i in shown) view!.entries[i].title];
      return InkWell(
        key: const ValueKey('playlist-peek'),
        onTap: _openAll,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
          child: Row(children: [
            const Icon(Icons.queue_music, size: 18, color: GnColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  titles.isEmpty ? 'Playlist' : 'Next: ${titles.join(' · ')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: GnColors.muted, fontSize: 13)),
            ),
            const Icon(Icons.chevron_right, size: 18, color: GnColors.muted),
          ]),
        ),
      );
    }
    // Before the first poll, the room's own idea of the current game.
    final fallbackTitle = state.inHostedRoom
        ? state.hostedRoom?.currentTitle
        : state.session?.currentTitle;
    final nowTitle =
        playing != null ? view!.entries[playing].title : fallbackTitle;
    final nowGame = playing != null ? view!.entries[playing].game : null;
    return Card(
      key: const ValueKey('now-and-next'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            key: const ValueKey('now-playing'),
            onTap: playing == null ? null : () => _open(view!, playing),
            leading: nowTitle == null
                ? const SizedBox.square(
                    dimension: 52,
                    child: Icon(Icons.weekend_outlined,
                        size: 32, color: GnColors.muted))
                : GameThumbnail(
                    game: nowGame == null ? null : _catalog[nowGame],
                    title: nowTitle,
                    size: 52),
            title: Text(nowTitle ?? 'In the lobby',
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            subtitle: Text(nowTitle == null
                ? 'Phone screens open here.'
                : 'On the TV now'),
            trailing: nowTitle == null
                ? null
                : GameSettingsButton(
                    state: state,
                    game: nowGame,
                    title: nowTitle,
                    playing: true),
          ),
          const Divider(height: 8, indent: 16, endIndent: 16),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('UP NEXT',
                style: TextStyle(
                    color: GnColors.green,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5)),
          ),
          if (view == null)
            const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Hint('Loading…'))
          else if (shown.isEmpty)
            const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Hint('No games queued yet.'))
          else
            for (final (n, i) in shown.indexed) _upcomingRow(view, i, n + 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
            child: Row(children: [
              TextButton.icon(
                key: const ValueKey('playlist-peek'),
                onPressed: _openAll,
                icon: const Icon(Icons.queue_music, size: 18),
                label: Text(more > 0
                    ? 'Whole playlist (+$more more)'
                    : 'Whole playlist'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// One queued game, as on the TV and in the catalog: its number (the
  /// same as the green badge on its cover), a small cover, the title.
  Widget _upcomingRow(PlaylistView view, int i, int number) {
    final entry = view.entries[i];
    final status = entryStatus(view, i);
    final label = switch (status) {
      EntryStatus.upNext => 'Up next',
      EntryStatus.queued => 'Queued',
      EntryStatus.autoplay => 'Autoplay',
      _ => null,
    };
    return ListTile(
      key: ValueKey('upcoming-${entry.game}-$i'),
      dense: true,
      onTap: () => _open(view, i),
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
            width: 24,
            child: Text(number.toString().padLeft(2, '0'),
                style: const TextStyle(
                    color: GnColors.muted,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()]))),
        GameThumbnail(game: _catalog[entry.game], title: entry.title),
      ]),
      title: Text(entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: label == null ? null : Text(label),
      trailing: GameSettingsButton(
          state: state, game: entry.game, title: entry.title),
    );
  }
}
