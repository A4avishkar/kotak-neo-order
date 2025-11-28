import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_background_service_ios/flutter_background_service_ios.dart';
import 'package:flutter/foundation.dart';
import '../models/credentials.dart';
import '../services/credentials_service.dart';
import '../services/scrip_master_service.dart';

/// Background task handler for daily scrip master downloads
@pragma('vm:entry-point')
Future<bool> onStart(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
    
    // Wait longer for notification to be fully ready before updating
    await Future.delayed(const Duration(seconds: 2));
    
    // Update notification to show service is running (only if service is still active)
    try {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "QuantKey",
          content: "Service running - Downloads every 24 hours",
        );
      }
    } catch (e) {
      debugPrint('BackgroundDownloadService: Error setting notification: $e');
    }
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Schedule daily downloads - runs every 24 hours
  // Calculate time until next 2 AM (or next day if past 2 AM)
  Timer? dailyTimer;
  
  void scheduleNextDownload() {
    final now = DateTime.now();
    var nextRun = DateTime(now.year, now.month, now.day, 2, 0); // 2 AM
    
    if (now.isAfter(nextRun)) {
      nextRun = nextRun.add(const Duration(days: 1));
    }
    
    final delay = nextRun.difference(now);
    
    dailyTimer?.cancel();
    dailyTimer = Timer(delay, () async {
      await _runDailyDownloadTask(service);
      // Schedule next day's download
      scheduleNextDownload();
    });
    
    debugPrint('BackgroundDownloadService: Next download scheduled in ${delay.inHours}h ${delay.inMinutes % 60}m');
  }
  
  // Start scheduling
  scheduleNextDownload();
  
  // Also check every hour if we missed the scheduled time (backup mechanism)
  Timer.periodic(const Duration(hours: 1), (timer) async {
    final now = DateTime.now();
    // Check if it's around 2-4 AM and we haven't downloaded today
    if (now.hour >= 2 && now.hour < 4) {
      final scripService = ScripMasterService();
      final hasFreshData = await scripService.hasFreshDataForToday();
      if (!hasFreshData) {
        debugPrint('BackgroundDownloadService: Backup check - downloading now');
        await _runDailyDownloadTask(service);
      }
    }
  });

  // Kick off an immediate sync (skips if already fresh today)
  scheduleMicrotask(() {
    _runDailyDownloadTask(service);
  });
  
  // Return true to keep service running
  return true;
}

Future<void> _runDailyDownloadTask(
  ServiceInstance service, {
  bool forceDownload = false,
}) async {
  final isAndroid = service is AndroidServiceInstance;

  if (isAndroid && await service.isForegroundService()) {
    service.setForegroundNotificationInfo(
      title: "Kotak Scrip Master",
      content: "Preparing daily download...",
    );
  }

  try {
    final credentialsService = CredentialsService();
    final credentials = await credentialsService.getCredentials();

    if (credentials == null || !credentials.isValid) {
      debugPrint('BackgroundDownloadService: No valid credentials found');
      if (isAndroid) {
        service.setForegroundNotificationInfo(
          title: "QuantKey",
          content: "Download skipped: No credentials",
        );
      }
      return;
    }

    final scripService = ScripMasterService();
    final hasFreshData = await scripService.hasFreshDataForToday();
    if (!forceDownload && hasFreshData) {
      debugPrint('BackgroundDownloadService: Already synced for today, skipping.');
      if (isAndroid) {
        service.setForegroundNotificationInfo(
          title: "QuantKey",
          content: "Already synced for today",
        );
      }
      return;
    }

    if (isAndroid) {
      service.setForegroundNotificationInfo(
        title: "Kotak Scrip Master",
        content: "Downloading scrip master files...",
      );
    }

    final result = await scripService.downloadLatest(credentials);

    if (result.hasFailures) {
      debugPrint('BackgroundDownloadService: Some downloads failed');
      if (isAndroid) {
        service.setForegroundNotificationInfo(
          title: "QuantKey",
          content: "Download completed with some errors",
        );
      }
    } else {
      debugPrint('BackgroundDownloadService: Daily download completed successfully');
      if (isAndroid) {
        service.setForegroundNotificationInfo(
          title: "QuantKey",
          content: "Download completed successfully",
        );
      }
    }
  } catch (error, stackTrace) {
    debugPrint('BackgroundDownloadService: Error during download: $error');
    debugPrint('BackgroundDownloadService: Stack trace: $stackTrace');
    if (isAndroid) {
      service.setForegroundNotificationInfo(
        title: "Kotak Scrip Master",
        content: "Download failed: ${error.toString()}",
      );
    }
  }
}

class BackgroundDownloadService {
  static bool _isInitialized = false;

  /// Initialize the background service
  static Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }
    
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'quantkey_scrip_master',
        initialNotificationTitle: 'QuantKey',
        initialNotificationContent: 'Service is starting...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onStart,
      ),
    );
    
    _isInitialized = true;
  }

  /// Start the background service
  static Future<void> startService() async {
    try {
      // Ensure service is initialized first
      if (!_isInitialized) {
        await initialize();
      }
      
      final service = FlutterBackgroundService();
      final isRunning = await service.isRunning();
      
      if (!isRunning) {
        // Start the service - it will automatically schedule daily downloads
        // The service runs continuously and schedules downloads at 2 AM daily
        await service.startService();
        debugPrint('BackgroundDownloadService: Service started - will download daily at 2 AM');
      } else {
        debugPrint('BackgroundDownloadService: Service already running');
      }
    } catch (error, stackTrace) {
      debugPrint('BackgroundDownloadService: Error starting service: $error');
      debugPrint('BackgroundDownloadService: Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Stop the background service
  static Future<void> stopService() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    
    if (isRunning) {
      service.invoke('stopService');
      debugPrint('BackgroundDownloadService: Service stopped');
    } else {
      debugPrint('BackgroundDownloadService: Service not running');
    }
  }

  /// Check if service is running
  static Future<bool> isServiceRunning() async {
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }

  /// Register a periodic task that runs daily (for compatibility)
  static Future<void> registerDailyTask({
    int initialDelayMinutes = 0,
  }) async {
    await startService();
  }

  /// Cancel the daily download task (for compatibility)
  static Future<void> cancelDailyTask() async {
    await stopService();
  }

  /// Manually trigger a download (useful for testing)
  static Future<void> triggerDownloadNow() async {
    try {
      final credentialsService = CredentialsService();
      final credentials = await credentialsService.getCredentials();

      if (credentials == null || !credentials.isValid) {
        debugPrint('BackgroundDownloadService: No valid credentials found');
        return;
      }

      final scripService = ScripMasterService();
      debugPrint('BackgroundDownloadService: Manually triggering download');
      final result = await scripService.downloadLatest(credentials);

      if (result.hasFailures) {
        debugPrint('BackgroundDownloadService: Some downloads failed');
      } else {
        debugPrint('BackgroundDownloadService: Download completed successfully');
      }
    } catch (error, stackTrace) {
      debugPrint('BackgroundDownloadService: Error during download: $error');
      debugPrint('BackgroundDownloadService: Stack trace: $stackTrace');
    }
  }
}
