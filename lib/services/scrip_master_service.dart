import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/credentials.dart';
import 'kotak_api_service.dart';

/// Handles downloading and tracking of Kotak scrip master CSV files.
class ScripMasterService {
  ScripMasterService({http.Client? httpClient, KotakApiService? apiService})
    : _httpClient = httpClient ?? http.Client(),
      _apiService = apiService ?? KotakApiService();

  final http.Client _httpClient;
  final KotakApiService _apiService;

  static const _prefsLastSyncKey = 'scrip_master_last_sync';
  static const _directDownloadBase =
      'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod';
  static const _downloadTimeout = Duration(seconds: 60);
  static const _apiTimeout = Duration(seconds: 30);

  static const Map<String, String> _segmentNames = {
    'nse_cm': 'NSE Cash',
    'nse_fo': 'NSE F&O',
    'nse_cd': 'NSE Currency',
    'bse_cm': 'BSE Cash',
    'bse_fo': 'BSE F&O',
    'mcx_fo': 'MCX F&O',
    'cde_fo': 'CDE F&O',
  };

  static const Set<String> _authSegments = {'nse_cm', 'bse_cm', 'nse_cd'};

  /// Returns a snapshot of currently cached CSV files.
  Future<ScripMasterState> describeLocal() async {
    final directory = await _ensureBaseDirectory();
    final lastSync = await _loadLastSync();
    final segments = <ScripMasterSegmentStatus>[];

    for (final entry in _segmentNames.entries) {
      final status = await _describeSegment(directory, entry.key, entry.value);
      segments.add(status);
    }

    return ScripMasterState(
      segments: segments,
      directoryPath: directory.path,
      lastSync: lastSync,
    );
  }

  /// Downloads the latest CSV files, replacing yesterday's copies.
  Future<ScripMasterState> downloadLatest(Credentials credentials) async {
    if (!credentials.isValid) {
      throw StateError(
        'Missing credentials. Please configure them in Settings first.',
      );
    }

    final directory = await _ensureBaseDirectory();
    final urls = await _buildSegmentUrls(credentials);
    final segments = <ScripMasterSegmentStatus>[];

    for (final entry in _segmentNames.entries) {
      final urlString = urls[entry.key];
      if (urlString == null) {
        segments.add(
          ScripMasterSegmentStatus(
            segmentCode: entry.key,
            segmentName: entry.value,
            state: ScripMasterSegmentState.failed,
            message: 'Missing download URL for ${entry.value}',
          ),
        );
        continue;
      }

      try {
        final uri = Uri.parse(urlString);
        final status = await _downloadSegment(
          directory,
          entry.key,
          entry.value,
          uri,
        );
        segments.add(status);
      } catch (error, stackTrace) {
        debugPrint(
          'ScripMasterService: Failed to parse ${entry.key} URL: '
          '$error\n$stackTrace',
        );
        segments.add(
          ScripMasterSegmentStatus(
            segmentCode: entry.key,
            segmentName: entry.value,
            state: ScripMasterSegmentState.failed,
            message: 'Invalid URL: ${error.toString()}',
          ),
        );
      }
    }

    final completedAt = DateTime.now();
    await _persistLastSync(completedAt);

    return ScripMasterState(
      segments: segments,
      directoryPath: directory.path,
      lastSync: completedAt,
    );
  }

  /// Returns true if the last recorded sync happened today.
  Future<bool> hasFreshDataForToday() async {
    final lastSync = await _loadLastSync();
    if (lastSync == null) {
      return false;
    }
    return _isSameDay(lastSync.toLocal(), DateTime.now());
  }

  Future<Directory> _ensureBaseDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(docs.path, 'scrip_masters'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<ScripMasterSegmentStatus> _describeSegment(
    Directory directory,
    String segmentCode,
    String segmentName,
  ) async {
    final files = await _segmentFiles(directory, segmentCode);
    if (files.isEmpty) {
      return ScripMasterSegmentStatus(
        segmentCode: segmentCode,
        segmentName: segmentName,
        state: ScripMasterSegmentState.missing,
      );
    }

    File? latestFile;
    FileStat? latestStat;

    for (final file in files) {
      try {
        final stat = await file.stat();
        if (latestStat == null || stat.modified.isAfter(latestStat.modified)) {
          latestFile = file;
          latestStat = stat;
        }
      } catch (error) {
        debugPrint(
          'ScripMasterService: Failed to read metadata for ${file.path}: $error',
        );
      }
    }

    if (latestFile == null || latestStat == null) {
      return ScripMasterSegmentStatus(
        segmentCode: segmentCode,
        segmentName: segmentName,
        state: ScripMasterSegmentState.failed,
        message: 'Unable to read cached file metadata.',
      );
    }

    final today = DateTime.now();
    final state = _isSameDay(latestStat.modified, today)
        ? ScripMasterSegmentState.upToDate
        : ScripMasterSegmentState.stale;

    return ScripMasterSegmentStatus(
      segmentCode: segmentCode,
      segmentName: segmentName,
      state: state,
      filePath: latestFile.path,
      updatedAt: latestStat.modified,
      sizeBytes: latestStat.size,
    );
  }

  Future<ScripMasterSegmentStatus> _downloadSegment(
    Directory directory,
    String segmentCode,
    String segmentName,
    Uri uri,
  ) async {
    final today = DateTime.now();
    final expectedName = _segmentFileName(segmentCode, today);
    final destination = File(p.join(directory.path, expectedName));
    final currentFiles = await _segmentFiles(directory, segmentCode);
    File? todaysFile;

    // Clean up previous files and check if today's copy already exists.
    for (final file in currentFiles) {
      final stat = await file.stat();
      final isToday =
          _isSameDay(stat.modified, today) ||
          p.basename(file.path) == expectedName;

      if (isToday && todaysFile == null) {
        todaysFile = file;
        continue;
      }

      try {
        await file.delete();
      } catch (error) {
        debugPrint(
          'ScripMasterService: Failed to delete old file ${file.path}: $error',
        );
      }
    }

    if (todaysFile != null) {
      File finalFile = todaysFile!;
      if (p.basename(finalFile.path) != expectedName) {
        try {
          finalFile = await finalFile.rename(destination.path);
        } catch (_) {
          await finalFile.copy(destination.path);
          await finalFile.delete();
          finalFile = destination;
        }
      }
      final stat = await finalFile.stat();
      return ScripMasterSegmentStatus(
        segmentCode: segmentCode,
        segmentName: segmentName,
        state: ScripMasterSegmentState.upToDate,
        filePath: finalFile.path,
        updatedAt: stat.modified,
        sizeBytes: stat.size,
      );
    }

    try {
      final response = await _httpClient.get(uri).timeout(_downloadTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'HTTP ${response.statusCode} while downloading ${uri.pathSegments.last}',
          uri: uri,
        );
      }

      await destination.writeAsBytes(response.bodyBytes, flush: true);
      final stat = await destination.stat();
      return ScripMasterSegmentStatus(
        segmentCode: segmentCode,
        segmentName: segmentName,
        state: ScripMasterSegmentState.downloaded,
        filePath: destination.path,
        updatedAt: stat.modified,
        sizeBytes: stat.size,
      );
    } catch (error) {
      return ScripMasterSegmentStatus(
        segmentCode: segmentCode,
        segmentName: segmentName,
        state: ScripMasterSegmentState.failed,
        message: error.toString(),
      );
    }
  }

  Future<Map<String, String>> _buildSegmentUrls(Credentials credentials) async {
    final urlMap = <String, String>{};
    final loginResult = await _apiService.totpLogin(credentials);
    final viewToken = loginResult['viewToken'] as String;
    final sid = loginResult['sid'] as String;
    final validateResult = await _apiService.totpValidate(
      credentials,
      sid,
      viewToken,
    );
    final baseUrl = validateResult['baseUrl'] as String?;

    final authUrls = await _fetchAuthenticatedUrls(
      credentials.consumerKey,
      baseUrl,
    );
    urlMap.addAll(authUrls);

    final todayFolder = _formatFolderDate(DateTime.now());
    for (final segment in _segmentNames.keys) {
      urlMap.putIfAbsent(
        segment,
        () => '$_directDownloadBase/$todayFolder/transformed/$segment.csv',
      );
    }

    return urlMap;
  }

  Future<Map<String, String>> _fetchAuthenticatedUrls(
    String consumerKey,
    String? baseUrl,
  ) async {
    final urls = <String, String>{};
    final bases = <String>[];

    if (baseUrl != null && baseUrl.isNotEmpty) {
      bases.add(baseUrl);
    }
    bases.add('https://mnapi.kotaksecurities.com');

    const endpoint = 'script-details/1.0/masterscrip/file-paths';
    for (final rawBase in bases) {
      final normalized = rawBase.endsWith('/')
          ? rawBase.substring(0, rawBase.length - 1)
          : rawBase;
      final uri = Uri.parse('$normalized/$endpoint');

      try {
        final response = await _httpClient
            .get(
              uri,
              headers: {
                'Authorization': consumerKey,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
            )
            .timeout(_apiTimeout);

        if (response.statusCode != 200) {
          debugPrint(
            'ScripMasterService: Auth URL fetch failed (${response.statusCode})',
          );
          continue;
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final paths = (data['data']?['filesPaths'] as List?)?.cast<String>();
        if (paths == null) {
          continue;
        }

        for (final path in paths) {
          final lower = path.toLowerCase();
          for (final segment in _authSegments) {
            if (!urls.containsKey(segment) && lower.contains(segment)) {
              urls[segment] = path;
            }
          }
        }

        if (urls.length == _authSegments.length) {
          break;
        }
      } catch (error) {
        debugPrint(
          'ScripMasterService: Failed to fetch auth URLs from $uri: $error',
        );
      }
    }

    return urls;
  }

  Future<List<File>> _segmentFiles(
    Directory directory,
    String segmentCode,
  ) async {
    final files = <File>[];
    final prefix = '${segmentCode}_scrip_master_';

    await for (final entity in directory.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) && name.endsWith('.csv')) {
          files.add(entity);
        }
      }
    }

    return files;
  }

  Future<void> _persistLastSync(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLastSyncKey, time.toIso8601String());
  }

  Future<DateTime?> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsLastSyncKey);
    if (raw == null) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _segmentFileName(String segmentCode, DateTime date) {
    return '${segmentCode}_scrip_master_${_formatFileDate(date)}.csv';
  }

  String _formatFolderDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  String _formatFileDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}$mm$dd';
  }
}

class ScripMasterState {
  const ScripMasterState({
    required this.segments,
    required this.directoryPath,
    this.lastSync,
  });

  final List<ScripMasterSegmentStatus> segments;
  final String directoryPath;
  final DateTime? lastSync;

  bool get hasFailures => segments.any(
    (element) => element.state == ScripMasterSegmentState.failed,
  );
}

enum ScripMasterSegmentState { downloaded, upToDate, stale, missing, failed }

class ScripMasterSegmentStatus {
  const ScripMasterSegmentStatus({
    required this.segmentCode,
    required this.segmentName,
    required this.state,
    this.filePath,
    this.updatedAt,
    this.sizeBytes,
    this.message,
  });

  final String segmentCode;
  final String segmentName;
  final ScripMasterSegmentState state;
  final String? filePath;
  final DateTime? updatedAt;
  final int? sizeBytes;
  final String? message;
}
