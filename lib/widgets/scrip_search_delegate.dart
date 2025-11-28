import 'dart:async';

import 'package:flutter/material.dart';

import '../services/scrip_search_service.dart';
import '../services/watchlist_service.dart';

class ScripSearchDelegate extends SearchDelegate<ScripSearchHit?> {
  ScripSearchDelegate({required this.searchService});

  final ScripSearchService searchService;
  final WatchlistService _watchlistService = WatchlistService();

  ScripSearchFilter _currentFilter = ScripSearchFilter.all;

  @override
  String get searchFieldLabel => 'Search scrip master';

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) =>
      _buildResultList(context, isResultsView: false);

  @override
  Widget buildResults(BuildContext context) =>
      _buildResultList(context, isResultsView: true);

  Widget _buildResultList(BuildContext context, {required bool isResultsView}) {
    final trimmed = query.trim();
    final content = trimmed.length < 2
        ? _DebouncedFutureBuilder<List<ScripSearchHit>>(
            key: ValueKey('top_${_currentFilter.name}'),
            futureBuilder: () => searchService.topEntries(filter: _currentFilter),
            debounceDuration: const Duration(milliseconds: 300),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return _CenteredHint(
                  message: 'Unable to load symbols: ${snapshot.error}',
                );
              }

              final results = snapshot.data ?? [];
              return _ResultListView(
                hits: results,
                emptyLabel:
                    'No ${_filterLabel(_currentFilter)} entries cached yet.',
                titleBuilder: (hit) => hit.primaryValue,
                subtitleBuilder: _subtitleBuilder,
                onTap: (hit) => close(context, hit),
                onAdd: (hit) => _addToWatchlist(context, hit),
              );
            },
          )
        : _DebouncedFutureBuilder<List<ScripSearchHit>>(
            key: ValueKey('search_${trimmed}_${_currentFilter.name}'),
            futureBuilder: () => searchService.search(trimmed, filter: _currentFilter),
            debounceDuration: const Duration(milliseconds: 300),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return _CenteredHint(
                  message: 'Search failed: ${snapshot.error}',
                );
              }

              final results = snapshot.data ?? [];
              return _ResultListView(
                hits: results,
                emptyLabel: 'No matches found for "$trimmed".',
                titleBuilder: (hit) => hit.primaryValue,
                subtitleBuilder: _subtitleBuilder,
                onTap: (hit) => close(context, hit),
                onAdd: (hit) => _addToWatchlist(context, hit),
              );
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FilterBar(
          current: _currentFilter,
          onChanged: (filter) =>
              _handleFilterChange(context, filter, isResultsView),
        ),
        const SizedBox(height: 8),
        Expanded(child: content),
      ],
    );
  }

  void _handleFilterChange(
    BuildContext context,
    ScripSearchFilter filter,
    bool isResultsView,
  ) {
    if (_currentFilter == filter) {
      return;
    }
    _currentFilter = filter;
    if (isResultsView) {
      showResults(context);
    } else {
      showSuggestions(context);
    }
  }

  String _subtitleBuilder(ScripSearchHit hit) {
    final subtitleParts = <String>[
      hit.segmentName,
      if ((hit.secondaryValue ?? '').isNotEmpty) hit.secondaryValue!,
    ];
    return subtitleParts.join(' • ');
  }

  String _filterLabel(ScripSearchFilter filter) {
    switch (filter) {
      case ScripSearchFilter.all:
        return 'All segments';
      case ScripSearchFilter.stocks:
        return 'Stocks';
      case ScripSearchFilter.fno:
        return 'F&O';
    }
  }

  Future<void> _addToWatchlist(BuildContext context, ScripSearchHit hit) async {
    final added = await _watchlistService.addHit(hit);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? '${hit.primaryValue} added to watchlist.'
              : '${hit.primaryValue} is already in watchlist.',
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.current, required this.onChanged});

  final ScripSearchFilter current;
  final ValueChanged<ScripSearchFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        children: [
          _buildChip(context, ScripSearchFilter.all, 'All'),
          _buildChip(context, ScripSearchFilter.stocks, 'Stocks'),
          _buildChip(context, ScripSearchFilter.fno, 'F&O'),
        ],
      ),
    );
  }

  Widget _buildChip(
    BuildContext context,
    ScripSearchFilter filter,
    String label,
  ) {
    final isSelected = current == filter;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onChanged(filter),
    );
  }
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DebouncedFutureBuilder<T> extends StatefulWidget {
  const _DebouncedFutureBuilder({
    super.key,
    required this.futureBuilder,
    required this.debounceDuration,
    required this.builder,
  });

  final Future<T> Function() futureBuilder;
  final Duration debounceDuration;
  final AsyncWidgetBuilder<T> builder;

  @override
  State<_DebouncedFutureBuilder<T>> createState() =>
      _DebouncedFutureBuilderState<T>();
}

class _DebouncedFutureBuilderState<T>
    extends State<_DebouncedFutureBuilder<T>> {
  Timer? _debounceTimer;
  Future<T>? _currentFuture;

  @override
  void initState() {
    super.initState();
    _scheduleSearch();
  }

  @override
  void didUpdateWidget(_DebouncedFutureBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the widget key changed, schedule a new search
    if (widget.key != oldWidget.key) {
      _scheduleSearch();
    }
  }

  void _scheduleSearch() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounceDuration, () {
      if (mounted) {
        setState(() {
          _currentFuture = widget.futureBuilder();
        });
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentFuture == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<T>(
      future: _currentFuture,
      builder: widget.builder,
    );
  }
}

class _ResultListView extends StatelessWidget {
  const _ResultListView({
    required this.hits,
    required this.emptyLabel,
    required this.titleBuilder,
    required this.subtitleBuilder,
    required this.onTap,
    required this.onAdd,
  });

  final List<ScripSearchHit> hits;
  final String emptyLabel;
  final String Function(ScripSearchHit hit) titleBuilder;
  final String Function(ScripSearchHit hit) subtitleBuilder;
  final ValueChanged<ScripSearchHit> onTap;
  final ValueChanged<ScripSearchHit> onAdd;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return _CenteredHint(message: emptyLabel);
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: hits.length,
      // Use const for separator to avoid rebuilds
      separatorBuilder: (_, __) => const Divider(height: 1),
      // Cache extent for better scroll performance
      cacheExtent: 500,
      itemBuilder: (context, index) {
        final hit = hits[index];
        return _SearchResultItem(
          hit: hit,
          title: titleBuilder(hit),
          subtitle: subtitleBuilder(hit),
          onTap: () => onTap(hit),
          onAdd: () => onAdd(hit),
        );
      },
    );
  }
}

/// Extracted widget for better performance (can be const and cached)
class _SearchResultItem extends StatelessWidget {
  const _SearchResultItem({
    required this.hit,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.onAdd,
  });

  final ScripSearchHit hit;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.search, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.playlist_add),
              tooltip: 'Add to watchlist',
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}
