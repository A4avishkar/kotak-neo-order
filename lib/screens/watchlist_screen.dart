import 'package:flutter/material.dart';

import '../models/watchlist_entry.dart';
import '../services/watchlist_service.dart';
import '../services/scrip_search_service.dart';
import 'scrip_detail_screen.dart';

class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  final _service = WatchlistService();
  List<WatchlistEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    setState(() {
      _loading = true;
    });
    final items = await _service.fetchEntries();
    if (!mounted) return;
    setState(() {
      _entries = items;
      _loading = false;
    });
  }

  Future<void> _removeEntry(WatchlistEntry entry) async {
    await _service.removeEntry(entry.id);
    await _loadEntries();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${entry.primaryValue} removed from watchlist.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchlist'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh watchlist',
            onPressed: _loadEntries,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const _EmptyWatchlist()
              : RefreshIndicator(
                  onRefresh: _loadEntries,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    // Add cacheExtent for better scrolling performance
                    cacheExtent: 500,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      // Wrap each card in RepaintBoundary to isolate repaints
                      return RepaintBoundary(
                        child: Card(
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ScripDetailScreen(
                                  hit: entry.toHit(),
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.primaryValue,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${entry.segmentName}${entry.secondaryValue != null && entry.secondaryValue!.isNotEmpty ? ' • ${entry.secondaryValue}' : ''}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _removeEntry(entry),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemCount: _entries.length,
                  ),
                ),
    );
  }
}

class _EmptyWatchlist extends StatelessWidget {
  const _EmptyWatchlist();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.list_alt_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              'No symbols yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Use the search panel to add stocks or F&O contracts to your watchlist.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

