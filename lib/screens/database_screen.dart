import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/credentials_service.dart';
import '../services/scrip_master_service.dart';
import '../services/background_download_service.dart';

class DatabaseScreen extends StatefulWidget {
  const DatabaseScreen({super.key});

  @override
  State<DatabaseScreen> createState() => _DatabaseScreenState();
}

class _DatabaseScreenState extends State<DatabaseScreen> {
  final _service = ScripMasterService();
  final _credentialsService = CredentialsService();
  static const String _backgroundServiceEnabledKey = 'background_service_enabled';

  ScripMasterState? _state;
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  bool _backgroundServiceEnabled = false;

  @override
  void initState() {
    super.initState();
    _refreshSnapshot();
    _loadBackgroundServiceState();
  }

  Future<void> _loadBackgroundServiceState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedState = prefs.getBool(_backgroundServiceEnabledKey) ?? false;
      
      // Check actual service state
      final isRunning = await BackgroundDownloadService.isServiceRunning();
      
      setState(() {
        _backgroundServiceEnabled = savedState && isRunning;
      });
      
      // Don't auto-start service when screen loads - let user manually enable it
      // This prevents crashes from starting service before notification is ready
    } catch (error) {
      debugPrint('Error loading background service state: $error');
      setState(() {
        _backgroundServiceEnabled = false;
      });
    }
  }

  Future<void> _toggleBackgroundService(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_backgroundServiceEnabledKey, enabled);
      
      if (enabled) {
        // Start the background service (runs continuously with daily downloads)
        try {
          await BackgroundDownloadService.startService();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Background service enabled. Downloads will run daily automatically.'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        } catch (error) {
          debugPrint('Error starting background service: $error');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to start service: $error'),
                duration: const Duration(seconds: 3),
              ),
            );
            // Revert the toggle
            await prefs.setBool(_backgroundServiceEnabledKey, false);
            setState(() {
              _backgroundServiceEnabled = false;
            });
            return;
          }
        }
      } else {
        // Stop the service
        try {
          await BackgroundDownloadService.stopService();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Background service disabled.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (error) {
          debugPrint('Error stopping background service: $error');
        }
      }
      
      if (mounted) {
        setState(() {
          _backgroundServiceEnabled = enabled;
        });
      }
    } catch (error) {
      debugPrint('Error toggling background service: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $error'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _refreshSnapshot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await _service.describeLocal();
      if (!mounted) return;
      setState(() {
        _state = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _downloadLatest() async {
    final credentials = await _credentialsService.getCredentials();
    if (credentials == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add your Kotak credentials before downloading.'),
          ),
        );
      }
      setState(() {
        _error = 'Credentials missing.';
      });
      return;
    }

    setState(() {
      _syncing = true;
      _error = null;
    });

    try {
      final result = await _service.downloadLatest(credentials);
      if (!mounted) return;
      setState(() {
        _state = result;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Latest scrip master files downloaded.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _handleRefresh() async {
    if (_syncing) {
      return;
    }
    await _refreshSnapshot();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget body;
    if (_loading && (_state == null || _state!.segments.isEmpty)) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = RefreshIndicator(
        onRefresh: _handleRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _buildSummaryCard(theme),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _buildErrorBanner(theme),
            ],
            const SizedBox(height: 16),
            if ((_state?.segments ?? []).isEmpty)
              _buildEmptyPlaceholder(theme)
            else
              ..._state!.segments.map(_buildSegmentTile),
            const SizedBox(height: 32),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Database')),
      body: body,
    );
  }

  Widget _buildSummaryCard(ThemeData theme) {
    final directory = _state?.directoryPath ?? 'Preparing storage…';
    final lastSyncText = _formatTimestamp(_state?.lastSync);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scrip Master Storage', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Files are saved locally and refreshed once per day.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _SummaryRow(label: 'Last sync', value: lastSyncText),
            const SizedBox(height: 4),
            _SummaryRow(label: 'Storage path', value: directory),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _syncing ? null : _downloadLatest,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined),
                    label: Text(_syncing ? 'Syncing…' : 'Download latest'),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _loading ? null : _refreshSnapshot,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reload file list',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-download daily',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Automatically download scrip master files every day, even when app is closed.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      if (_backgroundServiceEnabled) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Service is running. Downloads will occur automatically every 24 hours.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Switch(
                  value: _backgroundServiceEnabled,
                  onChanged: _toggleBackgroundService,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _error ?? '',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }

  Widget _buildEmptyPlaceholder(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(
            Icons.storage_outlined,
            size: 32,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('No files downloaded yet.', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Tap “Download latest” to grab today’s scrip master set.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTile(ScripMasterSegmentStatus status) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = _statusColor(status.state, colors);
    final icon = _statusIcon(status.state);
    final label = _statusLabel(status.state);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.segmentName,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SegmentDetailLine(
              label: 'Updated',
              value: _formatTimestamp(status.updatedAt),
            ),
            _SegmentDetailLine(
              label: 'Size',
              value: _formatSize(status.sizeBytes),
            ),
            _SegmentDetailLine(
              label: 'File path',
              value: status.filePath ?? 'Not available',
            ),
            if (status.message != null) ...[
              const SizedBox(height: 8),
              Text(
                status.message!,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) {
      return 'Never';
    }
    final local = timestamp.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '$date • $time';
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '--';
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(2)} MB';
    }
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }

  Color _statusColor(ScripMasterSegmentState state, ColorScheme colors) {
    switch (state) {
      case ScripMasterSegmentState.downloaded:
        return colors.secondary;
      case ScripMasterSegmentState.upToDate:
        return colors.primary;
      case ScripMasterSegmentState.stale:
        return colors.tertiary;
      case ScripMasterSegmentState.missing:
        return colors.outline;
      case ScripMasterSegmentState.failed:
        return colors.error;
    }
  }

  IconData _statusIcon(ScripMasterSegmentState state) {
    switch (state) {
      case ScripMasterSegmentState.downloaded:
        return Icons.check_circle_outline;
      case ScripMasterSegmentState.upToDate:
        return Icons.verified_outlined;
      case ScripMasterSegmentState.stale:
        return Icons.update;
      case ScripMasterSegmentState.missing:
        return Icons.hourglass_empty;
      case ScripMasterSegmentState.failed:
        return Icons.error_outline;
    }
  }

  String _statusLabel(ScripMasterSegmentState state) {
    switch (state) {
      case ScripMasterSegmentState.downloaded:
        return 'Downloaded just now';
      case ScripMasterSegmentState.upToDate:
        return 'Already up to date';
      case ScripMasterSegmentState.stale:
        return 'Needs refresh';
      case ScripMasterSegmentState.missing:
        return 'Not downloaded';
      case ScripMasterSegmentState.failed:
        return 'Download failed';
    }
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _SegmentDetailLine extends StatelessWidget {
  const _SegmentDetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
