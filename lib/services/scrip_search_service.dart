import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';

import 'scrip_master_service.dart';

enum ScripSearchFilter { all, stocks, fno }

/// Performs local search across downloaded scrip master files.
class ScripSearchService {
  ScripSearchService({ScripMasterService? masterService})
    : _masterService = masterService ?? ScripMasterService();

  final ScripMasterService _masterService;

  /// Searches every downloaded scrip master file:
  /// - `_cm` files are searched by `pDesc`
  /// - `_fo` files are searched by `pScripRefKey`
  Future<List<ScripSearchHit>> search(
    String query, {
    int limit = 40,
    ScripSearchFilter filter = ScripSearchFilter.all,
  }) async {
    return _searchByField(query, limit: limit, filter: filter);
  }

  /// Searches by trading symbol (pTrdSymbol) field
  /// Useful when you have a trading symbol from order data
  Future<List<ScripSearchHit>> searchByTradingSymbol(
    String query, {
    int limit = 40,
    ScripSearchFilter filter = ScripSearchFilter.all,
  }) async {
    return _searchByField(query, limit: limit, filter: filter, fieldName: 'pTrdSymbol');
  }

  /// Internal method to search by a specific field
  Future<List<ScripSearchHit>> _searchByField(
    String query, {
    int limit = 40,
    ScripSearchFilter filter = ScripSearchFilter.all,
    String? fieldName,
  }) async {
    final normalized = query.trim();
    if (normalized.length < 2) {
      return [];
    }

    final snapshot = await _masterService.describeLocal();
    debugPrint(
      'ScripSearchService: describeLocal returned ${snapshot.segments.length} segments',
    );
    if (snapshot.segments.isEmpty) {
      return [];
    }

    // Collect and prioritize segments based on filter - prioritize nse/bse first
    final segmentsToSearch = _getPrioritizedSegments(snapshot.segments, filter, fieldName: fieldName);
    
    if (segmentsToSearch.isEmpty) {
      return [];
    }

    // Process segments with priority: nse_fo and bse_fo first (in parallel), then others
    final hits = <ScripSearchHit>[];
    
    // Split segments into priority (nse_fo, bse_fo, nse_cm, bse_cm) and others
    final prioritySegments = <({String filePath, String field, String segmentCode, String segmentName})>[];
    final otherSegments = <({String filePath, String field, String segmentCode, String segmentName})>[];
    
    for (final segment in segmentsToSearch) {
      final segCode = segment.segmentCode.toLowerCase();
      if (segCode == 'nse_fo' || segCode == 'bse_fo' || segCode == 'nse_cm' || segCode == 'bse_cm') {
        prioritySegments.add(segment);
      } else {
        otherSegments.add(segment);
      }
    }
    
    // Search top 2 priority segments in parallel for speed (usually nse_fo and bse_fo)
    if (prioritySegments.isNotEmpty) {
      final topPriority = prioritySegments.take(2).toList();
      final remainingPriority = prioritySegments.skip(2).toList();
      
      // Search top 2 in parallel
      final futures = topPriority.map((segment) => compute(_searchFile, {
        'path': segment.filePath,
        'query': normalized,
        'field': segment.field,
        'limit': limit,
        'segmentCode': segment.segmentCode,
        'segmentName': segment.segmentName,
        'mode': 'search',
      }));
      
      final results = await Future.wait(futures);
      
      // Process results and return early if found
      for (int i = 0; i < results.length; i++) {
        final batch = results[i];
        final segment = topPriority[i];
        debugPrint('ScripSearchService: batch returned ${batch.length} hits from ${segment.segmentCode}');
        
        for (final map in batch) {
          if (hits.length >= limit) {
            return hits; // Early exit if we have enough results
          }
          hits.add(ScripSearchHit.fromMap(map));
        }
      }
      
      // If we found results in top priority segments, return early (don't search others)
      if (hits.isNotEmpty) {
        debugPrint('ScripSearchService: Found ${hits.length} results in priority segments, skipping other segments');
        return hits;
      }
      
      // If no results in top 2, try remaining priority segments sequentially
      for (final segment in remainingPriority) {
        if (hits.length >= limit) {
          return hits;
        }
        
        final remaining = limit - hits.length;
        final batch = await compute(_searchFile, {
          'path': segment.filePath,
          'query': normalized,
          'field': segment.field,
          'limit': remaining,
          'segmentCode': segment.segmentCode,
          'segmentName': segment.segmentName,
          'mode': 'search',
        });
        
        debugPrint('ScripSearchService: batch returned ${batch.length} hits from ${segment.segmentCode}');
        for (final map in batch) {
          if (hits.length >= limit) {
            return hits;
          }
          hits.add(ScripSearchHit.fromMap(map));
        }
        
        if (hits.isNotEmpty) {
          return hits;
        }
      }
    }
    
    // Only search other segments if no results found in priority segments
    if (hits.isEmpty && otherSegments.isNotEmpty) {
      debugPrint('ScripSearchService: No results in priority segments, searching other segments...');
      for (final segment in otherSegments) {
        if (hits.length >= limit) {
          break;
        }
        
        final remaining = limit - hits.length;
        final batch = await compute(_searchFile, {
          'path': segment.filePath,
          'query': normalized,
          'field': segment.field,
          'limit': remaining,
          'segmentCode': segment.segmentCode,
          'segmentName': segment.segmentName,
          'mode': 'search',
        });
        
        debugPrint('ScripSearchService: batch returned ${batch.length} hits from ${segment.segmentCode}');
        for (final map in batch) {
          if (hits.length >= limit) {
            return hits;
          }
          hits.add(ScripSearchHit.fromMap(map));
        }
        
        if (hits.isNotEmpty) {
          return hits;
        }
      }
    }
    
    return hits;
  }

  /// Returns the top entries (currently the first [limit] rows) from the prioritized
  /// segments, ordered as they appear in the CSV.
  Future<List<ScripSearchHit>> topEntries({
    int? limit,
    ScripSearchFilter filter = ScripSearchFilter.stocks,
  }) async {
    final snapshot = await _masterService.describeLocal();
    final effectiveLimit = limit == null || limit <= 0 ? 50 : limit;
    final segmentsToSearch = _getPrioritizedSegments(snapshot.segments, filter);
    if (segmentsToSearch.isEmpty) {
      return [];
    }

    final hits = <ScripSearchHit>[];
    for (final segment in segmentsToSearch) {
      if (hits.length >= effectiveLimit) break;
      final remaining = effectiveLimit - hits.length;
      final results = await compute(_searchFile, {
        'path': segment.filePath,
        'field': segment.field,
        'limit': remaining,
        'segmentCode': segment.segmentCode,
        'segmentName': segment.segmentName,
        'query': '',
        'mode': 'top',
      });
      hits.addAll(results.map(ScripSearchHit.fromMap));
    }

    return hits;
  }

  String? _fieldForSegment(String segmentCode, {String? fieldName}) {
    // If a specific field is requested, use it
    if (fieldName != null) {
      return fieldName;
    }
    
    final lower = segmentCode.toLowerCase();
    if (lower.contains('_cm')) {
      return 'pDesc';
    }
    if (lower.contains('_fo')) {
      return 'pScripRefKey';
    }
    return null;
  }

  bool _filterAllowsSegment(ScripSearchFilter filter, String segmentCode) {
    final lower = segmentCode.toLowerCase();
    final isCm = lower.contains('_cm');
    final isFo = lower.contains('_fo');
    switch (filter) {
      case ScripSearchFilter.all:
        return isCm || isFo;
      case ScripSearchFilter.stocks:
        return isCm;
      case ScripSearchFilter.fno:
        return isFo;
    }
  }

  /// Returns prioritized segments for search based on filter
  List<({String filePath, String field, String segmentCode, String segmentName})> 
      _getPrioritizedSegments(
    List<ScripMasterSegmentStatus> segments,
    ScripSearchFilter filter, {
    String? fieldName,
  }) {
    final result = <({String filePath, String field, String segmentCode, String segmentName})>[];
    
    // Define priority order for different filters
    final priorityOrder = <String>[];
    
    switch (filter) {
      case ScripSearchFilter.stocks:
        // For stocks: nse_cm first, then bse_cm, then other _cm files
        priorityOrder.addAll(['nse_cm', 'bse_cm']);
        break;
      case ScripSearchFilter.fno:
        // For F&O: nse_fo first, then bse_fo, then mcx_fo, then other _fo files
        priorityOrder.addAll(['nse_fo', 'bse_fo', 'mcx_fo', 'cde_fo']);
        break;
      case ScripSearchFilter.all:
        // For all: prioritize common ones first
        priorityOrder.addAll(['nse_cm', 'bse_cm', 'nse_fo', 'bse_fo', 'mcx_fo', 'cde_fo']);
        break;
    }
    
    // First, collect segments that match the filter
    final matchingSegments = <ScripMasterSegmentStatus>[];
    for (final segment in segments) {
      final filePath = segment.filePath;
      final field = _fieldForSegment(segment.segmentCode, fieldName: fieldName);
      if (filePath == null || field == null) {
        continue;
      }
      if (!_filterAllowsSegment(filter, segment.segmentCode)) {
        continue;
      }
      matchingSegments.add(segment);
    }
    
    // Add segments in priority order with field information
    for (final priority in priorityOrder) {
      for (final segment in matchingSegments) {
        final segmentCodeLower = segment.segmentCode.toLowerCase();
        if (segmentCodeLower.contains(priority) && 
            !result.any((r) => r.segmentCode == segment.segmentCode)) {
          final field = _fieldForSegment(segment.segmentCode, fieldName: fieldName);
          if (field != null && segment.filePath != null) {
            result.add((
              filePath: segment.filePath!,
              field: field,
              segmentCode: segment.segmentCode,
              segmentName: segment.segmentName,
            ));
          }
        }
      }
    }
    
    // Add remaining segments that weren't in priority list
    for (final segment in matchingSegments) {
      if (!result.any((r) => r.segmentCode == segment.segmentCode)) {
        final field = _fieldForSegment(segment.segmentCode, fieldName: fieldName);
        if (field != null && segment.filePath != null) {
          result.add((
            filePath: segment.filePath!,
            field: field,
            segmentCode: segment.segmentCode,
            segmentName: segment.segmentName,
          ));
        }
      }
    }
    
    return result;
  }

}

/// Represents a single search result row extracted from the CSV files.
class ScripSearchHit {
  const ScripSearchHit({
    required this.segmentCode,
    required this.segmentName,
    required this.primaryField,
    required this.primaryValue,
    required this.metadata,
  });

  factory ScripSearchHit.fromMap(Map<String, dynamic> map) {
    final metadata = <String, String>{};
    final rawMetadata = map['metadata'] as Map?;
    if (rawMetadata != null) {
      for (final entry in rawMetadata.entries) {
        metadata[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    }
    return ScripSearchHit(
      segmentCode: map['segmentCode'] as String,
      segmentName: map['segmentName'] as String,
      primaryField: map['primaryField'] as String,
      primaryValue: map['primaryValue'] as String,
      metadata: metadata,
    );
  }

  final String segmentCode;
  final String segmentName;
  final String primaryField;
  final String primaryValue;
  final Map<String, String> metadata;

  String? get secondaryValue {
    return metadata['pSymbol'] ??
        metadata['pISIN'] ??
        metadata['pSeries'] ??
        metadata['pToken'];
  }
}

Future<List<Map<String, dynamic>>> _searchFile(
  Map<String, dynamic> payload,
) async {
  final filePath = payload['path'] as String;
  final field = payload['field'] as String;
  final rawLimit = payload['limit'] as int?;
  final perFileLimit =
      rawLimit == null || rawLimit <= 0 ? 1000000 : rawLimit;
  final mode = payload['mode'] as String? ?? 'search';
  final isTopMode = mode == 'top';
  final query = (payload['query'] as String?)?.toLowerCase() ?? '';

  final file = File(filePath);
  if (!await file.exists()) {
    return [];
  }

  try {
    final bytes = await file.readAsBytes();
    final raw = _decodeCsvPayload(bytes, filePath);
    final normalizedRaw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final suspectedDelimiter = normalizedRaw.contains('|') ? '|' : ',';
    final rows = CsvToListConverter(
      shouldParseNumbers: false,
      fieldDelimiter: suspectedDelimiter,
      eol: '\n',
    ).convert(normalizedRaw);
    debugPrint(
      'ScripSearchService: Parsed ${rows.length} rows from $filePath using "$suspectedDelimiter" delimiter',
    );
    if (rows.length <= 1) {
      final sampleLength = normalizedRaw.length >= 400 ? 400 : normalizedRaw.length;
      final sample = normalizedRaw.substring(0, sampleLength);
      final printableSample = sample.replaceAll('\n', '\\n');
      final codeUnits = sample.codeUnits.take(32).toList();
      final newlineCount = '\n'.allMatches(normalizedRaw).length;
      debugPrint(
        'ScripSearchService: row anomaly for $filePath (newlineCount=$newlineCount, '
        'sample="$printableSample", codes=$codeUnits)',
      );
    }
    if (rows.isEmpty) {
      return [];
    }

    List<String>? header;
    int headerRowIndex = -1;
    int fieldIndex = -1;

    for (var i = 0; i < rows.length; i++) {
      final candidate = rows[i]
          .map((cell) => cell?.toString().replaceAll('\ufeff', '').trim() ?? '')
          .toList();
      final index = candidate.indexWhere(
        (column) => column.toLowerCase() == field.toLowerCase(),
      );
      if (index != -1) {
        header = candidate;
        headerRowIndex = i;
        fieldIndex = index;
        break;
      }
    }

    if (header == null || fieldIndex == -1 || headerRowIndex == -1) {
      return [];
    }

    final results = <Map<String, dynamic>>[];
    // For search mode, try to find matches early in the file
    // For top mode, just take first N rows
    final searchStart = isTopMode ? headerRowIndex + 1 : headerRowIndex + 1;
    final searchEnd = rows.length;
    
    for (var i = searchStart; i < searchEnd; i++) {
      if (results.length >= perFileLimit) {
        break;
      }

      final row = rows[i];
      if (fieldIndex >= row.length) {
        continue;
      }
      final value = row[fieldIndex]?.toString() ?? '';
      if (value.isEmpty) {
        continue;
      }

      if (!isTopMode && !value.toLowerCase().contains(query)) {
        continue;
      }

      final metadata = <String, String>{};
      for (var j = 0; j < header.length && j < row.length; j++) {
        final column = header[j];
        if (column.isEmpty) {
          continue;
        }
        metadata[column] = row[j]?.toString() ?? '';
      }

      results.add({
        'segmentCode': payload['segmentCode'],
        'segmentName': payload['segmentName'],
        'primaryField': field,
        'primaryValue': value,
        'metadata': metadata,
      });
    }

    return results;
  } catch (error, stackTrace) {
    debugPrint(
      'ScripSearchService: Failed to search $filePath: $error\n$stackTrace',
    );
    return [];
  }
}

String _decodeCsvPayload(List<int> bytes, String filePath) {
  String? result;

  String? tryDecode(String label, List<int> payload) {
    try {
      return utf8.decode(payload);
    } catch (error, stackTrace) {
      debugPrint(
        'ScripSearchService: Failed to decode $label for $filePath: '
        '$error\n$stackTrace',
      );
      return null;
    }
  }

  String? tryGzip() {
    try {
      final decoded = GZipCodec().decode(bytes);
      debugPrint(
        'ScripSearchService: Detected gzip-compressed file at $filePath',
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
        'ScripSearchService: Detected zlib-compressed file at $filePath',
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
          'ScripSearchService: Detected ZIP-compressed file at $filePath '
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
