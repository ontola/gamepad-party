// The app's store filters must match web/catalog-filters.json, which the
// website uses too: same options, and the same results on its shared cases.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/catalog_filter_spec.dart';
import 'package:gamenight/screens/catalog_filters.dart';

void main() {
  final spec =
      jsonDecode(File('../web/catalog-filters.json').readAsStringSync())
          as Map<String, dynamic>;
  Map<String, String> options(String key) => {
        for (final o in spec[key] as List)
          o['id'] as String: o['label'] as String
      };

  test('options match the shared definition', () {
    expect(playerCounts, spec['players']);
    expect(priceOptions, options('price'));
    expect(platformOptions, options('platforms'));
    expect(personalLabels, options('personal'));
    expect(roomFilterLabel, spec['room']['label']);
    expect(tagMatch, spec['tag_match']);
    expect(tagAliases, spec['tag_aliases']);
    expect(browserLibraryPath, spec['browser_library']);
    expect([
      for (final s in CatalogSort.values)
        {
          'id': s.id,
          'label': s.label,
          'short': s.short,
          if (s.personal) 'personal': true
        }
    ], spec['sorts']);
  });

  final cases = spec['cases'] as Map<String, dynamic>;
  final games = parseCatalog(cases['games'] as List);
  List<String> ids(Iterable<CatalogGame> list) => [for (final g in list) g.id];

  test('shared filter cases', () {
    for (final c in cases['filters'] as List) {
      final f = c['filter'] as Map;
      final filter = CatalogFilter(
          query: f['q'] as String? ?? '',
          tags: {...(f['tags'] as List? ?? const []).cast<String>()},
          players: f['players'] as int?,
          price: f['price'] as String?,
          platform: f['platform'] as String?,
          browserGames: browserGameIds(cases['browser_library']));
      expect(ids(games.where(filter.matches)), c['expect'], reason: '$f');
    }
  });

  test('shared sort cases', () {
    for (final c in cases['sorts'] as List) {
      final sort = CatalogSort.values.firstWhere((s) => s.id == c['sort']);
      expect(ids(sortCatalog(games, sort)), c['expect'], reason: c['sort']);
    }
  });

  test('shared tag cases', () {
    for (final c in cases['tags'] as List) {
      expect(normalizeTags((c['tags'] as List).cast<String>()), c['expect']);
    }
  });
}
