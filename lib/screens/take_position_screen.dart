import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/credentials.dart';
import '../models/market_quote.dart';
import '../models/order_request.dart';
import '../services/credentials_service.dart';
import '../services/kotak_api_service.dart';
import '../services/market_data_service.dart';
import '../services/scrip_search_service.dart';
import '../services/watchlist_service.dart';

class TakePositionScreen extends StatefulWidget {
  const TakePositionScreen({
    super.key,
    required this.hit,
    this.initialQuantity,
    this.initialPrice,
  });

  final ScripSearchHit hit;
  final String? initialQuantity;
  final String? initialPrice;

  @override
  State<TakePositionScreen> createState() => _TakePositionScreenState();
}

class _TakePositionScreenState extends State<TakePositionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quantityController = TextEditingController();
  final _priceController = TextEditingController();
  final _tagController = TextEditingController();
  final _symbolController = TextEditingController();

  final _credentialsService = CredentialsService();
  final _apiService = KotakApiService();
  final _marketDataService = MarketDataService();
  final _scripSearchService = ScripSearchService();
  final _watchlistService = WatchlistService();

  bool _isLoading = false;
  bool _isDryRun = false; // Always live mode
  String? _loadingTransactionType; // Track which button is loading
  String _product = 'MIS'; // Will be set in initState based on segment
  String _orderType = 'L'; // Default to Limit order
  MarketQuote? _currentQuote;
  final ValueNotifier<MarketQuote?> _quoteNotifier = ValueNotifier<MarketQuote?>(null);
  bool _isLoadingQuote = false;
  StreamSubscription<MarketQuote>? _quoteSubscription;
  Timer? _quoteUpdateTimer;
  bool _hasReceivedFirstQuote = false;

  // Holdings data for current stock
  Map<String, dynamic>? _currentStockHolding;
  bool _isLoadingHolding = false;

  // Watchlist status
  bool _isInWatchlist = false;
  bool _isCheckingWatchlist = true;

  final List<String> _products = ['MIS', 'NRML', 'CNC', 'CO', 'BO'];
  final List<String> _orderTypes = ['MKT', 'L', 'SL', 'SL-M'];

  late final String _segment;
  late final bool _isCashSegment;
  late final Map<String, String> _metadata;
  late final List<String> _symbolCandidates;
  late final String? _resolvedSymbol;
  late final String? _displaySymbol;

  @override
  void initState() {
    super.initState();
    _segment = widget.hit.segmentCode;
    _isCashSegment = _segment.toLowerCase().contains('_cm');
    _metadata = widget.hit.metadata;
    _symbolCandidates = _buildSymbolCandidates(widget.hit);
    _resolvedSymbol = _symbolCandidates.isNotEmpty
        ? _symbolCandidates.first
        : null;
    _displaySymbol =
        _clean(_metadata['pTrdSymbol']) ??
        _clean(widget.hit.secondaryValue) ??
        _resolvedSymbol;
    
    // Initialize symbol controller with resolved symbol
    _symbolController.text = _resolvedSymbol ?? '';

    // Set default product type based on segment
    // For stocks (cash segment): CNC, For options (F&O): NRML
    final isFno = _segment.toLowerCase().contains('_fo');
    _product = _isCashSegment ? 'CNC' : (isFno ? 'NRML' : 'MIS');

    // Set initial quantity: use provided initialQuantity, or lot size, or leave empty
    if (widget.initialQuantity != null && widget.initialQuantity!.isNotEmpty) {
      _quantityController.text = widget.initialQuantity!;
    } else {
      final lotSize = _clean(_metadata['lLotSize']);
      if (lotSize != null) {
        _quantityController.text = lotSize;
      }
    }

    // Set initial price if provided
    if (widget.initialPrice != null && widget.initialPrice!.isNotEmpty) {
      _priceController.text = widget.initialPrice!;
    }

    // Build extra tags once
    _extraTags = _buildExtraTags();

    // Fetch current market price
    _fetchCurrentPrice();

    // Fetch holdings for current stock
    _fetchCurrentStockHolding();

    // Check watchlist status
    _checkWatchlistStatus();
  }

  @override
  void dispose() {
    _quoteSubscription?.cancel();
    _quoteUpdateTimer?.cancel();
    _quoteNotifier.dispose();
    _marketDataService.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _tagController.dispose();
    _symbolController.dispose();
    super.dispose();
  }

  String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<String> _buildSymbolCandidates(ScripSearchHit hit) {
    final metadata = hit.metadata;
    final orderedRawValues = _isCashSegment
        ? [
            metadata['pSymbol'],
            metadata['pTrdSymbol'],
            metadata['pScripRefKey'],
            metadata['pISIN'],
            hit.primaryValue,
            hit.secondaryValue,
          ]
        : [
            // For F&O: Try pTrdSymbol first (correct format without .00 that API accepts)
            // Then pScripRefKey without .00, then pScripRefKey with .00, then numeric pSymbol token
            metadata['pTrdSymbol'],
            metadata['pScripRefKey'],
            metadata['pSymbol'],
            metadata['pISIN'],
            hit.secondaryValue,
            hit.primaryValue,
          ];

    final deduped = <String>{};
    final candidates = <String>[];
    for (final raw in orderedRawValues) {
      final cleaned = _clean(raw);
      if (cleaned == null) continue;
      final formatted = _formatSymbol(cleaned);
      if (formatted.isEmpty) continue;
      
      // For F&O options: Match Python CLI approach - try without .00 first, then with .00
      if (!_isCashSegment && formatted.contains('.00') && 
          (formatted.endsWith('CE') || formatted.endsWith('PE'))) {
        // Python CLI: Try WITHOUT .00 first (e.g., SENSEX27NOV2585200PE)
        final withoutDotZero = formatted.replaceAll('.00', '');
        if (deduped.add(withoutDotZero)) {
          candidates.add(withoutDotZero);
          print('Symbol candidate added (without .00): $withoutDotZero');
        }
        // Python CLI: Then try WITH .00 (e.g., SENSEX27NOV2585200.00PE)
        if (deduped.add(formatted)) {
          candidates.add(formatted);
          print('Symbol candidate added (with .00): $formatted');
        }
      } else {
        // For other symbols (stocks, futures), add as-is
        if (deduped.add(formatted)) {
          candidates.add(formatted);
          print('Symbol candidate added (as-is): $formatted');
        }
      }
    }
    print('Total symbol candidates: ${candidates.length}');
    return candidates;
  }

  String _formatSymbol(String raw) {
    final trimmed = raw.trim();
    final isNumeric = double.tryParse(trimmed) != null;
    if (_isCashSegment) {
      return trimmed;
    }
    return isNumeric ? trimmed : trimmed.toUpperCase();
  }

  Future<void> _fetchCurrentPrice() async {
    if (_resolvedSymbol == null) return;

    setState(() {
      _isLoadingQuote = true;
      _hasReceivedFirstQuote = false;
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null) {
        if (mounted) {
          setState(() {
            _isLoadingQuote = false;
          });
        }
        return;
      }

      // Construct symbol: {segmentCode}|{symbol}
      final isFno = _segment.toLowerCase().contains('_fo');
      final token = _clean(_metadata['pSymbol']);
      final trdSymbol = _clean(_metadata['pTrdSymbol']);
      final scripRefKey = _clean(_metadata['pScripRefKey']);

      String tradingSymbol;
      if (isFno) {
        // For F&O: use numeric pSymbol token (required)
        tradingSymbol = token ?? scripRefKey ?? _resolvedSymbol!;
      } else if (_isCashSegment) {
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
          tradingSymbol = token ?? scripRefKey ?? _resolvedSymbol!;
        }
      } else {
        // Default: use numeric token
        tradingSymbol = token ?? scripRefKey ?? _resolvedSymbol!;
      }

      final symbol = '$_segment|$tradingSymbol';

      // Use WebSocket for live price updates
      // Check if WebSocket is enabled
      if (MarketDataService.disableWebSocket) {
        debugPrint('WebSocket is disabled - skipping quote subscription');
        if (mounted) {
          setState(() {
            _isLoadingQuote = false;
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
                // Store latest quote immediately (always have most recent data)
                _currentQuote = quote;
                _isLoadingQuote = false;
                // Auto-populate price field with current market price (only once)
                // Price is not auto-filled - user must enter manually
                
                // First quote update immediately, then batch subsequent updates
                if (!_hasReceivedFirstQuote) {
                  _hasReceivedFirstQuote = true;
                  _quoteNotifier.value = quote;
                  setState(() {
                    // First update - show data immediately
                  });
                } else {
                  // Update ValueNotifier immediately (no rebuild needed)
                  _quoteNotifier.value = quote;
                  // Batch setState calls to prevent lagging - only rebuild every 200ms
                  _quoteUpdateTimer?.cancel();
                  _quoteUpdateTimer = Timer(const Duration(milliseconds: 200), () {
                    if (mounted) {
                      setState(() {
                        // Minimal rebuild - quote display uses ValueListenableBuilder
                      });
                    }
                  });
                }
              }
            },
            onError: (error) {
              if (mounted) {
                _quoteUpdateTimer?.cancel();
                setState(() {
                  _isLoadingQuote = false;
                });
              }
            },
          );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingQuote = false;
        });
      }
    }
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

  Future<void> _fetchCurrentStockHolding() async {
    if (!_isCashSegment || _resolvedSymbol == null) return;

    setState(() {
      _isLoadingHolding = true;
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        if (mounted) {
          setState(() {
            _isLoadingHolding = false;
          });
        }
        return;
      }

      final holdingsResult = await _apiService.executeHoldingsFetch(credentials);

      if (!mounted) return;

      // Handle different response structures
      // Python CLI shows: { "data": [...] } where data is directly a List
      List<dynamic> holdings;
      if (holdingsResult['data'] != null) {
        final holdingsData = holdingsResult['data'];
        if (holdingsData is List) {
          holdings = holdingsData;
        } else if (holdingsData is Map && holdingsData['holdings'] != null) {
          holdings = holdingsData['holdings'] as List;
        } else {
          holdings = [];
        }
      } else if (holdingsResult['holdings'] != null) {
        holdings = holdingsResult['holdings'] as List;
      } else {
        holdings = [];
      }

      // Debug: Print holdings structure
      print('Holdings count: ${holdings.length}');
      if (holdings.isNotEmpty) {
        print('First holding keys: ${(holdings.first as Map).keys}');
      }

      // Find holding for current stock
      Map<String, dynamic>? foundHolding;
      final currentSymbol = _displaySymbol?.toUpperCase() ?? 
                           _resolvedSymbol?.toUpperCase() ?? '';
      
      for (final holding in holdings) {
        if (holding is! Map) continue;
        
        // Try multiple field names for symbol (Python CLI shows 'symbol' and 'displaySymbol')
        final holdingSymbol = (holding['symbol'] ?? 
                              holding['displaySymbol'] ??
                              holding['tradingSymbol'] ?? 
                              holding['pSymbol'] ??
                              holding['commonScripCode'] ??
                              '').toString().toUpperCase();
        
        // Try multiple field names for segment (Python CLI shows 'exchangeSegment')
        final segment = (holding['exchangeSegment'] ??
                        holding['segment'] ?? 
                        holding['exchange'] ??
                        '').toString().toLowerCase();
        
        print('Checking holding: symbol=$holdingSymbol, segment=$segment, currentSymbol=$currentSymbol');
        
        // Match by symbol and ensure it's cash segment
        if (holdingSymbol.isNotEmpty && 
            (holdingSymbol == currentSymbol || 
             holdingSymbol.contains(currentSymbol) ||
             currentSymbol.contains(holdingSymbol)) &&
            (segment.contains('_cm') || segment.contains('cm') || segment == 'nse_cm' || segment == 'bse_cm')) {
          foundHolding = holding as Map<String, dynamic>;
          print('Found matching holding: $foundHolding');
          break;
        }
      }

      if (mounted) {
        setState(() {
          _currentStockHolding = foundHolding;
          _isLoadingHolding = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingHolding = false;
        });
      }
      // Silently fail - holdings are optional
    }
  }

  Future<void> _placeOrder(String transactionType) async {
    final userSymbol = _symbolController.text.trim();
    if (userSymbol.isEmpty && _symbolCandidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a trading symbol or ensure symbol is available.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_orderType == 'L' && _priceController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Price is required for Limit orders'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingTransactionType = transactionType;
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        throw Exception('Please configure credentials first');
      }

      // Use tag from field if provided, otherwise auto-generate unique tag
      final tagText = _tagController.text.trim();
      final uniqueTag = tagText.isEmpty
          ? 'MOBILE_APP_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}'
          : tagText; // Use tag exactly as entered by user

      // Build symbol candidates: user-entered symbol first, then fallback candidates
      final userSymbol = _symbolController.text.trim();
      final symbolsToTry = <String>[];
      
      // If user entered a symbol, try it first
      if (userSymbol.isNotEmpty) {
        symbolsToTry.add(userSymbol);
      }
      
      // Then add other candidates (excluding the one already tried)
      for (final candidate in _symbolCandidates) {
        if (candidate != userSymbol && !symbolsToTry.contains(candidate)) {
          symbolsToTry.add(candidate);
        }
      }
      
      // If no symbols to try, use original candidates
      if (symbolsToTry.isEmpty) {
        symbolsToTry.addAll(_symbolCandidates);
      }

      final orderRequests = symbolsToTry
          .map(
            (symbol) => OrderRequest(
              segment: _segment,
              symbol: symbol,
              transactionType: transactionType,
              product: _product,
              orderType: _orderType,
              quantity: int.parse(_quantityController.text.trim()),
              price: _priceController.text.trim().isNotEmpty
                  ? double.parse(_priceController.text.trim())
                  : null,
              tag: uniqueTag,
            ),
          )
          .toList();

      // Always execute live order (dry run removed)
      await _attemptLiveOrder(credentials, orderRequests);
    } catch (error) {
      if (!mounted) return;
      var message = _cleanErrorMessage(error.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingTransactionType = null;
        });
      }
    }
  }

  Future<void> _attemptLiveOrder(
    Credentials credentials,
    List<OrderRequest> requests,
  ) async {
    // Match Python CLI approach: try each symbol variant until one succeeds
    Exception? lastError;
    for (final request in requests) {
      try {
        print('Attempting order with symbol: ${request.symbol}...');
        final result = await _apiService.executeOrderPlacement(
          credentials,
          request,
        );
        if (!mounted) return;
        // Success! Show result and return
        _showOrderResult(result, request.symbol);
        return;
      } catch (error) {
        lastError = error is Exception ? error : Exception(error.toString());
        final message = _cleanErrorMessage(error.toString());
        final isSymbolError = _looksLikeSymbolError(message);
        
        // If this is not the last request and it's a symbol error, try next variant
        if (isSymbolError && request != requests.last) {
          print('Failed with symbol "${request.symbol}", trying next variant...');
          continue;
        }
        
        // If non-symbol error or last request, show error
        if (!mounted) return;
        if (!isSymbolError) {
          // Non-symbol error - show immediately
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 8),
            ),
          );
          return;
        }
        
        // Last symbol variant failed - show summary
        if (request == requests.last) {
          final attemptMessages = requests
              .map((r) => '${r.symbol} → ${_cleanErrorMessage(error.toString())}')
              .toList();
          _showSymbolAttemptSummary(attemptMessages);
        }
      }
    }
    
    // All variants failed
    if (lastError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('All symbol variants failed: ${_cleanErrorMessage(lastError.toString())}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  bool _looksLikeSymbolError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('valid symbol') ||
        lower.contains('symbol') ||
        lower.contains('scrip') ||
        lower.contains('body invalid');
  }

  String _cleanErrorMessage(String message) {
    var cleaned = message;
    if (cleaned.contains('Exception: ')) {
      cleaned = cleaned.replaceFirst('Exception: ', '');
    }
    return cleaned.trim();
  }

  void _showSymbolAttemptSummary(List<String> attempts) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Symbol attempts failed'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: attempts
                .map(
                  (line) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(line),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showOrderPreview(
    OrderRequest orderRequest,
    List<String> symbolVariants,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Order Preview'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPreviewRow('Segment', orderRequest.segment),
              _buildPreviewRow('Trading Symbol', orderRequest.symbol),
              _buildPreviewRow(
                'Transaction',
                orderRequest.transactionType == 'B' ? 'BUY' : 'SELL',
              ),
              _buildPreviewRow('Product', orderRequest.product),
              _buildPreviewRow('Order Type', orderRequest.orderType),
              _buildPreviewRow('Quantity', orderRequest.quantity.toString()),
              if (orderRequest.price != null)
                _buildPreviewRow(
                  'Price',
                  orderRequest.price!.toStringAsFixed(2),
                ),
              if (orderRequest.tag != null)
                _buildPreviewRow('Tag', orderRequest.tag!),
              if (symbolVariants.length > 1) ...[
                const SizedBox(height: 12),
                const Text(
                  'Symbol variants that will be tried (ordered):',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: symbolVariants
                      .map(
                        (symbol) => Chip(
                          label: Text(symbol),
                          avatar: const Icon(Icons.tag, size: 16),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _placeOrder(orderRequest.transactionType);
            },
            child: const Text('Place Live Order'),
          ),
        ],
      ),
    );
  }

  void _showOrderResult(Map<String, dynamic> result, String symbolUsed) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Order Result'),
        content: SingleChildScrollView(
          child: Text(
            'Symbol: $symbolUsed\n\n$result',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }


  Widget _buildPreviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  // Cache expensive computations
  late final List<Widget> _extraTags;

  List<Widget> _buildExtraTags() {
    final tags = <Widget>[];
    final instrumentType = _clean(_metadata['pInstType']);
    if (instrumentType != null) {
      tags.add(_InfoChip(label: 'Instrument', value: instrumentType));
    }
    final expiry = _clean(_metadata['pExpiryDate']);
    if (expiry != null) {
      tags.add(_InfoChip(label: 'Expiry', value: expiry));
    }
    final lotSize = _clean(_metadata['lLotSize']);
    if (lotSize != null) {
      tags.add(_InfoChip(label: 'Lot size', value: lotSize));
    }
    return tags;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hit.primaryValue),
        actions: [
          if (!_isCheckingWatchlist)
            IconButton(
              icon: Icon(_isInWatchlist ? Icons.bookmark : Icons.bookmark_border),
              tooltip: _isInWatchlist ? 'Remove from watchlist' : 'Add to watchlist',
              onPressed: _toggleWatchlist,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            // Add cacheExtent for better scrolling performance
            cacheExtent: 500,
            children: [
              if (_isLoadingQuote) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Fetching current price...',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                // Use ValueListenableBuilder to isolate quote updates
                ValueListenableBuilder<MarketQuote?>(
                  valueListenable: _quoteNotifier,
                  builder: (context, quote, child) {
                    if (quote == null) return const SizedBox.shrink();
                    return _QuoteDisplay(quote: quote);
                  },
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                enabled: false,
                initialValue: _segment.toUpperCase(),
                decoration: const InputDecoration(
                  labelText: 'Exchange Segment',
                  prefixIcon: Icon(Icons.business),
                  helperText: 'Locked for this instrument',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _symbolController,
                decoration: const InputDecoration(
                  labelText: 'Order Identifier',
                  prefixIcon: Icon(Icons.tag),
                  helperText: 'Trading symbol used for API call (editable)',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _product,
                decoration: const InputDecoration(
                  labelText: 'Product *',
                  prefixIcon: Icon(Icons.category),
                ),
                items: _products
                    .map(
                      (product) => DropdownMenuItem(
                        value: product,
                        child: Text(product),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _product = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _orderType,
                decoration: const InputDecoration(
                  labelText: 'Order Type *',
                  prefixIcon: Icon(Icons.list),
                ),
                items: _orderTypes
                    .map(
                      (type) =>
                          DropdownMenuItem(value: type, child: Text(type)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _orderType = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantityController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Quantity *',
                  prefixIcon: Icon(Icons.numbers),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Quantity is required';
                  }
                  final parsed = int.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid quantity';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _orderType == 'L' ? 'Price *' : 'Price (Optional)',
                  prefixIcon: const Icon(Icons.currency_rupee),
                ),
                validator: (value) {
                  if (_orderType == 'L') {
                    if (value == null || value.trim().isEmpty) {
                      return 'Price is required for Limit orders';
                    }
                    final parsed = double.tryParse(value.trim());
                    if (parsed == null || parsed <= 0) {
                      return 'Enter a valid price';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tagController,
                decoration: const InputDecoration(
                  labelText: 'Order Identifier / Tag',
                  prefixIcon: Icon(Icons.label),
                  helperText: 'Leave empty for auto-generated tag, or enter custom identifier',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: RepaintBoundary(
                      child: ElevatedButton.icon(
                        onPressed: (_symbolController.text.trim().isEmpty && _resolvedSymbol == null) || _isLoading
                            ? null
                            : () => _placeOrder('B'),
                        icon: _isLoading && _loadingTransactionType == 'B'
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.shopping_cart_checkout),
                        label: const Text('BUY'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RepaintBoundary(
                      child: ElevatedButton.icon(
                        onPressed: (_symbolController.text.trim().isEmpty && _resolvedSymbol == null) || _isLoading
                            ? null
                            : () => _placeOrder('S'),
                        icon: _isLoading && _loadingTransactionType == 'S'
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sell),
                        label: const Text('SELL'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_resolvedSymbol == null) ...[
                const SizedBox(height: 12),
                Text(
                  'Unable to auto-populate a trading symbol for this entry. '
                  'Please cross-check the scrip master and try again.',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label, 
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: DefaultTextStyle(
        style: Theme.of(
          context,
        ).textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w600),
        child: Text('$label: $value'),
      ),
    );
  }
}

class _QuoteDisplay extends StatelessWidget {
  const _QuoteDisplay({required this.quote});

  final MarketQuote quote;

  String _formatVolume(double? volume) {
    if (volume == null) return 'N/A';
    if (volume >= 1000000000) {
      return '${(volume / 1000000000).toStringAsFixed(2)}B';
    } else if (volume >= 1000000) {
      return '${(volume / 1000000).toStringAsFixed(2)}M';
    } else if (volume >= 1000) {
      return '${(volume / 1000).toStringAsFixed(2)}K';
    }
    return volume.toStringAsFixed(0);
  }

  String _formatTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    final priceText = '₹${quote.lastPrice.toStringAsFixed(2)}';
    final change = quote.change ?? 0.0;
    final changePercent = quote.changePercent ?? 0.0;
    final isPositive = change >= 0;
    final changeText = '₹${change.abs().toStringAsFixed(2)} (${changePercent.abs().toStringAsFixed(2)}%)';
    final changeColor = isPositive ? Colors.green : Colors.red;
    
    final previousClose = quote.closePrice ?? 0.0;
    final open = quote.openPrice ?? 0.0;
    final high = quote.highPrice ?? 0.0;
    final low = quote.lowPrice ?? 0.0;
    final volume = quote.volume;
    final timestamp = quote.timestamp ?? DateTime.now();

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with title and timestamp
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Live Price',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _formatTime(timestamp),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Current Price and Change
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  priceText,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  isPositive ? Icons.arrow_upward : Icons.arrow_downward,
                  color: changeColor,
                  size: 24,
                ),
                const SizedBox(width: 4),
                Text(
                  changeText,
                  style: TextStyle(
                    color: changeColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Market Data Grid
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Previous Close',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${previousClose.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Open',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${open.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'High',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${high.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Low',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${low.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Volume
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Volume',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatVolume(volume),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[300],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
