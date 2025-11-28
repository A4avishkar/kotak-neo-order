import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/watchlist_entry.dart';
import 'scrip_search_service.dart';

class WatchlistService {
  WatchlistService._();

  static final WatchlistService _instance = WatchlistService._();

  factory WatchlistService() => _instance;

  static const _prefsKey = 'watchlist_entries';

  Future<List<WatchlistEntry>> fetchEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? [];
    final entries = <WatchlistEntry>[];
    for (final raw in stored) {
      try {
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        entries.add(WatchlistEntry.fromJson(jsonMap));
      } catch (_) {
        // Ignore malformed entry.
      }
    }
    return entries;
  }

  Future<bool> addHit(ScripSearchHit hit) async {
    final entry = WatchlistEntry.fromHit(hit);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? [];
    final exists = stored.any((raw) {
      try {
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        return jsonMap['id'] == entry.id;
      } catch (_) {
        return false;
      }
    });
    if (exists) {
      return false;
    }
    stored.add(jsonEncode(entry.toJson()));
    await prefs.setStringList(_prefsKey, stored);
    return true;
  }

  Future<void> removeEntry(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? [];
    stored.removeWhere((raw) {
      try {
        final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
        return jsonMap['id'] == id;
      } catch (_) {
        return false;
      }
    });
    await prefs.setStringList(_prefsKey, stored);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

