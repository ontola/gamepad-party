import 'package:flutter/material.dart';

import '../account.dart';
import '../catalog.dart';
import '../catalog_filter_spec.dart';
import '../theme.dart';

class CatalogFilter {
  final bool liked, unplayed, played, wanted;

  /// Only games by this developer, as the store names them.
  final String? developer;

  /// Only games this account develops, in the store or not.
  final bool mine;
  final Set<String> tags, likedGames, playedGames, mineGames, wantedGames;

  /// Words to find in a game's title, tagline, developer or tags.
  final String query;

  /// Only games that can be played with exactly this many players.
  final int? players;

  /// Only games with this price kind (see [priceOptions]).
  final String? price;

  /// Only games that run on this platform (see [platformOptions]).
  final String? platform;

  /// Only games the room's host can start ([playableGames]).
  final bool room;
  final Set<String> playableGames;
  const CatalogFilter(
      {this.liked = false,
      this.unplayed = false,
      this.played = false,
      this.wanted = false,
      this.wantedGames = const {},
      this.developer,
      this.mine = false,
      this.mineGames = const {},
      this.tags = const {},
      this.likedGames = const {},
      this.playedGames = const {},
      this.query = '',
      this.players,
      this.price,
      this.platform,
      this.room = false,
      this.playableGames = const {}});

  /// Filters the filter sheet sets, for the count on the Filter button.
  int get sheetCount =>
      [liked, unplayed, played, wanted, mine, room].where((v) => v).length +
      tags.length +
      (price != null ? 1 : 0) +
      (platform != null ? 1 : 0);

  bool get active =>
      liked ||
      unplayed ||
      played ||
      wanted ||
      developer != null ||
      mine ||
      room ||
      tags.isNotEmpty ||
      query.trim().isNotEmpty ||
      players != null ||
      price != null ||
      platform != null;
  bool matches(CatalogGame game) =>
      (!liked || likedGames.contains(game.id)) &&
      (!unplayed || !playedGames.contains(game.id)) &&
      (!played || playedGames.contains(game.id)) &&
      (!wanted || wantedGames.contains(game.id)) &&
      (developer == null || game.developer == developer) &&
      (mine ? mineGames.contains(game.id) : !game.unreviewed) &&
      (!room || playableGames.contains(game.id)) &&
      tags.every(game.tags.contains) &&
      (price == null || (game.price ?? 'free') == price) &&
      (platform == null || game.platforms.contains(platform)) &&
      _fits(game) &&
      searchMatches(query,
          [game.title, game.tagline, game.developer, ...game.tags].join(' '));
  bool _fits(CatalogGame game) {
    final n = players;
    if (n == null) return true;
    final min = game.minPlayers ?? game.maxPlayers;
    final max = game.maxPlayers ?? game.minPlayers;
    return min == null || max == null || (min <= n && n <= max);
  }

  CatalogFilter copyWith(
          {bool? liked,
          bool? unplayed,
          bool? played,
          bool? wanted,
          Set<String>? wantedGames,
          String? Function()? developer,
          bool? mine,
          Set<String>? mineGames,
          Set<String>? tags,
          Set<String>? likedGames,
          Set<String>? playedGames,
          String? query,
          int? Function()? players,
          String? Function()? price,
          String? Function()? platform,
          bool? room,
          Set<String>? playableGames}) =>
      CatalogFilter(
          liked: liked ?? this.liked,
          unplayed: unplayed ?? this.unplayed,
          played: played ?? this.played,
          wanted: wanted ?? this.wanted,
          wantedGames: wantedGames ?? this.wantedGames,
          developer: developer == null ? this.developer : developer(),
          mine: mine ?? this.mine,
          mineGames: mineGames ?? this.mineGames,
          tags: tags ?? this.tags,
          likedGames: likedGames ?? this.likedGames,
          playedGames: playedGames ?? this.playedGames,
          query: query ?? this.query,
          players: players == null ? this.players : players(),
          price: price == null ? this.price : price(),
          platform: platform == null ? this.platform : platform(),
          room: room ?? this.room,
          playableGames: playableGames ?? this.playableGames);
}

/// How the store orders its games, as on the website
/// (`web/catalog-filters.json`).
enum CatalogSort {
  store('featured', 'Featured', 'Featured'),
  newest('newest', 'Newest', 'Newest'),
  updated('updated', 'Recently updated', 'Updated'),
  lastPlayed('last_played', 'Last played by you', 'Last played'),
  title('title', 'A to Z', 'A–Z'),
  players('players', 'Most players', 'Players'),
  shortest('short', 'Shortest rounds', 'Shortest'),
  free('free', 'Free first', 'Free'),
  liked('liked', 'Most liked', 'Liked');

  /// The id both stores share.
  final String id;

  /// In the menu, and on the sort button once chosen.
  final String label, short;
  const CatalogSort(this.id, this.label, this.short);

  /// Needs the player's account.
  bool get personal => this == lastPlayed;
}

/// Free, then pay what you want, then paid; unknown prices last.
int priceRank(CatalogGame game) =>
    const ['free', 'pay_what_you_want', 'paid'].indexOf(game.price ?? 'free') +
    (game.price == null || priceOptions.containsKey(game.price) ? 0 : 99);

/// [games] in [sort] order, keeping their order between equals. [played]
/// and [ratings] feed Last played and Most liked.
List<CatalogGame> sortCatalog(List<CatalogGame> games, CatalogSort sort,
    {Map<String, int> played = const {},
    Map<String, ({int up, int down})> ratings = const {}}) {
  double ratio(CatalogGame g) {
    final r = ratings[g.id];
    final votes = (r?.up ?? 0) + (r?.down ?? 0);
    return votes == 0 ? -1 : r!.up / votes;
  }

  int votes(CatalogGame g) =>
      (ratings[g.id]?.up ?? 0) + (ratings[g.id]?.down ?? 0);
  // Highest first; games without a value last.
  int high<T extends Comparable<Object>>(
          T? Function(CatalogGame) key, CatalogGame a, CatalogGame b) =>
      switch ((key(a), key(b))) {
        (null, null) => 0,
        (null, _) => 1,
        (_, null) => -1,
        (final x?, final y?) => y.compareTo(x),
      };
  final int Function(CatalogGame, CatalogGame)? order = switch (sort) {
    CatalogSort.store => null,
    CatalogSort.newest => (a, b) => high((g) => g.added, a, b),
    CatalogSort.updated => (a, b) => high((g) => g.updated, a, b),
    CatalogSort.lastPlayed => (a, b) => high((g) => played[g.id], a, b),
    CatalogSort.title => (a, b) =>
        searchFold(a.title).compareTo(searchFold(b.title)),
    CatalogSort.players => (a, b) => high((g) => g.maxPlayers, a, b),
    CatalogSort.shortest => (a, b) =>
        high((g) => g.matchMinutes == null ? null : -g.matchMinutes!, a, b),
    CatalogSort.free => (a, b) => priceRank(a).compareTo(priceRank(b)),
    CatalogSort.liked => (a, b) {
        final r = ratio(b).compareTo(ratio(a));
        return r != 0 ? r : votes(b).compareTo(votes(a));
      },
  };
  // Featured: featured games first, then catalog order. Other sorts break
  // ties in that order, as the website does.
  final featured = [
    ...games.where((g) => g.featured),
    ...games.where((g) => !g.featured)
  ];
  if (order == null) return featured;
  final indexed = [for (var i = 0; i < featured.length; i++) (i, featured[i])];
  indexed.sort((a, b) {
    final c = order(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

class CatalogFilters extends StatefulWidget {
  final CatalogFilter filter;
  final List<CatalogGame> games;
  final CloudApi? cloud;
  final Future<void> Function()? onSignIn;

  /// The games this player wants to play, when known.
  final Set<String> wantedGames;

  /// In a room: the games its host can start, for "Available in this room".
  final Set<String>? playableGames;
  const CatalogFilters(
      {super.key,
      required this.filter,
      required this.games,
      this.cloud,
      this.onSignIn,
      this.wantedGames = const {},
      this.playableGames});
  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  late bool _liked = widget.filter.liked,
      _unplayed = widget.filter.unplayed,
      _played = widget.filter.played,
      _wanted = widget.filter.wanted,
      _mine = widget.filter.mine,
      _room = widget.filter.room && widget.playableGames != null;
  late final Set<String> _tags = {...widget.filter.tags};
  late int? _players = widget.filter.players;
  late String? _price = widget.filter.price, _platform = widget.filter.platform;
  String _tagQuery = '';
  Set<String> _likedGames = {}, _playedGames = {};
  bool _loading = false, _loaded = false;
  String? _error;
  bool get _signedIn => widget.cloud?.signedIn == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_signedIn) return;
    setState(() {
      _loading = true;
      _error = null;
      _loaded = false;
    });
    try {
      final cloud = widget.cloud!, identity = widget.cloud!.token;
      final results =
          await Future.wait<Object>([cloud.gameRatings(), cloud.lastPlayed()]);
      if (!mounted || cloud.token != identity) return;
      final ratings = results[0] as Map<String, int>;
      final played = results[1] as Map<String, int>;
      setState(() {
        _likedGames = {
          for (final entry in ratings.entries)
            if (entry.value == 1) entry.key
        };
        _playedGames = played.keys.toSet();
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load your likes and play history.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  CatalogFilter get _selection => CatalogFilter(
      liked: _liked,
      unplayed: _unplayed,
      played: _played,
      wanted: _wanted,
      wantedGames: widget.wantedGames,
      developer: widget.filter.developer,
      mine: _mine,
      mineGames: widget.filter.mineGames,
      tags: _tags,
      likedGames: _likedGames,
      playedGames: _playedGames,
      query: widget.filter.query,
      players: _players,
      price: _price,
      platform: _platform,
      room: _room,
      playableGames: widget.playableGames ?? const {});

  static const _heading = TextStyle(fontWeight: FontWeight.w700);

  /// A row of single-choice chips; tapping the chosen one clears it.
  Widget _choices<T>(Map<T, String> options, T? value, void Function(T?) set) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final MapEntry(:key, value: label) in options.entries)
          ChoiceChip(
              label: Text(label),
              selected: value == key,
              onSelected: (v) => setState(() => set(v ? key : null))),
      ]);

  @override
  Widget build(BuildContext context) {
    final tags = widget.games.expand((game) => game.tags).toSet().toList()
      ..sort();
    final find = searchFold(_tagQuery.trim());
    final shownTags = [
      for (final tag in tags)
        if (_tags.contains(tag) || searchFold(tag).contains(find)) tag
    ];
    final ready = !(_liked || _unplayed || _played) || _loaded;
    final count = widget.games.where(_selection.matches).length;
    return SafeArea(
        child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                  child: Text('Filter games',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700))),
              TextButton(
                  onPressed: () => setState(() {
                        _liked = false;
                        _unplayed = false;
                        _played = false;
                        _wanted = false;
                        _mine = false;
                        _room = false;
                        _players = null;
                        _price = null;
                        _platform = null;
                        _tags.clear();
                      }),
                  child: const Text('Clear')),
            ]),
            Expanded(
                child: ListView(children: [
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (widget.playableGames != null)
                  FilterChip(
                      label: const Text(roomFilterLabel),
                      avatar:
                          const Icon(Icons.sports_esports_outlined, size: 18),
                      selected: _room,
                      onSelected: (v) => setState(() => _room = v)),
                FilterChip(
                    label: Text(personalLabels['liked']!),
                    avatar: const Icon(Icons.thumb_up_outlined, size: 18),
                    selected: _liked,
                    onSelected:
                        _loaded ? (v) => setState(() => _liked = v) : null),
                FilterChip(
                    label: Text(personalLabels['wanted']!),
                    avatar: const Icon(Icons.bookmark_border, size: 18),
                    selected: _wanted,
                    onSelected:
                        _signedIn ? (v) => setState(() => _wanted = v) : null),
                if (widget.filter.mineGames.isNotEmpty)
                  FilterChip(
                      label: const Text('My games'),
                      avatar: const Icon(Icons.code, size: 18),
                      selected: _mine,
                      onSelected: (v) => setState(() => _mine = v)),
                FilterChip(
                    label: Text(personalLabels['played']!),
                    selected: _played,
                    onSelected: _loaded
                        ? (v) => setState(() {
                              _played = v;
                              if (v) _unplayed = false;
                            })
                        : null),
                FilterChip(
                    label: Text(personalLabels['unplayed']!),
                    selected: _unplayed,
                    onSelected: _loaded
                        ? (v) => setState(() {
                              _unplayed = v;
                              if (v) _played = false;
                            })
                        : null),
              ]),
              if (_loading)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator()),
              if (!_signedIn) ...[
                const Hint('Sign in to filter by your likes and play history.'),
                if (widget.onSignIn != null)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed: () async {
                            await widget.onSignIn!();
                            if (mounted) {
                              setState(() {});
                              await _load();
                            }
                          },
                          child: const Text('Sign in'))),
              ] else if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: GnColors.warn)),
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        onPressed: _load, child: const Text('Try again'))),
              ],
              const SizedBox(height: 24),
              const Text('Players', style: _heading),
              const SizedBox(height: 12),
              _choices({for (final n in playerCounts) n: '$n'}, _players,
                  (v) => _players = v),
              const SizedBox(height: 24),
              const Text('Price', style: _heading),
              const SizedBox(height: 12),
              _choices(priceOptions, _price, (v) => _price = v),
              const SizedBox(height: 24),
              const Text('Platform', style: _heading),
              const SizedBox(height: 12),
              _choices(platformOptions, _platform, (v) => _platform = v),
              const SizedBox(height: 24),
              const Text('Tags', style: _heading),
              const SizedBox(height: 4),
              const Hint('Games with every selected tag.'),
              if (tags.length > 12) ...[
                const SizedBox(height: 8),
                TextField(
                    key: const ValueKey('tag-search'),
                    onChanged: (v) => setState(() => _tagQuery = v),
                    decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: 'Find a tag…')),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final tag in shownTags)
                  FilterChip(
                      label: Text(tag),
                      selected: _tags.contains(tag),
                      onSelected: (v) => setState(() {
                            v ? _tags.add(tag) : _tags.remove(tag);
                          })),
              ]),
              if (shownTags.isEmpty) const Hint('No matching tags'),
              const SizedBox(height: 16),
            ])),
            FilledButton(
                onPressed:
                    ready ? () => Navigator.pop(context, _selection) : null,
                child: Text(ready
                    ? 'Show $count ${count == 1 ? 'game' : 'games'}'
                    : _loading
                        ? 'Loading your games…'
                        : 'Show games')),
          ])),
    ));
  }
}
