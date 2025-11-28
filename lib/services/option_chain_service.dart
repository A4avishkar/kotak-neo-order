import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/option_chain_entry.dart';
import 'scrip_master_service.dart';

// Top-level function for isolate (must be outside class)
Future<Map<String, List<OptionChainEntry>>> _parseCsvInIsolate(Map<String, dynamic> params) async {
  final filePath = params['filePath'] as String;
  final symbol = params['symbol'] as String? ?? 'NIFTY'; // Default to NIFTY for backward compatibility
  final file = File(filePath);
  
  final bytes = await file.readAsBytes();
  final raw = _decodeCsvPayloadIsolate(bytes, filePath);
  final normalizedRaw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final suspectedDelimiter = normalizedRaw.contains('|') ? '|' : ',';
  
  final rows = CsvToListConverter(
    shouldParseNumbers: false,
    fieldDelimiter: suspectedDelimiter,
    eol: '\n',
  ).convert(normalizedRaw);
  
  if (rows.isEmpty) {
    throw Exception('CSV file is empty');
  }

  // Find header row
  List<String>? header;
  int headerRowIndex = -1;
  int symbolNameIdx = -1;
  int symbolIdx = -1;
  int optionTypeIdx = -1;
  int scripRefKeyIdx = -1;
  int trdSymbolIdx = -1; // pTrdSymbol column index

  for (var i = 0; i < rows.length && i < 100; i++) { // Limit search to first 100 rows
    final candidate = rows[i]
        .map((cell) => cell?.toString().replaceAll('\ufeff', '').trim() ?? '')
        .toList();
    
    final nameIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'psymbolname',
    );
    final symIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'psymbol',
    );
    final optIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'poptiontype',
    );
    final refIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'pscriprefkey',
    );
    final trdIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'ptrdsymbol',
    );
    
    if (nameIdx != -1 && symIdx != -1 && optIdx != -1 && refIdx != -1) {
      header = candidate;
      headerRowIndex = i;
      symbolNameIdx = nameIdx;
      symbolIdx = symIdx;
      optionTypeIdx = optIdx;
      scripRefKeyIdx = refIdx;
      trdSymbolIdx = trdIdx; // pTrdSymbol is optional, -1 if not found
      break;
    }
  }

  if (header == null || headerRowIndex == -1) {
    throw Exception('Required columns not found in CSV');
  }

  // Pre-compile regex patterns for better performance (dynamic based on symbol)
  final symbolEscaped = RegExp.escape(symbol);
  final expiryRegex = RegExp('$symbolEscaped(\\d{2}[A-Z]{3}\\d{2})');
  final strikeRegex = RegExp('$symbolEscaped\\d{2}[A-Z]{3}\\d{2}(\\d+)\\.\\d+(CE|PE)\$');
  
  // Filter for specified symbol and extract data
  final Map<String, Map<double, OptionChainEntry>> expiryMap = {};
  
  int processedCount = 0;
  int symbolCount = 0;
  
  for (int i = headerRowIndex + 1; i < rows.length; i++) {
    final row = rows[i];
    
    // Quick length check first
    if (row.length <= scripRefKeyIdx) continue;
    
    // Fast path: Check scripRefKey first (options start with symbol name)
    // This avoids checking symbolName for most rows
    final scripRefKeyRaw = row[scripRefKeyIdx]?.toString();
    if (scripRefKeyRaw == null || scripRefKeyRaw.isEmpty) continue;
    
    final scripRefKey = scripRefKeyRaw.trim();
    if (!scripRefKey.startsWith(symbol)) continue;
    
    // Now verify it's actually the correct symbol by checking symbolName
    if (row.length <= symbolNameIdx) continue;
    final symbolName = (row[symbolNameIdx]?.toString() ?? '').trim();
    if (symbolName != symbol) continue;
    
    // We have a matching option - process it
    symbolCount++;
    if (row.length <= symbolIdx || row.length <= optionTypeIdx) continue;
    
    final token = (row[symbolIdx]?.toString() ?? '').trim();
    final optionType = (row[optionTypeIdx]?.toString() ?? '').trim();
    
    if (token.isEmpty || optionType.isEmpty) continue;
    
    // Read pTrdSymbol from CSV if available (correct format for order placement)
    String? trdSymbol;
    if (trdSymbolIdx != -1 && row.length > trdSymbolIdx) {
      final trdSymbolRaw = row[trdSymbolIdx]?.toString();
      if (trdSymbolRaw != null && trdSymbolRaw.trim().isNotEmpty) {
        trdSymbol = trdSymbolRaw.trim();
      }
    }
    
    // Extract expiry and strike using pre-compiled regex
    final expiryMatch = expiryRegex.firstMatch(scripRefKey);
    final strikeMatch = strikeRegex.firstMatch(scripRefKey);
    
    if (expiryMatch == null || strikeMatch == null) continue;
    
    final expiry = expiryMatch.group(1);
    final strikeStr = strikeMatch.group(1);
    if (expiry == null || strikeStr == null) continue;
    
    final strike = double.tryParse(strikeStr);
    if (strike == null) continue;
    
    final strikeMap = expiryMap.putIfAbsent(expiry, () => {});
    final entry = strikeMap.putIfAbsent(
      strike,
      () => OptionChainEntry(strike: strike, expiry: expiry),
    );
    
    final optionData = OptionData(
      token: token,
      symbol: scripRefKey,
      scripRefKey: scripRefKey,
      trdSymbol: trdSymbol,
      optionType: optionType,
    );
    
    if (optionType == 'CE') {
      strikeMap[strike] = OptionChainEntry(
        strike: strike,
        expiry: expiry,
        ce: optionData,
        pe: entry.pe,
      );
    } else if (optionType == 'PE') {
      strikeMap[strike] = OptionChainEntry(
        strike: strike,
        expiry: expiry,
        ce: entry.ce,
        pe: optionData,
      );
    }
    
    processedCount++;
  }

  // Convert to final format
  final result = <String, List<OptionChainEntry>>{};
  for (final entry in expiryMap.entries) {
    final expiry = entry.key;
    final entries = entry.value.values.toList();
    entries.sort((a, b) => a.strike.compareTo(b.strike));
    result[expiry] = entries;
  }
  
  return result;
}

// Top-level function to get available indices from CSV
Future<List<String>> _getAvailableIndicesInIsolate(Map<String, dynamic> params) async {
  final filePath = params['filePath'] as String;
  final file = File(filePath);
  
  final bytes = await file.readAsBytes();
  final raw = _decodeCsvPayloadIsolate(bytes, filePath);
  final normalizedRaw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final suspectedDelimiter = normalizedRaw.contains('|') ? '|' : ',';
  
  final rows = CsvToListConverter(
    shouldParseNumbers: false,
    fieldDelimiter: suspectedDelimiter,
    eol: '\n',
  ).convert(normalizedRaw);
  
  if (rows.isEmpty) {
    return [];
  }

  // Find header row
  int symbolNameIdx = -1;
  int optionTypeIdx = -1;

  for (var i = 0; i < rows.length && i < 100; i++) {
    final candidate = rows[i]
        .map((cell) => cell?.toString().replaceAll('\ufeff', '').trim() ?? '')
        .toList();
    
    final nameIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'psymbolname',
    );
    final optIdx = candidate.indexWhere(
      (column) => column.toLowerCase() == 'poptiontype',
    );
    
    if (nameIdx != -1 && optIdx != -1) {
      symbolNameIdx = nameIdx;
      optionTypeIdx = optIdx;
      break;
    }
  }

  if (symbolNameIdx == -1 || optionTypeIdx == -1) {
    return [];
  }

  // Collect unique indices that have options (CE or PE)
  final Set<String> indices = {};
  
  for (int i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length <= symbolNameIdx || row.length <= optionTypeIdx) continue;
    
    final symbolName = (row[symbolNameIdx]?.toString() ?? '').trim();
    final optionType = (row[optionTypeIdx]?.toString() ?? '').trim();
    
    // Only include symbols that have options (CE or PE)
    if (symbolName.isNotEmpty && (optionType == 'CE' || optionType == 'PE')) {
      indices.add(symbolName);
    }
  }
  
  // Sort indices (NIFTY first, then alphabetically)
  final sortedIndices = indices.toList()..sort((a, b) {
    if (a == 'NIFTY') return -1;
    if (b == 'NIFTY') return 1;
    if (a == 'BANKNIFTY') return -1;
    if (b == 'BANKNIFTY') return 1;
    if (a == 'FINNIFTY') return -1;
    if (b == 'FINNIFTY') return 1;
    return a.compareTo(b);
  });
  
  return sortedIndices;
}

String _decodeCsvPayloadIsolate(List<int> bytes, String filePath) {
  String? result;

  String? tryDecode(String label, List<int> payload) {
    try {
      return utf8.decode(payload);
    } catch (error) {
      return null;
    }
  }

  String? tryGzip() {
    try {
      final decoded = GZipCodec().decode(bytes);
      return utf8.decode(decoded);
    } catch (_) {
      return null;
    }
  }

  String? tryZlib() {
    try {
      final decoded = ZLibDecoder().decodeBytes(bytes);
      return utf8.decode(decoded);
    } catch (_) {
      return null;
    }
  }

  String? tryZip() {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final data = file.content as List<int>;
        final decoded = tryDecode('zip-entry', data);
        if (decoded != null) {
          return decoded;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  result = tryGzip();
  result ??= tryZip();
  result ??= tryZlib();
  result ??= tryDecode('utf8', bytes);
  result ??= utf8.decode(bytes, allowMalformed: true);

  return result;
}

class OptionChainService {
  // Cache for nearest expiry (most commonly used) - per segment and symbol
  Map<String, Map<String, List<OptionChainEntry>>> _nearestExpiryCache = {}; // segment -> symbol -> entries
  Map<String, Map<String, String>> _cachedNearestExpiry = {}; // segment -> symbol -> expiry
  
  // Cache for all expiries (loaded on demand) - per segment and symbol
  Map<String, Map<String, Map<String, List<OptionChainEntry>>>> _allExpiriesCache = {}; // segment -> symbol -> expiry -> entries
  
  // Cache for sorted expiry lists - per segment and symbol (avoids re-sorting)
  Map<String, Map<String, List<String>>> _sortedExpiriesCache = {}; // segment -> symbol -> sorted expiry list
  
  // Cache for available indices - per segment
  Map<String, List<String>> _availableIndicesCache = {};
  
  // Cache for available segments
  List<String>? _availableSegmentsCache;
  
  static const Map<String, String> segmentDisplayNames = {
    'nse_fo': 'NSE F&O',
    'bse_fo': 'BSE F&O',
    'mcx_fo': 'MCX F&O',
    'cde_fo': 'CDE F&O',
  };
  
  /// Gets available F&O segments
  Future<List<String>> getAvailableFoSegments() async {
    if (_availableSegmentsCache != null) {
      return _availableSegmentsCache!;
    }
    
    try {
      final scripMasterService = ScripMasterService();
      final state = await scripMasterService.describeLocal();
      
      // Get all F&O segments that have files
      final foSegments = state.segments
          .where((s) => s.segmentCode.endsWith('_fo') && s.filePath != null)
          .map((s) => s.segmentCode)
          .toList();
      
      // Sort: nse_fo first, then bse_fo, then others
      foSegments.sort((a, b) {
        if (a == 'nse_fo') return -1;
        if (b == 'nse_fo') return 1;
        if (a == 'bse_fo') return -1;
        if (b == 'bse_fo') return 1;
        return a.compareTo(b);
      });
      
      _availableSegmentsCache = foSegments;
      return foSegments;
    } catch (e) {
      debugPrint('Error getting available segments: $e');
      // Default to nse_fo if we can't get segments
      return ['nse_fo'];
    }
  }
  
  /// Gets available indices from the CSV file for a given segment
  Future<List<String>> getAvailableIndices({String segment = 'nse_fo'}) async {
    if (_availableIndicesCache.containsKey(segment)) {
      return _availableIndicesCache[segment]!;
    }
    
    final csvFile = await _findScripMasterFile(segment: segment);
    final indices = await compute(_getAvailableIndicesInIsolate, {
      'filePath': csvFile.path,
    });
    _availableIndicesCache[segment] = indices;
    return indices;
  }
  
  /// Loads nearest expiry option chain data (fast path - optimized for most common use case)
  /// This is cached separately for instant access
  Future<List<OptionChainEntry>> loadNearestExpiry({String symbol = 'NIFTY', String segment = 'nse_fo'}) async {
    // Check if we already have the nearest expiry cached for this segment and symbol
    if (_nearestExpiryCache.containsKey(segment) && 
        _nearestExpiryCache[segment]!.containsKey(symbol) &&
        _cachedNearestExpiry.containsKey(segment) &&
        _cachedNearestExpiry[segment]!.containsKey(symbol)) {
      debugPrint('Returning cached nearest expiry for $symbol in $segment: ${_cachedNearestExpiry[segment]![symbol]}');
      return _nearestExpiryCache[segment]![symbol]!;
    }
    
    // If we have all expiries cached for this segment and symbol, just extract nearest expiry
    if (_allExpiriesCache.containsKey(segment) && _allExpiriesCache[segment]!.containsKey(symbol)) {
      final nearestExpiryStr = await getNearestExpiry(symbol: symbol, segment: segment);
      if (nearestExpiryStr != null && _allExpiriesCache[segment]![symbol]!.containsKey(nearestExpiryStr)) {
        _nearestExpiryCache.putIfAbsent(segment, () => {})[symbol] = _allExpiriesCache[segment]![symbol]![nearestExpiryStr]!;
        _cachedNearestExpiry.putIfAbsent(segment, () => {})[symbol] = nearestExpiryStr;
        debugPrint('Extracted nearest expiry from cache for $symbol in $segment: $nearestExpiryStr (${_nearestExpiryCache[segment]![symbol]!.length} strikes)');
        return _nearestExpiryCache[segment]![symbol]!;
      }
    }
    
    // Parse CSV once and cache everything for this segment and symbol
    debugPrint('Parsing CSV in background isolate for $symbol in $segment (one-time parse)...');
    final csvFile = await _findScripMasterFile(segment: segment);
    final allChains = await compute(_parseCsvInIsolate, {
      'filePath': csvFile.path,
      'symbol': symbol,
    });
    debugPrint('CSV parsing completed in isolate for $symbol in $segment');
    
    // Cache all expiries for this segment and symbol
    _allExpiriesCache.putIfAbsent(segment, () => {})[symbol] = allChains;
    
    // Get nearest expiry from parsed data
    final expiries = allChains.keys.toList();
    expiries.sort((a, b) {
      final dateA = _parseExpiryToDateTime(a);
      final dateB = _parseExpiryToDateTime(b);
      if (dateA == null || dateB == null) return a.compareTo(b);
      return dateA.compareTo(dateB);
    });
    
    // Cache sorted expiries for fast future access
    _sortedExpiriesCache.putIfAbsent(segment, () => {})[symbol] = expiries;
    
    final nearestExpiryStr = expiries.isNotEmpty ? expiries.first : null;
    if (nearestExpiryStr == null) {
      throw Exception('No expiry found for $symbol in $segment');
    }
    
    // Cache nearest expiry separately
    _nearestExpiryCache.putIfAbsent(segment, () => {})[symbol] = allChains[nearestExpiryStr] ?? [];
    _cachedNearestExpiry.putIfAbsent(segment, () => {})[symbol] = nearestExpiryStr;
    
    debugPrint('Cached nearest expiry for $symbol in $segment: $nearestExpiryStr (${_nearestExpiryCache[segment]![symbol]!.length} strikes)');
    return _nearestExpiryCache[segment]![symbol]!;
  }
  
  /// Gets all available expiries (lightweight - just expiry strings)
  Future<List<String>> getAvailableExpiries({String symbol = 'NIFTY', String segment = 'nse_fo'}) async {
    // If we have cached sorted expiries, return immediately (fastest path)
    if (_sortedExpiriesCache.containsKey(segment) && _sortedExpiriesCache[segment]!.containsKey(symbol)) {
      debugPrint('Returning cached sorted expiries for $symbol in $segment');
      return _sortedExpiriesCache[segment]![symbol]!;
    }
    
    // If we have cached data for this segment and symbol, sort and cache the sorted list
    if (_allExpiriesCache.containsKey(segment) && _allExpiriesCache[segment]!.containsKey(symbol)) {
      final expiries = _allExpiriesCache[segment]![symbol]!.keys.toList();
      expiries.sort((a, b) {
        final dateA = _parseExpiryToDateTime(a);
        final dateB = _parseExpiryToDateTime(b);
        if (dateA == null || dateB == null) return a.compareTo(b);
        return dateA.compareTo(dateB);
      });
      // Cache the sorted list for future use
      _sortedExpiriesCache.putIfAbsent(segment, () => {})[symbol] = expiries;
      return expiries;
    }
    
    // Otherwise, parse just to get expiry list (lightweight)
    final csvFile = await _findScripMasterFile(segment: segment);
    
    // Parse CSV in background isolate
    debugPrint('Parsing CSV in background isolate for expiry list for $symbol in $segment...');
    final allChains = await compute(_parseCsvInIsolate, {
      'filePath': csvFile.path,
      'symbol': symbol,
    });
    _allExpiriesCache.putIfAbsent(segment, () => {})[symbol] = allChains;
    debugPrint('CSV parsing completed in isolate for $symbol in $segment');
    
    final expiries = allChains.keys.toList();
    expiries.sort((a, b) {
      final dateA = _parseExpiryToDateTime(a);
      final dateB = _parseExpiryToDateTime(b);
      if (dateA == null || dateB == null) return a.compareTo(b);
      return dateA.compareTo(dateB);
    });
    
    // Cache the sorted list for future use
    _sortedExpiriesCache.putIfAbsent(segment, () => {})[symbol] = expiries;
    
    return expiries;
  }

  /// Loads all option chain data from scrip master CSV for a given symbol and segment
  /// Returns a map of expiry -> list of option chain entries
  /// Note: Use loadNearestExpiry() for faster access to most common expiry
  Future<Map<String, List<OptionChainEntry>>> loadAllOptionChains({String symbol = 'NIFTY', String segment = 'nse_fo'}) async {
    // Return cached data if available for this segment and symbol
    if (_allExpiriesCache.containsKey(segment) && _allExpiriesCache[segment]!.containsKey(symbol)) {
      debugPrint('Returning cached all expiries data for $symbol in $segment');
      return _allExpiriesCache[segment]![symbol]!;
    }
    
    final csvFile = await _findScripMasterFile(segment: segment);
    
    // Parse CSV in background isolate
    debugPrint('Parsing CSV in background isolate for all expiries for $symbol in $segment...');
    final allChains = await compute(_parseCsvInIsolate, {
      'filePath': csvFile.path,
      'symbol': symbol,
    });
    debugPrint('CSV parsing completed in isolate for $symbol in $segment');
    
    // Cache for future use
    _allExpiriesCache.putIfAbsent(segment, () => {})[symbol] = allChains;
    
    // Also cache nearest expiry if not already cached
    if (!_nearestExpiryCache.containsKey(segment) || !_nearestExpiryCache[segment]!.containsKey(symbol)) {
      final nearestExpiry = await getNearestExpiry(symbol: symbol, segment: segment);
      if (nearestExpiry != null && allChains.containsKey(nearestExpiry)) {
        _nearestExpiryCache.putIfAbsent(segment, () => {})[symbol] = allChains[nearestExpiry]!;
        _cachedNearestExpiry.putIfAbsent(segment, () => {})[symbol] = nearestExpiry;
      }
    }
    
    return allChains;
  }
  
  /// Finds the scrip master CSV file for a given segment (helper method)
  Future<File> _findScripMasterFile({String segment = 'nse_fo'}) async {
    File? csvFile;
    
    // Try to get from ScripMasterService (app documents directory)
    try {
      final scripMasterService = ScripMasterService();
      final state = await scripMasterService.describeLocal();
      
      // Find the requested segment - handle case where segment might not exist
      ScripMasterSegmentStatus? segmentStatus;
      try {
        segmentStatus = state.segments.firstWhere(
          (s) => s.segmentCode == segment,
        );
      } catch (e) {
        debugPrint('Segment $segment not found in ScripMasterService state, checking all segments');
        // List all available segments for debugging
        for (final seg in state.segments) {
          debugPrint('Available segment: ${seg.segmentCode}, state: ${seg.state}, filePath: ${seg.filePath}');
        }
      }
      
      if (segmentStatus != null && segmentStatus.filePath != null) {
        final file = File(segmentStatus.filePath!);
        if (await file.exists()) {
          final stat = await file.stat();
          // Check if file has reasonable size (at least 1KB)
          if (stat.size > 1024) {
            csvFile = file;
            debugPrint('Found $segment scrip master in app documents: ${file.path} (${stat.size} bytes)');
            return csvFile;
          } else {
            debugPrint('App documents file too small (${stat.size} bytes), will try project directory');
          }
        } else {
          debugPrint('ScripMasterService reported file path but file does not exist: ${segmentStatus.filePath}');
        }
      } else {
        debugPrint('Segment $segment not found or has no filePath in ScripMasterService');
      }
    } catch (e, stackTrace) {
      debugPrint('Could not find scrip master in app documents: $e');
      debugPrint('Stack trace: $stackTrace');
    }
    
    // Fallback: Try project's scrip_masters directory (for development/desktop only)
    // Note: This won't work on Android/iOS, but useful for desktop development
    if (csvFile == null || !await csvFile.exists()) {
      try {
        // Try multiple possible project root locations
        final possibleRoots = [
          Directory.current,
          // Try to find project root by looking for pubspec.yaml
          Directory(path.join(Directory.current.path, '..')),
          Directory(path.join(Directory.current.path, '../..')),
        ];
        
        for (final rootDir in possibleRoots) {
          try {
            final projectScripMastersDir = Directory(path.join(rootDir.path, 'scrip_masters'));
            
            if (await projectScripMastersDir.exists()) {
              debugPrint('Checking project directory: ${projectScripMastersDir.path}');
              // Find the most recent file for the requested segment
              final entities = await projectScripMastersDir.list().toList();
              final files = entities
                  .whereType<File>()
                  .where((f) => 
                      path.basename(f.path).startsWith('${segment}_scrip_master_') &&
                      f.path.endsWith('.csv'))
                  .toList();
              
              if (files.isNotEmpty) {
                // Get file stats and sort by modification time (most recent first)
                final fileStats = await Future.wait(
                  files.map((f) async => (file: f, stat: await f.stat())),
                );
                fileStats.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
                
                if (fileStats.isNotEmpty) {
                  csvFile = fileStats.first.file;
                  debugPrint('Found $segment scrip master in project directory: ${csvFile?.path}');
                  return csvFile;
                }
              }
            }
          } catch (e) {
            // Continue to next possible root
            continue;
          }
        }
      } catch (e) {
        debugPrint('Could not find scrip master in project directory: $e');
      }
    }
    
    // Final check and error message
    if (csvFile == null || !await csvFile.exists()) {
      final segmentName = segmentDisplayNames[segment] ?? segment.toUpperCase();
      throw Exception(
        '$segmentName scrip master not found.\n'
        'Please download it from Settings screen (Settings > Download Scrip Masters).\n'
        'The file ${segment}_scrip_master_*.csv should exist in the app documents directory.'
      );
    }
    
    return csvFile;
  }

  /// Loads option chain for a specific expiry
  /// Optimized: Uses cache if available, loads on demand if not
  Future<List<OptionChainEntry>> loadOptionChainForExpiry(String expiry, {String symbol = 'NIFTY', String segment = 'nse_fo'}) async {
    // If requesting nearest expiry and we have it cached, return immediately
    if (_cachedNearestExpiry.containsKey(segment) &&
        _cachedNearestExpiry[segment]!.containsKey(symbol) &&
        expiry == _cachedNearestExpiry[segment]![symbol] &&
        _nearestExpiryCache.containsKey(segment) &&
        _nearestExpiryCache[segment]!.containsKey(symbol)) {
      debugPrint('Returning cached nearest expiry for $symbol in $segment: $expiry');
      return _nearestExpiryCache[segment]![symbol]!;
    }
    
    // If we have all expiries cached for this segment and symbol, use it
    if (_allExpiriesCache.containsKey(segment) &&
        _allExpiriesCache[segment]!.containsKey(symbol) &&
        _allExpiriesCache[segment]![symbol]!.containsKey(expiry)) {
      debugPrint('Returning cached expiry for $symbol in $segment: $expiry');
      return _allExpiriesCache[segment]![symbol]![expiry]!;
    }
    
    // Otherwise, load all chains (will cache for future use)
    debugPrint('Loading expiry on demand for $symbol in $segment: $expiry');
    final allChains = await loadAllOptionChains(symbol: symbol, segment: segment);
    return allChains[expiry] ?? [];
  }
  
  /// Clears the cache (useful when scrip master is updated)
  void clearCache() {
    _nearestExpiryCache.clear();
    _cachedNearestExpiry.clear();
    _allExpiriesCache.clear();
    _sortedExpiriesCache.clear();
    _availableIndicesCache.clear();
    _availableSegmentsCache = null;
    debugPrint('Option chain cache cleared');
  }

  /// Gets the nearest expiry (closest future expiry, or latest past if none)
  Future<String?> getNearestExpiry({String symbol = 'NIFTY', String segment = 'nse_fo'}) async {
    // If we have cached data for this segment and symbol, use it directly (no need to parse)
    if (_allExpiriesCache.containsKey(segment) && _allExpiriesCache[segment]!.containsKey(symbol)) {
      final expiries = _allExpiriesCache[segment]![symbol]!.keys.toList();
      expiries.sort((a, b) {
        final dateA = _parseExpiryToDateTime(a);
        final dateB = _parseExpiryToDateTime(b);
        if (dateA == null || dateB == null) return a.compareTo(b);
        return dateA.compareTo(dateB);
      });
      
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      
      // Find first future expiry
      for (final expiry in expiries) {
        final expiryDate = _parseExpiryToDateTime(expiry);
        if (expiryDate != null && (expiryDate.isAfter(today) || expiryDate.isAtSameMomentAs(today))) {
          return expiry;
        }
      }
      return expiries.isNotEmpty ? expiries.first : null;
    }
    
    // Otherwise, get from available expiries (will parse if needed)
    final expiries = await getAvailableExpiries(symbol: symbol, segment: segment);
    if (expiries.isEmpty) return null;
    
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Find first future expiry
    for (final expiry in expiries) {
      final expiryDate = _parseExpiryToDateTime(expiry);
      if (expiryDate != null && (expiryDate.isAfter(today) || expiryDate.isAtSameMomentAs(today))) {
        return expiry;
      }
    }
    
    // If no future expiry, return the latest one
    return expiries.last;
  }

  Future<Map<String, List<OptionChainEntry>>> _parseScripMasterCsv(File csvFile) async {
    debugPrint('Parsing scrip master CSV file: ${csvFile.path}');
    
    // Check file size
    final fileStat = await csvFile.stat();
    debugPrint('CSV file size: ${fileStat.size} bytes');
    
    // Read as bytes first (like scrip_search_service does)
    final bytes = await csvFile.readAsBytes();
    final raw = _decodeCsvPayload(bytes, csvFile.path);
    final normalizedRaw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    
    // Detect delimiter (pipe or comma)
    final suspectedDelimiter = normalizedRaw.contains('|') ? '|' : ',';
    debugPrint('Detected delimiter: "$suspectedDelimiter"');
    
    // Parse CSV with detected delimiter
    final rows = CsvToListConverter(
      shouldParseNumbers: false,
      fieldDelimiter: suspectedDelimiter,
      eol: '\n',
    ).convert(normalizedRaw);
    
    if (rows.isEmpty) {
      throw Exception('CSV file is empty');
    }

    debugPrint('CSV has ${rows.length} rows');

    // Find header row (might not be first row)
    List<String>? header;
    int headerRowIndex = -1;
    int symbolNameIdx = -1;
    int symbolIdx = -1;
    int optionTypeIdx = -1;
    int scripRefKeyIdx = -1;
    int trdSymbolIdx = -1; // pTrdSymbol column index

    for (var i = 0; i < rows.length; i++) {
      final candidate = rows[i]
          .map((cell) => cell?.toString().replaceAll('\ufeff', '').trim() ?? '')
          .toList();
      
      final nameIdx = candidate.indexWhere(
        (column) => column.toLowerCase() == 'psymbolname',
      );
      final symIdx = candidate.indexWhere(
        (column) => column.toLowerCase() == 'psymbol',
      );
      final optIdx = candidate.indexWhere(
        (column) => column.toLowerCase() == 'poptiontype',
      );
      final refIdx = candidate.indexWhere(
        (column) => column.toLowerCase() == 'pscriprefkey',
      );
      final trdIdx = candidate.indexWhere(
        (column) => column.toLowerCase() == 'ptrdsymbol',
      );
      
      if (nameIdx != -1 && symIdx != -1 && optIdx != -1 && refIdx != -1) {
        header = candidate;
        headerRowIndex = i;
        symbolNameIdx = nameIdx;
        symbolIdx = symIdx;
        optionTypeIdx = optIdx;
        scripRefKeyIdx = refIdx;
        trdSymbolIdx = trdIdx; // pTrdSymbol is optional, -1 if not found
        break;
      }
    }

    if (header == null || headerRowIndex == -1) {
      throw Exception(
        'Required columns not found in CSV.\n'
        'Searched first ${rows.length > 10 ? 10 : rows.length} rows.\n'
        'Required: pSymbolName, pSymbol, pOptionType, pScripRefKey'
      );
    }

    debugPrint('Found header at row $headerRowIndex');
    debugPrint('CSV header columns (${header.length}): ${header.take(10).join(', ')}...');
    
    // Filter for NIFTY and extract data
    final Map<String, Map<double, OptionChainEntry>> expiryMap = {};
    
    int niftyCount = 0;
    for (int i = headerRowIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length <= symbolNameIdx || row.length <= symbolIdx) continue;

      final symbolName = (row[symbolNameIdx]?.toString() ?? '').trim();
      
      // Only process NIFTY options
      if (symbolName != 'NIFTY') continue;
      
      niftyCount++;
      
      final token = (row[symbolIdx]?.toString() ?? '').trim();
      final optionType = (row[optionTypeIdx]?.toString() ?? '').trim();
      final scripRefKey = (row[scripRefKeyIdx]?.toString() ?? '').trim();
      
      if (token.isEmpty || optionType.isEmpty || scripRefKey.isEmpty) continue;
      
      // Read pTrdSymbol from CSV if available (correct format for order placement)
      String? trdSymbol;
      if (trdSymbolIdx != -1 && row.length > trdSymbolIdx) {
        final trdSymbolRaw = row[trdSymbolIdx]?.toString();
        if (trdSymbolRaw != null && trdSymbolRaw.trim().isNotEmpty) {
          trdSymbol = trdSymbolRaw.trim();
        }
      }
      
      // Extract expiry and strike from pScripRefKey
      // Format: NIFTY[DDMMMYY][STRIKE].00[CE/PE]
      // Example: NIFTY25NOV2525000.00CE
      final expiry = _extractExpiry(scripRefKey, 'NIFTY');
      final strike = _extractStrikePrice(scripRefKey, 'NIFTY');
      
      if (expiry == null || strike == null) {
        debugPrint('Failed to parse expiry or strike from: $scripRefKey');
        continue;
      }
      
      // Get or create expiry map
      final strikeMap = expiryMap.putIfAbsent(expiry, () => {});

      // Get or create entry for this strike
      final entry = strikeMap.putIfAbsent(
        strike,
        () => OptionChainEntry(strike: strike, expiry: expiry),
      );

      // Create option data
      final optionData = OptionData(
        token: token,
        symbol: scripRefKey,
        trdSymbol: trdSymbol,
        scripRefKey: scripRefKey,
        optionType: optionType,
      );

      // Assign to CE or PE
      if (optionType == 'CE') {
        strikeMap[strike] = OptionChainEntry(
          strike: strike,
          expiry: expiry,
          ce: optionData,
          pe: entry.pe,
        );
      } else if (optionType == 'PE') {
        strikeMap[strike] = OptionChainEntry(
          strike: strike,
          expiry: expiry,
          ce: entry.ce,
          pe: optionData,
        );
      }
    }

    debugPrint('Found $niftyCount NIFTY option rows');
    
    // Convert to final format: expiry -> sorted list of entries
    final result = <String, List<OptionChainEntry>>{};
    for (final entry in expiryMap.entries) {
      final expiry = entry.key;
      final entries = entry.value.values.toList();
    entries.sort((a, b) => a.strike.compareTo(b.strike));
      result[expiry] = entries;
    }
    
    debugPrint('Parsed ${result.length} expiries with ${result.values.fold<int>(0, (sum, list) => sum + list.length)} total entries');
    return result;
  }

  /// Extracts expiry string from pScripRefKey
  /// Format: SYMBOL[DDMMMYY][STRIKE].00[CE/PE]
  /// Example: NIFTY25NOV2525000.00CE -> 25NOV25
  String? _extractExpiry(String scripRefKey, String symbol) {
    // Pattern: SYMBOL followed by DDMMMYY
    final symbolEscaped = RegExp.escape(symbol);
    final match = RegExp('$symbolEscaped(\\d{2}[A-Z]{3}\\d{2})').firstMatch(scripRefKey);
    if (match != null) {
      return match.group(1);
    }
    return null;
  }

  /// Extracts strike price from pScripRefKey
  /// Format: SYMBOL[DDMMMYY][STRIKE].00[CE/PE]
  /// Example: NIFTY25NOV2525000.00CE -> 25000
  double? _extractStrikePrice(String scripRefKey, String symbol) {
    // Pattern: SYMBOL followed by DDMMMYY, then capture the strike price
    final symbolEscaped = RegExp.escape(symbol);
    final match = RegExp('$symbolEscaped\\d{2}[A-Z]{3}\\d{2}(\\d+)\\.\\d+(CE|PE)\$').firstMatch(scripRefKey);
    if (match != null) {
      final strikeStr = match.group(1);
      if (strikeStr != null) {
        return double.tryParse(strikeStr);
      }
    }
    return null;
  }

  /// Parses expiry string to DateTime
  /// Format: DDMMMYY (e.g., 25NOV25 -> November 25, 2025)
  DateTime? _parseExpiryToDateTime(String expiryStr) {
    try {
      // Format: 25NOV25 -> day (2 digits), month abbreviation (3 letters), year (2 digits)
      // We need to parse: %d%b%y
      final day = expiryStr.substring(0, 2);
      final monthStr = expiryStr.substring(2, 5);
      final yearStr = expiryStr.substring(5, 7);
      
      // Convert 2-digit year to 4-digit (assuming 20xx)
      final year = 2000 + int.parse(yearStr);
      
      // Map month abbreviations to numbers
      const monthMap = {
        'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
        'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
      };
      
      final month = monthMap[monthStr];
      if (month == null) return null;
      
      final dayNum = int.parse(day);
      
      return DateTime(year, month, dayNum);
    } catch (e) {
      debugPrint('Failed to parse expiry: $expiryStr - $e');
      return null;
    }
  }

  /// Decodes CSV payload, handling compression and encoding (from scrip_search_service.dart)
  String _decodeCsvPayload(List<int> bytes, String filePath) {
    String? result;

    String? tryDecode(String label, List<int> payload) {
      try {
        return utf8.decode(payload);
      } catch (error, stackTrace) {
        debugPrint(
          'OptionChainService: Failed to decode $label for $filePath: '
          '$error\n$stackTrace',
        );
        return null;
      }
    }

    String? tryGzip() {
      try {
        final decoded = GZipCodec().decode(bytes);
        debugPrint(
          'OptionChainService: Detected gzip-compressed file at $filePath',
        );
        return utf8.decode(decoded);
      } catch (_) {
        return null;
      }
    }

    String? tryZlib() {
      try {
        final decoded = ZLibDecoder().decodeBytes(bytes);
        debugPrint(
          'OptionChainService: Detected zlib-compressed file at $filePath',
        );
        return utf8.decode(decoded);
      } catch (_) {
        return null;
      }
    }

    String? tryZip() {
      try {
        final archive = ZipDecoder().decodeBytes(bytes, verify: true);
        for (final file in archive.files) {
          if (!file.isFile) continue;
          debugPrint(
            'OptionChainService: Detected ZIP-compressed file at $filePath '
            '(entry: ${file.name})',
          );
          final data = file.content as List<int>;
          final decoded = tryDecode('zip-entry', data);
          if (decoded != null) {
            return decoded;
          }
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    result = tryGzip();
    result ??= tryZip();
    result ??= tryZlib();
    result ??= tryDecode('utf8', bytes);
    result ??= utf8.decode(bytes, allowMalformed: true);

    return result;
  }
}
