import 'package:shared_preferences/shared_preferences.dart';

/// Local store for the user's recent search queries.
///
/// Apple Music keeps the last few searches per account; here the page is
/// stateless per visit, so the history lives next to the field and never
/// leaves the machine. Queries are de-duplicated (a repeat moves to the front),
/// capped at [maxEntries] and stored with [SharedPreferences], i.e. one
/// `setStringList` write per change — no network, no account coupling.
class SearchHistoryStore {
  SearchHistoryStore([this._preferences]);

  /// How many queries the empty-search page offers back.
  static const int maxEntries = 10;

  static const String _storageKey = 'lazer_search_history_v1';

  SharedPreferences? _preferences;

  Future<SharedPreferences> _prefs() async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// Reads the stored queries, newest first.
  Future<List<String>> load() async {
    final SharedPreferences prefs = await _prefs();
    return List<String>.of(
      prefs.getStringList(_storageKey) ?? const <String>[],
    );
  }

  /// Records [query] as the most recent search and returns the new list.
  Future<List<String>> record(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return load();
    final List<String> entries = await load();
    entries.removeWhere((String entry) => entry == trimmed);
    entries.insert(0, trimmed);
    final List<String> capped = entries
        .take(maxEntries)
        .toList(growable: false);
    await (await _prefs()).setStringList(_storageKey, capped);
    return capped;
  }

  /// Drops one query from the history; returns the remaining list.
  Future<List<String>> remove(String query) async {
    final List<String> entries = await load();
    entries.removeWhere((String entry) => entry == query);
    await (await _prefs()).setStringList(_storageKey, entries);
    return entries;
  }

  /// Wipes the history.
  Future<void> clear() async {
    await (await _prefs()).remove(_storageKey);
  }
}
