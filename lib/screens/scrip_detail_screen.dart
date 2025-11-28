import 'dart:async';

import 'package:flutter/material.dart';

import '../models/market_quote.dart';
import '../services/credentials_service.dart';
import '../services/market_data_service.dart';
import '../services/scrip_search_service.dart';
import '../services/watchlist_service.dart';
import 'take_position_screen.dart';

class ScripDetailScreen extends StatefulWidget {
  const ScripDetailScreen({super.key, required this.hit});

  final ScripSearchHit hit;

  @override
  State<ScripDetailScreen> createState() => _ScripDetailScreenState();
}

class _ScripDetailScreenState extends State<ScripDetailScreen> {
  MarketQuote? _quote;
  bool _isLoadingQuote = false;
  String? _quoteError;
  final MarketDataService _marketDataService = MarketDataService();
  final CredentialsService _credentialsService = CredentialsService();
  final WatchlistService _watchlistService = WatchlistService();
  StreamSubscription<MarketQuote>? _quoteSubscription;
  bool _isInWatchlist = false;
  bool _isCheckingWatchlist = true;

  @override
  void initState() {
    super.initState();
    _startLivePriceStream();
    _checkWatchlistStatus();
  }

  Future<void> _checkWatchlistStatus() async {
    setState(() {
      _isCheckingWatchlist = true;
    });
    final entries = await _watchlistService.fetchEntries();
    final entryId = '${widget.hit.segmentCode}|${widget.hit.primaryValue}'.toLowerCase();
    final isInWatchlist = entries.any((entry) => entry.id == entryId);
    if (mounted) {
      setState(() {
        _isInWatchlist = isInWatchlist;
        _isCheckingWatchlist = false;
      });
    }
  }

  Future<void> _toggleWatchlist() async {
    if (_isInWatchlist) {
      // Remove from watchlist
      final entryId = '${widget.hit.segmentCode}|${widget.hit.primaryValue}'.toLowerCase();
      await _watchlistService.removeEntry(entryId);
      if (mounted) {
        setState(() {
          _isInWatchlist = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.hit.primaryValue} removed from watchlist.'),
          ),
        );
      }
    } else {
      // Add to watchlist
      final added = await _watchlistService.addHit(widget.hit);
      if (mounted) {
        setState(() {
          _isInWatchlist = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added
                  ? '${widget.hit.primaryValue} added to watchlist.'
                  : '${widget.hit.primaryValue} is already in watchlist.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _startLivePriceStream() async {
    setState(() {
      _isLoadingQuote = true;
      _quoteError = null;
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null) {
        if (mounted) {
          setState(() {
            _quoteError = 'Credentials not configured';
            _isLoadingQuote = false;
          });
        }
        return;
      }

      // Construct symbol: {segmentCode}|{symbol}
      // Based on Python implementation:
      // - For indices (nse_cm): use symbol name (e.g., "Nifty 50")
      // - For CM stocks: try trading symbol name first, then numeric token
      // - For F&O: use numeric pSymbol token
      final isCashMarket = widget.hit.segmentCode.toLowerCase().contains('_cm');
      final isFno = widget.hit.segmentCode.toLowerCase().contains('_fo');
      final token = widget.hit.metadata['pSymbol']?.trim();
      final trdSymbol = widget.hit.metadata['pTrdSymbol']?.trim();
      final scripRefKey = widget.hit.metadata['pScripRefKey']?.trim();

      String tradingSymbol;
      if (isFno) {
        // For F&O: use numeric pSymbol token (required)
        tradingSymbol = token ?? scripRefKey ?? widget.hit.primaryValue;
      } else if (isCashMarket) {
        // For CM stocks: WebSocket requires numeric pSymbol token (not trading symbol name)
        // Only use name for indices like "Nifty 50"
        final isIndex =
            widget.hit.primaryValue.toLowerCase().contains('nifty') ||
            widget.hit.primaryValue.toLowerCase().contains('sensex') ||
            widget.hit.primaryValue.toLowerCase().contains('bank');
        if (isIndex) {
          // For indices, use the name (e.g., "Nifty 50")
          tradingSymbol = widget.hit.primaryValue;
        } else {
          // For regular stocks, use numeric token
          tradingSymbol = token ?? scripRefKey ?? widget.hit.primaryValue;
        }
      } else {
        // Default: use numeric token
        tradingSymbol = token ?? scripRefKey ?? widget.hit.primaryValue;
      }

      final symbol = '${widget.hit.segmentCode}|$tradingSymbol';

      debugPrint(
        'ScripDetailScreen: Subscribing to WebSocket for symbol: $symbol '
        '(pSymbol: ${token ?? "N/A"}, pTrdSymbol: ${trdSymbol ?? "N/A"}, '
        'pScripRefKey: ${scripRefKey ?? "N/A"}, primaryValue: ${widget.hit.primaryValue})',
      );

      // Use WebSocket instead of REST API (like dashboard does for Nifty)
      // Check if WebSocket is enabled
      if (MarketDataService.disableWebSocket) {
        debugPrint('WebSocket is disabled - skipping quote subscription');
        if (mounted) {
          setState(() {
            _isLoadingQuote = false;
            _quoteError = 'WebSocket is disabled in Settings';
          });
        }
        return;
      }
      
      _quoteSubscription?.cancel();
      _quoteSubscription = _marketDataService
          .symbolWebsocketStream(credentials, symbol)
          .listen(
            (quote) {
              if (mounted) {
                setState(() {
                  _quote = quote;
                  _isLoadingQuote = false;
                  _quoteError = null;
                });
              }
            },
            onError: (error) {
              if (mounted) {
                final errorMessage = error.toString();
                String displayError;
                if (errorMessage.contains('503') ||
                    errorMessage.contains('temporarily unavailable')) {
                  displayError =
                      'Server temporarily unavailable. Please try again in a moment.';
                } else if (errorMessage.contains('401') ||
                    errorMessage.contains('403') ||
                    errorMessage.contains('Authorization')) {
                  displayError =
                      'Authentication failed. Please check your credentials.';
                } else if (errorMessage.contains('No quotes available')) {
                  displayError = 'No market data available for this symbol.';
                } else {
                  displayError = errorMessage;
                }

                setState(() {
                  _quoteError = displayError;
                  _isLoadingQuote = false;
                });
              }
            },
          );
    } catch (e) {
      if (mounted) {
        setState(() {
          _quoteError = e.toString();
          _isLoadingQuote = false;
        });
      }
    }
  }

  Future<void> _fetchLivePrice() async {
    _startLivePriceStream();
  }

  @override
  void dispose() {
    _quoteSubscription?.cancel();
    _marketDataService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metadataEntries = widget.hit.metadata.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hit.primaryValue),
        actions: [
          if (!_isCheckingWatchlist)
            IconButton(
              icon: Icon(_isInWatchlist ? Icons.bookmark : Icons.bookmark_border),
              onPressed: _toggleWatchlist,
              tooltip: _isInWatchlist ? 'Remove from watchlist' : 'Add to watchlist',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchLivePrice,
            tooltip: 'Refresh price',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Live Price Card
          if (_isLoadingQuote)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(width: 16),
                    Text(
                      'Fetching live price...',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            )
          else if (_quoteError != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Unable to fetch live price',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onErrorContainer,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _quoteError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_quote != null)
            _buildPriceCard(context, _quote!),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.hit.segmentName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    label: 'Segment code',
                    value: widget.hit.segmentCode,
                  ),
                  _DetailRow(
                    label: widget.hit.primaryField,
                    value: widget.hit.primaryValue,
                  ),
                  if ((widget.hit.secondaryValue ?? '').isNotEmpty)
                    _DetailRow(
                      label: 'Symbol',
                      value: widget.hit.secondaryValue!,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: metadataEntries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No additional columns available for this row.',
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: metadataEntries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = metadataEntries[index];
                      return ListTile(
                        title: Text(entry.key),
                        subtitle: Text(
                          entry.value.isEmpty ? '—' : entry.value,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TakePositionScreen(hit: widget.hit),
                ),
              );
            },
            icon: const Icon(Icons.playlist_add_check),
            label: const Text('Take Position'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPriceCard(BuildContext context, MarketQuote quote) {
    final theme = Theme.of(context);
    final isPositive = (quote.change ?? 0) >= 0;
    final changeColor = isPositive ? Colors.green : Colors.red;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Live Price',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (quote.timestamp != null)
                  Text(
                    _formatTime(quote.timestamp!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '₹${_formatPrice(quote.lastPrice)}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (quote.change != null && quote.changePercent != null)
                  Row(
                    children: [
                      Icon(
                        isPositive ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 20,
                        color: changeColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '₹${_formatPrice(quote.change!.abs())} (${_formatPercent(quote.changePercent!.abs())}%)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: changeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            if (quote.closePrice != null) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _PriceInfoItem(
                    label: 'Previous Close',
                    value: '₹${_formatPrice(quote.closePrice!)}',
                  ),
                  if (quote.openPrice != null)
                    _PriceInfoItem(
                      label: 'Open',
                      value: '₹${_formatPrice(quote.openPrice!)}',
                    ),
                  if (quote.highPrice != null)
                    _PriceInfoItem(
                      label: 'High',
                      value: '₹${_formatPrice(quote.highPrice!)}',
                    ),
                  if (quote.lowPrice != null)
                    _PriceInfoItem(
                      label: 'Low',
                      value: '₹${_formatPrice(quote.lowPrice!)}',
                    ),
                  if (quote.volume != null)
                    _PriceInfoItem(
                      label: 'Volume',
                      value: _formatNumber(quote.volume!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatPrice(double price) {
    return price.toStringAsFixed(2);
  }

  String _formatPercent(double percent) {
    return percent.toStringAsFixed(2);
  }

  String _formatNumber(double number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(2)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(2)}K';
    }
    return number.toStringAsFixed(0);
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _PriceInfoItem extends StatelessWidget {
  const _PriceInfoItem({required this.label, required this.value});

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
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
