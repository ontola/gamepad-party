/// The store's filters and sort orders, mirrored from
/// `web/catalog-filters.json`, which the website uses too.
/// `test/catalog_filter_spec_test.dart` checks this file against that JSON
/// and runs its shared cases, so the app and the website stay in sync.
library;

/// The player counts the filters offer.
const playerCounts = [1, 2, 3, 4, 5, 6, 8];

/// Price filter: catalog value and label.
const priceOptions = {
  'free': 'Free',
  'pay_what_you_want': 'Pay what you want',
  'paid': 'Paid',
};

/// Platform filter: catalog value and label.
const platformOptions = {
  'windows': 'Windows',
  'mac': 'macOS',
  'linux': 'Linux',
  'browser': 'Browser',
};

/// The browser host's game list; it decides the Browser platform.
const browserLibraryPath = '/play/games/library.json';

/// Catalog ids in the browser host's library.json. Some browser builds
/// carry a -warp suffix next to the catalog id (neon-siege-warp).
Set<String> browserGameIds(Object? library) =>
    browserLibraryIds(library).keys.toSet();

/// The browser host's own id for each catalog id it runs, for
/// `/play/?game=ID` (neon-siege becomes neon-siege-warp).
Map<String, String> browserLibraryIds(Object? library) => {
      if (library is List)
        for (final entry in library)
          if (entry is Map &&
              entry['id'] is String &&
              RegExp(r'^[a-z0-9-]+$').hasMatch(entry['id'] as String))
            (entry['id'] as String).replaceFirst(RegExp(r'-warp$'), ''):
                entry['id'] as String,
    };

/// Filters that need the player's account.
const personalLabels = {
  'liked': 'Liked',
  'wanted': 'Want to play',
  'played': 'Played',
  'unplayed': 'Not played',
};

/// Only games the room's host can start.
const roomFilterLabel = 'Available in this room';

/// A game must carry every selected tag.
const tagMatch = 'all';

/// Different spellings of one tag, after [normalizeTag]'s cleanup.
const tagAliases = {
  'coop': 'co-op',
  'cooperative': 'co-op',
  'co-operative': 'co-op',
  'split-screen': 'splitscreen',
  'local-coop': 'co-op',
  'pvp': 'versus',
};

/// One spelling per tag: trimmed, lower case, spaces and underscores as
/// hyphens, then [tagAliases].
String normalizeTag(String tag) {
  final clean = tag
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_]+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  return tagAliases[clean] ?? clean;
}

/// [normalizeTag] on each tag, without blanks or repeats, in order.
List<String> normalizeTags(Iterable<String> tags) => {
      for (final t in tags.map(normalizeTag))
        if (t.isNotEmpty) t
    }.toList();

const _folds = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ç': 'c',
  'č': 'c',
  'ć': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ę': 'e',
  'ě': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ō': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'š': 's',
  'ś': 's',
  'ř': 'r',
  'ď': 'd',
  'ť': 't',
};

/// Lower case without accents, as the website's search compares text.
String searchFold(String text) {
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final c = String.fromCharCode(rune);
    out.write(_folds[c] ?? c);
  }
  return out.toString();
}

/// Every word of [query] appears in [text], ignoring case and accents.
bool searchMatches(String query, String text) {
  final haystack = searchFold(text);
  return searchFold(query)
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .every(haystack.contains);
}
