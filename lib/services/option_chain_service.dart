import 'package:flutter/foundation.dart';

import '../models/option_chain_entry.dart';
import 'cloud_scrip_search_service.dart';
import 'credentials_service.dart';

class OptionChainService {
  OptionChainService._();

  /// Shared singleton instance.
  static final OptionChainService instance = OptionChainService._();
  factory OptionChainService() => instance;

  // In-memory cache: segment -> symbol -> expiryStr -> List<OptionChainEntry>
  final Map<String, Map<String, Map<String, List<OptionChainEntry>>>> _allExpiriesCache = {};

  // Sorted expiry lists: segment -> symbol -> List<String> (chronological)
  final Map<String, Map<String, List<String>>> _sortedExpiriesCache = {};

  // Nearest expiry cache: segment -> symbol -> List<OptionChainEntry>
  final Map<String, Map<String, List<OptionChainEntry>>> _nearestExpiryCache = {};
  final Map<String, Map<String, String>> _cachedNearestExpiry = {};

  // Available indices per segment cache
  final Map<String, List<String>> _availableIndicesCache = {};

  // Available segments cache
  List<String>? _availableSegmentsCache;

  static const Map<String, String> segmentDisplayNames = {
    'nse_fo': 'NSE F&O',
    'bse_fo': 'BSE F&O',
    'mcx_fo': 'MCX F&O',
    'cde_fo': 'CDE F&O',
  };

  /// Primary default index symbol per F&O segment.
  static String defaultSymbolForSegment(String segment) {
    switch (segment) {
      case 'bse_fo':
        return 'SENSEX';
      case 'nse_fo':
      default:
        return 'NIFTY';
    }
  }

  /// Picks the preferred symbol from [indices] for [segment].
  static String preferredSymbolForSegment(String segment, List<String> indices) {
    if (indices.isEmpty) return defaultSymbolForSegment(segment);
    final preferred = defaultSymbolForSegment(segment);
    if (indices.contains(preferred)) return preferred;
    return indices.first;
  }

  /// Returns available F&O segments.
  Future<List<String>> getAvailableFoSegments() async {
    if (_availableSegmentsCache != null) return _availableSegmentsCache!;
    const defaults = ['nse_fo', 'bse_fo', 'mcx_fo', 'cde_fo'];
    _availableSegmentsCache = defaults;
    return defaults;
  }

  /// Returns cached indices for [segment], if any.
  List<String>? cachedIndicesForSegment(String segment) =>
      _availableIndicesCache[segment];

  /// Gets available indices for [segment] — fetches from Worker if not cached.
  Future<List<String>> getAvailableIndices({String segment = 'nse_fo'}) async {
    if (_availableIndicesCache.containsKey(segment) &&
        _availableIndicesCache[segment]!.isNotEmpty) {
      return _availableIndicesCache[segment]!;
    }

    try {
      await loadNearestExpiry(symbol: defaultSymbolForSegment(segment), segment: segment);
    } catch (e) {
      debugPrint('Error warming up indices for $segment: $e');
    }

    final cached = _availableIndicesCache[segment];
    if (cached != null && cached.isNotEmpty) return cached;

    final defaults = switch (segment) {
      'bse_fo' => ['SENSEX', 'BANKEX'],
      'mcx_fo' => ['CRUDEOIL', 'GOLD', 'SILVER', 'NATURALGAS'],
      'cde_fo' => ['USDINR', 'EURINR', 'GBPINR', 'JPYINR'],
      _ => ['NIFTY', 'BANKNIFTY', 'FINNIFTY', 'MIDCPNIFTY'],
    };
    _availableIndicesCache[segment] = defaults;
    return defaults;
  }

  /// Stores parsed data into all caches.
  void _cacheParsedSegmentData({
    required String segment,
    required String symbol,
    required Map<String, List<OptionChainEntry>> allChains,
    required List<String> indices,
  }) {
    _availableIndicesCache[segment] = indices;
    _allExpiriesCache.putIfAbsent(segment, () => {})[symbol] = allChains;

    final expiries = allChains.keys.toList()
      ..sort((a, b) {
        final dateA = _parseExpiryToDateTime(a);
        final dateB = _parseExpiryToDateTime(b);
        if (dateA == null || dateB == null) return a.compareTo(b);
        return dateA.compareTo(dateB);
      });
    _sortedExpiriesCache.putIfAbsent(segment, () => {})[symbol] = expiries;

    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    String? nearestExpiryStr;
    for (final expiry in expiries) {
      final expiryDate = _parseExpiryToDateTime(expiry);
      if (expiryDate != null &&
          (expiryDate.isAfter(today) || expiryDate.isAtSameMomentAs(today))) {
        nearestExpiryStr = expiry;
        break;
      }
    }
    nearestExpiryStr ??= expiries.isNotEmpty ? expiries.last : null;
    if (nearestExpiryStr != null) {
      _nearestExpiryCache.putIfAbsent(segment, () => {})[symbol] =
          allChains[nearestExpiryStr] ?? [];
      _cachedNearestExpiry.putIfAbsent(segment, () => {})[symbol] = nearestExpiryStr;
    }
  }

  /// Loads the nearest expiry option chain — always from Cloud Worker.
  Future<List<OptionChainEntry>> loadNearestExpiry({
    String symbol = 'NIFTY',
    String segment = 'nse_fo',
  }) async {
    // Return from cache if available
    if (_nearestExpiryCache.containsKey(segment) &&
        _nearestExpiryCache[segment]!.containsKey(symbol) &&
        _cachedNearestExpiry.containsKey(segment) &&
        _cachedNearestExpiry[segment]!.containsKey(symbol)) {
      debugPrint(
        'Returning cached nearest expiry for $symbol in $segment: '
        '${_cachedNearestExpiry[segment]![symbol]}',
      );
      return _nearestExpiryCache[segment]![symbol]!;
    }

    // Extract from allExpiriesCache if present
    if (_allExpiriesCache.containsKey(segment) &&
        _allExpiriesCache[segment]!.containsKey(symbol)) {
      final nearestExpiryStr = await getNearestExpiry(symbol: symbol, segment: segment);
      if (nearestExpiryStr != null &&
          _allExpiriesCache[segment]![symbol]!.containsKey(nearestExpiryStr)) {
        _nearestExpiryCache.putIfAbsent(segment, () => {})[symbol] =
            _allExpiriesCache[segment]![symbol]![nearestExpiryStr]!;
        _cachedNearestExpiry.putIfAbsent(segment, () => {})[symbol] = nearestExpiryStr;
        return _nearestExpiryCache[segment]![symbol]!;
      }
    }

    // Fetch directly from Cloud Worker
    debugPrint('Fetching option chain from Cloud Worker for $symbol in $segment...');
    final parsed = await _fetchFromCloudWorker(symbol: symbol, segment: segment);

    final allChains = parsed['chains'] as Map<String, List<OptionChainEntry>>;
    final indices = (parsed['indices'] as List).cast<String>();

    if (allChains.isEmpty) {
      throw Exception('No option data found for $symbol in $segment');
    }

    _cacheParsedSegmentData(
      segment: segment,
      symbol: symbol,
      allChains: allChains,
      indices: indices,
    );

    final nearestExpiryStr = _cachedNearestExpiry[segment]![symbol]!;
    debugPrint(
      'Loaded nearest expiry for $symbol in $segment: '
      '$nearestExpiryStr (${_nearestExpiryCache[segment]![symbol]!.length} strikes)',
    );
    return _nearestExpiryCache[segment]![symbol]!;
  }

  /// Fetches all expiry option chain data from Cloud Worker.
  Future<Map<String, List<OptionChainEntry>>> loadAllOptionChains({
    String symbol = 'NIFTY',
    String segment = 'nse_fo',
  }) async {
    if (_allExpiriesCache.containsKey(segment) &&
        _allExpiriesCache[segment]!.containsKey(symbol)) {
      return _allExpiriesCache[segment]![symbol]!;
    }
    await loadNearestExpiry(symbol: symbol, segment: segment);
    return _allExpiriesCache[segment]![symbol]!;
  }

  /// Loads option chain for a specific expiry from cache or Cloud Worker.
  Future<List<OptionChainEntry>> loadOptionChainForExpiry(
    String expiry, {
    String symbol = 'NIFTY',
    String segment = 'nse_fo',
  }) async {
    // Check nearest expiry cache
    if (_cachedNearestExpiry.containsKey(segment) &&
        _cachedNearestExpiry[segment]!.containsKey(symbol) &&
        expiry == _cachedNearestExpiry[segment]![symbol] &&
        _nearestExpiryCache.containsKey(segment) &&
        _nearestExpiryCache[segment]!.containsKey(symbol)) {
      return _nearestExpiryCache[segment]![symbol]!;
    }

    // Check all expiries cache
    if (_allExpiriesCache.containsKey(segment) &&
        _allExpiriesCache[segment]!.containsKey(symbol) &&
        _allExpiriesCache[segment]![symbol]!.containsKey(expiry)) {
      return _allExpiriesCache[segment]![symbol]![expiry]!;
    }

    // Fetch specifically for this expiry from Cloud Worker
    debugPrint('Fetching specific expiry $expiry for $symbol in $segment from Cloud Worker...');
    try {
      final parsed = await _fetchFromCloudWorker(
        symbol: symbol,
        segment: segment,
        expiry: expiry,
      );
      final fetchedChains = parsed['chains'] as Map<String, List<OptionChainEntry>>;

      // Try exact match first, then fallback to first available
      List<OptionChainEntry>? targetChain = fetchedChains[expiry];
      if (targetChain == null || targetChain.isEmpty) {
        targetChain = fetchedChains.values.firstOrNull ?? [];
      }

      if (targetChain.isNotEmpty) {
        _allExpiriesCache
            .putIfAbsent(segment, () => {})
            .putIfAbsent(symbol, () => {})[expiry] = targetChain;
      }
      return targetChain;
    } catch (e) {
      debugPrint('Failed to fetch expiry $expiry from Cloud Worker: $e');
    }

    return [];
  }

  /// Gets available expiries for [symbol] in [segment].
  Future<List<String>> getAvailableExpiries({
    String symbol = 'NIFTY',
    String segment = 'nse_fo',
  }) async {
    if (_sortedExpiriesCache.containsKey(segment) &&
        _sortedExpiriesCache[segment]!.containsKey(symbol)) {
      return _sortedExpiriesCache[segment]![symbol]!;
    }

    if (_allExpiriesCache.containsKey(segment) &&
        _allExpiriesCache[segment]!.containsKey(symbol)) {
      final expiries = _allExpiriesCache[segment]![symbol]!.keys.toList()
        ..sort((a, b) {
          final dateA = _parseExpiryToDateTime(a);
          final dateB = _parseExpiryToDateTime(b);
          if (dateA == null || dateB == null) return a.compareTo(b);
          return dateA.compareTo(dateB);
        });
      _sortedExpiriesCache.putIfAbsent(segment, () => {})[symbol] = expiries;
      return expiries;
    }

    await loadNearestExpiry(symbol: symbol, segment: segment);
    return _sortedExpiriesCache[segment]?[symbol] ?? [];
  }

  /// Gets the nearest future expiry string.
  Future<String?> getNearestExpiry({
    String symbol = 'NIFTY',
    String segment = 'nse_fo',
  }) async {
    final expiries = _allExpiriesCache.containsKey(segment) &&
            _allExpiriesCache[segment]!.containsKey(symbol)
        ? _allExpiriesCache[segment]![symbol]!.keys.toList()
        : await getAvailableExpiries(symbol: symbol, segment: segment);

    if (expiries.isEmpty) return null;

    expiries.sort((a, b) {
      final dateA = _parseExpiryToDateTime(a);
      final dateB = _parseExpiryToDateTime(b);
      if (dateA == null || dateB == null) return a.compareTo(b);
      return dateA.compareTo(dateB);
    });

    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    for (final expiry in expiries) {
      final expiryDate = _parseExpiryToDateTime(expiry);
      if (expiryDate != null &&
          (expiryDate.isAfter(today) || expiryDate.isAtSameMomentAs(today))) {
        return expiry;
      }
    }
    return expiries.last;
  }

  /// Clears all in-memory caches.
  void clearCache() {
    _nearestExpiryCache.clear();
    _cachedNearestExpiry.clear();
    _allExpiriesCache.clear();
    _sortedExpiriesCache.clear();
    _availableIndicesCache.clear();
    _availableSegmentsCache = null;
    debugPrint('Option chain cache cleared');
  }

  // ---------------------------------------------------------------------------
  // Cloud Worker Fetcher
  // ---------------------------------------------------------------------------

  /// Fetches option chain data via the Cloudflare Worker API.
  Future<Map<String, dynamic>> _fetchFromCloudWorker({
    required String symbol,
    required String segment,
    String? expiry,
  }) async {
    final creds = await CredentialsService().getCredentials();
    final workerUrl = creds?.scripWorkerUrl;
    final cloudService = CloudScripSearchService();

    final hits = await cloudService.search(
      symbol,
      workerUrl: workerUrl,
      limit: 5000,
      segment: segment,
      expiry: expiry,
      exact: true,
    );

    debugPrint(
      '_fetchFromCloudWorker: Got ${hits.length} hits for $symbol in $segment (expiry: $expiry)',
    );

    final expiryMap = <String, Map<double, OptionChainEntry>>{};
    final indices = <String>{symbol};
    final symbolUpper = symbol.toUpperCase();
    int skippedSymbol = 0, skippedOptionType = 0, skippedExpiry = 0, skippedStrike = 0, processed = 0;

    for (final hit in hits) {
      final trdSymbol = hit.metadata['pTrdSymbol'] ?? hit.primaryValue;
      final token = hit.metadata['pToken'] ?? hit.metadata['pSymbol'] ?? '';
      final symbolName = (hit.metadata['pSymbolName'] ?? '').toUpperCase();

      if (token.isEmpty) continue;

      // Filter to exact symbol match
      final trdUpper = trdSymbol.toUpperCase();
      if (symbolName.isNotEmpty) {
        if (symbolName != symbolUpper) { skippedSymbol++; continue; }
      } else {
        if (!trdUpper.startsWith(symbolUpper)) { skippedSymbol++; continue; }
        if (symbolUpper == 'NIFTY' &&
            (trdUpper.startsWith('NIFTYNXT') ||
                trdUpper.startsWith('NIFTYIT') ||
                trdUpper.startsWith('NIFTYMID'))) {
          skippedSymbol++; continue;
        }
        if (symbolUpper == 'BANKNIFTY' && trdUpper.startsWith('BANKEX')) {
          skippedSymbol++; continue;
        }
      }

      // Determine option type
      var optionType = (hit.metadata['pOptionType'] ?? '').toUpperCase();
      if (optionType != 'CE' && optionType != 'PE') {
        if (trdSymbol.endsWith('CE') || trdSymbol.endsWith('CE.00')) {
          optionType = 'CE';
        } else if (trdSymbol.endsWith('PE') || trdSymbol.endsWith('PE.00')) {
          optionType = 'PE';
        }
      }
      if (optionType != 'CE' && optionType != 'PE') { skippedOptionType++; continue; }

      // Determine expiry string
      final rawExpiry = hit.metadata['lExpiryDate'] ??
          hit.metadata['pExpiryDate'] ??
          hit.metadata['expiry'];
      String? expiryStr;

      if (rawExpiry != null && rawExpiry.isNotEmpty) {
        expiryStr = _normalizeExpiryString(rawExpiry);
      }
      if (expiryStr == null || expiryStr.isEmpty) {
        final trdMatch = RegExp(r'(\d{2}[A-Z]{3}\d{2})').firstMatch(trdSymbol) ??
            RegExp(r'(\d{2}[A-Z]{3})').firstMatch(trdSymbol);
        expiryStr = trdMatch?.group(1);
      }
      if (expiryStr == null || expiryStr.isEmpty) { skippedExpiry++; continue; }

      // Determine strike price
      final strikeStr = hit.metadata['dStrikePrice'] ??
          hit.metadata['pStrikePrice'] ??
          hit.metadata['strikePrice'] ??
          '';
      double? strike;
      if (strikeStr.isNotEmpty) strike = double.tryParse(strikeStr);
      if (strike == null) {
        final m = RegExp(r'(\d+(?:\.\d+)?)(?:CE|PE)').firstMatch(trdSymbol);
        if (m != null) strike = double.tryParse(m.group(1)!);
      }
      if (strike != null && strike > 100000) strike = strike / 100.0;
      if (strike == null || strike <= 0) { skippedStrike++; continue; }

      processed++;
      final validStrike = strike;
      final validExpiry = expiryStr;

      final strikeMap = expiryMap.putIfAbsent(validExpiry, () => {});
      final entry = strikeMap.putIfAbsent(
        validStrike,
        () => OptionChainEntry(strike: validStrike, expiry: validExpiry),
      );

      final optionData = OptionData(
        token: token,
        symbol: trdSymbol,
        scripRefKey: trdSymbol,
        trdSymbol: trdSymbol,
        optionType: optionType,
      );

      if (optionType == 'CE') {
        strikeMap[validStrike] = OptionChainEntry(
          strike: validStrike,
          expiry: validExpiry,
          ce: optionData,
          pe: entry.pe,
        );
      } else {
        strikeMap[validStrike] = OptionChainEntry(
          strike: validStrike,
          expiry: validExpiry,
          ce: entry.ce,
          pe: optionData,
        );
      }
    }

    debugPrint(
      '_fetchFromCloudWorker: processed=$processed, skippedSymbol=$skippedSymbol, '
      'skippedOptionType=$skippedOptionType, skippedExpiry=$skippedExpiry, '
      'skippedStrike=$skippedStrike, expiries=${expiryMap.length}',
    );

    final chains = <String, List<OptionChainEntry>>{};
    for (final e in expiryMap.entries) {
      chains[e.key] = e.value.values.toList()
        ..sort((a, b) => a.strike.compareTo(b.strike));
    }

    return {'chains': chains, 'indices': indices.toList()};
  }

  // ---------------------------------------------------------------------------
  // Expiry String Helpers
  // ---------------------------------------------------------------------------

  /// Normalizes a raw expiry string (epoch timestamp, date string, etc.) to DDMMMYY format.
  String _normalizeExpiryString(String raw) {
    // Handle Kotak 1980-epoch numeric timestamps
    final doubleVal = double.tryParse(raw.trim());
    if (doubleVal != null && doubleVal > 100000000) {
      final numericVal = doubleVal.toInt();
      final seconds = numericVal > 10000000000 ? numericVal ~/ 1000 : numericVal;
      // Kotak Neo uses 1980 epoch — add 315,532,800s offset to get standard Unix epoch
      final realSeconds = seconds + 315532800;
      final dt = DateTime.fromMillisecondsSinceEpoch(realSeconds * 1000, isUtc: true);
      const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
      final day = dt.day.toString().padLeft(2, '0');
      final month = months[dt.month - 1];
      final year = (dt.year % 100).toString().padLeft(2, '0');
      return '$day$month$year';
    }

    final clean = raw.replaceAll('-', '').replaceAll('/', '').toUpperCase().trim();
    if (clean.length == 7 && RegExp(r'^\d{2}[A-Z]{3}\d{2}$').hasMatch(clean)) {
      return clean;
    }

    final dt = DateTime.tryParse(raw);
    if (dt != null) {
      const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
      final day = dt.day.toString().padLeft(2, '0');
      final month = months[dt.month - 1];
      final year = (dt.year % 100).toString().padLeft(2, '0');
      return '$day$month$year';
    }
    return clean;
  }

  /// Parses an expiry string to DateTime for sorting/comparison.
  DateTime? _parseExpiryToDateTime(String expiryStr) {
    try {
      final clean = expiryStr.trim().toUpperCase();

      // Numeric Kotak 1980-epoch timestamp
      final doubleVal = double.tryParse(clean);
      if (doubleVal != null && doubleVal > 100000000) {
        final numericVal = doubleVal.toInt();
        final seconds = numericVal > 10000000000 ? numericVal ~/ 1000 : numericVal;
        final realSeconds = seconds + 315532800;
        return DateTime.fromMillisecondsSinceEpoch(realSeconds * 1000, isUtc: true);
      }

      const monthMap = {
        'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
        'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
      };

      // DDMMMYY format (e.g. 28JUL26)
      if (clean.length >= 7) {
        final dayStr = clean.substring(0, 2);
        final monthStr = clean.substring(2, 5);
        final yearStr = clean.substring(5, 7);
        final month = monthMap[monthStr];
        final dayNum = int.tryParse(dayStr);
        final yearNum = int.tryParse(yearStr);
        if (month != null && dayNum != null && yearNum != null) {
          return DateTime(2000 + yearNum, month, dayNum);
        }
      }

      // YYMMM format (e.g. 26JUL)
      if (clean.length == 5) {
        final yearStr = clean.substring(0, 2);
        final monthStr = clean.substring(2, 5);
        final month = monthMap[monthStr];
        final yearNum = int.tryParse(yearStr);
        if (month != null && yearNum != null) {
          return DateTime(2000 + yearNum, month, 1);
        }
      }

      return DateTime.tryParse(clean);
    } catch (e) {
      debugPrint('Failed to parse expiry: $expiryStr - $e');
      return null;
    }
  }
}
