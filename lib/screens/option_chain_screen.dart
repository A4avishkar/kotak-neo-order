import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/credentials.dart';
import '../models/market_quote.dart';
import '../models/option_chain_entry.dart';
import '../services/credentials_service.dart';
import '../services/market_data_service.dart';
import '../services/option_chain_service.dart';
import '../services/scrip_search_service.dart';
import 'scrip_detail_screen.dart';

/// Helper class for token lookup optimization
class _TokenLocation {
  final int entryIndex;
  final bool isCE;
  
  _TokenLocation(this.entryIndex, this.isCE);
}

class OptionChainScreen extends StatefulWidget {
  const OptionChainScreen({super.key});

  @override
  State<OptionChainScreen> createState() => _OptionChainScreenState();
}

class _OptionChainScreenState extends State<OptionChainScreen> {
  final _optionChainService = OptionChainService();
  final _marketDataService = MarketDataService();
  final _credentialsService = CredentialsService();

  List<OptionChainEntry> _optionChain = [];
  List<OptionChainEntry> _filteredOptionChain = []; // Filtered to show ±10 strikes around spot
  List<String> _availableExpiries = [];
  String? _selectedExpiry;
  List<String> _availableIndices = [];
  String _selectedIndex = 'NIFTY'; // Default to NIFTY
  List<String> _availableSegments = [];
  String _selectedSegment = 'nse_fo'; // Default to NSE F&O
  MarketQuote? _niftyQuote; // Keep name for backward compatibility, but will hold current index quote
  bool _isLoading = true;
  String? _errorMessage;
  bool _isConnected = false;
  bool _showOI = false; // Toggle between OI and Price view

  StreamSubscription<MarketQuote>? _niftySubscription;
  final Map<String, StreamSubscription<MarketQuote>> _optionSubscriptions = {};
  // Store ALL live option data (including OI) we receive from WebSocket
  // This allows us to preserve last known OI when we get blank/NA values
  // OI is continuously fetched and saved, UI updates immediately
  final Map<String, OptionData> _liveOptionData = {}; // token -> OptionData (all values saved)
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToSpot = false; // Track if we've already scrolled to spot price
  
  // Performance optimization: Map token -> (entryIndex, isCE) for O(1) lookups
  final Map<String, _TokenLocation> _tokenIndexMap = {};
  
  // Batch updates to reduce setState calls
  Timer? _updateBatchTimer;
  final Set<String> _pendingUpdates = {};
  bool _isLoadingMoreAbove = false; // Loading more strikes above
  bool _isLoadingMoreBelow = false; // Loading more strikes below
  int _strikesAboveSpot = 10; // Current number of strikes above spot price
  int _strikesBelowSpot = 10; // Current number of strikes below spot price
  double _pullDistanceTop = 0.0; // Track how far user has pulled at top edge
  double _pullDistanceBottom = 0.0; // Track how far user has pulled at bottom edge
  bool _isPullingAbove = false; // User is pulling at top
  bool _isPullingBelow = false; // User is pulling at bottom
  Timer? _holdTimerTop; // Timer for holding at top edge
  Timer? _holdTimerBottom; // Timer for holding at bottom edge

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _niftySubscription?.cancel();
    for (var subscription in _optionSubscriptions.values) {
      subscription.cancel();
    }
    _updateBatchTimer?.cancel();
    _holdTimerTop?.cancel();
    _holdTimerBottom?.cancel();
    _holdTimerTop?.cancel();
    _holdTimerBottom?.cancel();
    _scrollController.dispose();
    _marketDataService.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Load credentials and segments in parallel (segments don't need credentials)
      debugPrint('Loading credentials and segments in parallel...');
      final credentialsFuture = _credentialsService.getCredentials();
      final segmentsFuture = _optionChainService.getAvailableFoSegments();
      
      final results = await Future.wait([credentialsFuture, segmentsFuture]);
      final credentials = results[0] as Credentials?;
      final segments = results[1] as List<String>;
      
      if (credentials == null || !credentials.isValid) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Please configure credentials in Settings.';
        });
        return;
      }
      
      if (segments.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'No F&O segments found. Please download scrip master files from Settings.';
        });
        return;
      }
      
      // Set default segment if not already set
      final defaultSegment = segments.contains('nse_fo') ? 'nse_fo' : segments.first;
      final currentSegment = _selectedSegment.isNotEmpty && segments.contains(_selectedSegment)
          ? _selectedSegment
          : defaultSegment;
      
      setState(() {
        _availableSegments = segments;
        _selectedSegment = currentSegment;
      });
      
      // Load available indices for the selected segment
      debugPrint('Loading available indices for $currentSegment...');
      final indices = await _optionChainService.getAvailableIndices(segment: currentSegment);
      if (!mounted) return;

      if (indices.isEmpty) {
      setState(() {
          _isLoading = false;
          _errorMessage = 'No indices found in $currentSegment. Please ensure scrip master is downloaded.';
        });
        return;
      }
      
      // Set default index if not already set
      final defaultIndex = indices.contains('NIFTY') ? 'NIFTY' : indices.first;
      final currentIndex = _selectedIndex.isNotEmpty && indices.contains(_selectedIndex) 
          ? _selectedIndex 
          : defaultIndex;
      
      setState(() {
        _availableIndices = indices;
        _selectedIndex = currentIndex;
      });

      // Load data for the current index and segment
      await _loadDataForIndex(currentIndex, currentSegment, credentials);
      if (!mounted) return;
    } catch (e, stackTrace) {
      debugPrint('Error in _initialize: $e');
      debugPrint('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading option chain: ${e.toString()}';
      });
    }
  }

  /// Gets the market data symbol for a given index
  String _getIndexSymbol(String index) {
    // Map index names to their market data symbols
    final indexSymbolMap = {
      // NSE indices
      'NIFTY': 'nse_cm|Nifty 50',
      'BANKNIFTY': 'nse_cm|Nifty Bank',
      'FINNIFTY': 'nse_cm|Nifty Fin Service',
      'MIDCPNIFTY': 'nse_cm|Nifty Midcap Select',
      'NIFTYIT': 'nse_cm|Nifty IT',
      // BSE indices - try different formats
      'SENSEX': 'bse_cm|SENSEX', // Try without "30" first
      'BANKEX': 'bse_cm|BANKEX',
    };
    
    return indexSymbolMap[index] ?? 'nse_cm|Nifty 50'; // Default to NIFTY
  }

  // Removed _fetchIndexQuote - using WebSocket only for better performance

  Future<void> _onSegmentChanged(String? newSegment) async {
    if (newSegment == null || newSegment == _selectedSegment) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedSegment = newSegment;
      _selectedIndex = 'NIFTY'; // Reset to default
      _selectedExpiry = null;
      _availableIndices = [];
      _availableExpiries = [];
      _optionChain = [];
      _filteredOptionChain = [];
      _niftyQuote = null;
      _hasScrolledToSpot = false;
      _strikesAboveSpot = 10;
      _strikesBelowSpot = 10;
    });

    try {
      // Cancel existing subscriptions
      _niftySubscription?.cancel();
      _niftySubscription = null;
      for (var subscription in _optionSubscriptions.values) {
        subscription.cancel();
      }
      _optionSubscriptions.clear();
      _liveOptionData.clear();

      // Load credentials
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Please configure credentials in Settings.';
        });
        return;
      }

      // Load available indices for new segment
      debugPrint('Loading available indices for $newSegment...');
      final indices = await _optionChainService.getAvailableIndices(segment: newSegment);
      if (!mounted) return;

      if (indices.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'No indices found in $newSegment.';
        });
        return;
      }

      // Set default index
      final defaultIndex = indices.contains('NIFTY') ? 'NIFTY' : indices.first;
      setState(() {
        _availableIndices = indices;
        _selectedIndex = defaultIndex;
      });

      // Now load data for the default index
      await _loadDataForIndex(defaultIndex, newSegment, credentials);
    } catch (e, stackTrace) {
      debugPrint('Error in _onSegmentChanged: $e');
      debugPrint('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading segment $newSegment: ${e.toString()}';
      });
    }
  }

  Future<void> _onIndexChanged(String? newIndex) async {
    if (newIndex == null || newIndex == _selectedIndex) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedIndex = newIndex;
      _selectedExpiry = null;
      _availableExpiries = [];
      _optionChain = [];
      _filteredOptionChain = [];
      _niftyQuote = null; // Clear old spot price to avoid using wrong value
      _hasScrolledToSpot = false;
      _strikesAboveSpot = 10;
      _strikesBelowSpot = 10;
    });

    try {
      // Cancel existing subscriptions FIRST to prevent old data from interfering
      _niftySubscription?.cancel();
      _niftySubscription = null;
      for (var subscription in _optionSubscriptions.values) {
        subscription.cancel();
      }
      _optionSubscriptions.clear();
      _liveOptionData.clear();

      // Load credentials
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Please configure credentials in Settings.';
        });
        return;
      }

      // Don't fetch via REST - wait for WebSocket data (more efficient)
      debugPrint('Waiting for ${newIndex} spot price via WebSocket...');

      // Load data for the new index
      await _loadDataForIndex(newIndex, _selectedSegment, credentials);
    } catch (e, stackTrace) {
      debugPrint('Error in _onIndexChanged: $e');
      debugPrint('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading option chain for $newIndex: ${e.toString()}';
      });
    }
  }

  Future<void> _loadDataForIndex(String index, String segment, Credentials credentials) async {
    // Note: Option chain data (CSV) can be loaded even when OI is disabled
    // Only live WebSocket subscriptions are blocked when OI is disabled
    
    // Load nearest expiry for index (this also caches all expiries)
    debugPrint('Loading nearest expiry for $index in $segment...');
    final optionChain = await _optionChainService.loadNearestExpiry(symbol: index, segment: segment);
    if (!mounted) return;

    // Get all available expiries (should be instant from cache after loadNearestExpiry)
    final expiries = await _optionChainService.getAvailableExpiries(symbol: index, segment: segment);
    if (!mounted) return;

    if (expiries.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'No $index option expiries found in $segment.';
      });
      return;
    }

    // Get nearest expiry from cached data (no need to call service again)
    // The first expiry is always the nearest (sorted by date)
    final selectedExpiry = expiries.first;

    if (optionChain.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'No option chain data found for expiry: $selectedExpiry';
      });
      return;
    }

    // Show UI immediately with option chain data - don't wait for spot price
    setState(() {
      _availableExpiries = expiries;
      _selectedExpiry = selectedExpiry;
      _optionChain = optionChain;
      _isLoading = false; // Show UI immediately
      _isConnected = true;
    });

    // Build token index map for O(1) lookups
    _buildTokenIndexMap();

    // Filter option chain - use spot price if available, otherwise show default range
    _filterOptionChain(optionChain);

    // Check if OI & Option Chain data is enabled for live subscriptions
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (oiAndOptionChainEnabled) {
      // Check if WebSocket is enabled
      if (MarketDataService.disableWebSocket) {
        debugPrint('WebSocket is disabled - showing option chain without live updates');
        setState(() {
          _isConnected = false; // No live connection
        });
        return;
      }
      
      // Subscribe to index for live spot price (in background, don't block UI)
      debugPrint('Subscribing to $index index for live spot price...');
      final indexSymbol = _getIndexSymbol(index);
      _niftySubscription = _marketDataService
          .symbolWebsocketStream(credentials, indexSymbol)
          .listen(
            _handleNiftyUpdate,
            onError: (error) {
              if (!mounted) return;
              debugPrint('$index feed error: $error');
              setState(() {
                _isConnected = false;
              });
            },
          );

      debugPrint('Waiting for $index spot price from WebSocket before subscribing to options...');
    } else {
      debugPrint('OI & Option Chain data is disabled - showing option chain without live updates');
      // Still show the option chain, just without live data
      setState(() {
        _isConnected = false; // No live connection
      });
    }
  }

  Future<void> _onExpiryChanged(String? newExpiry) async {
    if (newExpiry == null || newExpiry == _selectedExpiry) return;
    
    // Reset scroll flag and strike counts when expiry changes
    _hasScrolledToSpot = false;
    _strikesAboveSpot = 10;
    _strikesBelowSpot = 10;
    _isLoadingMoreAbove = false;
    _isLoadingMoreBelow = false;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Note: Option chain data (CSV) can be loaded even when OI is disabled
      // Only live WebSocket subscriptions are blocked when OI is disabled
      
      // Cancel existing option subscriptions
      for (var subscription in _optionSubscriptions.values) {
        subscription.cancel();
      }
      _optionSubscriptions.clear();
      _liveOptionData.clear();

      // Load option chain for new expiry
      debugPrint('Loading option chain for expiry: $newExpiry (index: $_selectedIndex, segment: $_selectedSegment)');
      final optionChain = await _optionChainService.loadOptionChainForExpiry(newExpiry, symbol: _selectedIndex, segment: _selectedSegment);
      if (!mounted) return;

      debugPrint('Loaded ${optionChain.length} option chain entries for expiry: $newExpiry');

      // Load credentials for subscriptions
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Credentials invalid. Please reconfigure.';
        });
        return;
      }

      // Filter option chain to show ±10 strikes around spot price
      _filterOptionChain(optionChain);

      setState(() {
        _selectedExpiry = newExpiry;
        _optionChain = optionChain;
      });

      // Rebuild token index map for new expiry
      _buildTokenIndexMap();

      // Check if OI & Option Chain data is enabled for live subscriptions
      final prefs = await SharedPreferences.getInstance();
      final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
      
      if (oiAndOptionChainEnabled) {
        // Subscribe to filtered option tokens for new expiry
        debugPrint('Subscribing to ${_filteredOptionChain.length * 2} option tokens for filtered strikes...');
        _subscribeToFilteredOptions(credentials);
      } else {
        debugPrint('OI & Option Chain data is disabled - showing option chain without live updates');
      }

      setState(() {
        _isLoading = false;
      });
      
      // Scroll to spot price after expiry change (if spot price is available)
      if (_niftyQuote != null && _niftyQuote!.lastPrice > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSpotPrice();
        });
      }
    } catch (e, stackTrace) {
      debugPrint('Error changing expiry: $e');
      debugPrint('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading expiry: ${e.toString()}';
      });
    }
  }

  void _subscribeToOptions(Credentials credentials) {
    // Subscribe to all CE and PE tokens
    for (final entry in _optionChain) {
      if (entry.ce != null) {
        _subscribeToOption(credentials, entry.ce!);
      }
      if (entry.pe != null) {
        _subscribeToOption(credentials, entry.pe!);
      }
    }
  }

  // Removed _fetchInitialOIValues - OI comes ONLY from WebSocket live updates (index 22)
  // No REST API fetching - all OI data is live from WebSocket

  void _subscribeToFilteredOptions(Credentials credentials) async {
    // Check if OI & Option Chain data is enabled
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (!oiAndOptionChainEnabled) {
      debugPrint('OI & Option Chain data is disabled - skipping option subscriptions');
      return;
    }
    
    // Get all options we need to subscribe to
    final neededOptions = <OptionData>[];
    final neededTokens = <String>{};
    
    for (final entry in _filteredOptionChain) {
      if (entry.ce != null) {
        neededTokens.add(entry.ce!.token);
        neededOptions.add(entry.ce!);
      }
      if (entry.pe != null) {
        neededTokens.add(entry.pe!.token);
        neededOptions.add(entry.pe!);
      }
    }
    
    // Unsubscribe from tokens we no longer need
    final tokensToUnsubscribe = _optionSubscriptions.keys
        .where((token) => !neededTokens.contains(token))
        .toList();
    
    for (final token in tokensToUnsubscribe) {
      final subscription = _optionSubscriptions.remove(token);
      subscription?.cancel();
      _liveOptionData.remove(token);
    }
    
    // Find options we need but don't have subscriptions for
    final optionsToSubscribe = neededOptions
        .where((opt) => !_optionSubscriptions.containsKey(opt.token))
        .toList();
    
    if (optionsToSubscribe.isNotEmpty) {
      // Use batch subscription for efficiency
      _batchSubscribeToOptions(credentials, optionsToSubscribe);
    }
    
    debugPrint('Active subscriptions: ${_optionSubscriptions.length} batch connections (covering ${neededTokens.length} tokens)');
  }

  void _subscribeToOption(Credentials credentials, OptionData option) {
    final token = option.token;
    if (_optionSubscriptions.containsKey(token)) {
      return; // Already subscribed
    }
    // This method is kept for compatibility but batch subscription is used in _subscribeToFilteredOptions
  }
  
  /// Batch subscribe to multiple options using a single WebSocket connection
  void _batchSubscribeToOptions(Credentials credentials, List<OptionData> options) async {
    // Check if OI & Option Chain data is enabled
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (!oiAndOptionChainEnabled) {
      debugPrint('OI & Option Chain data is disabled - skipping batch option subscription');
      return;
    }
    if (options.isEmpty) return;
    
    // Collect all symbols for batch subscription
    final symbols = <String>[];
    final tokenToOptionMap = <String, OptionData>{};
    
    for (final option in options) {
      final token = option.token;
      if (!_optionSubscriptions.containsKey(token)) {
        final symbol = '${_selectedSegment}|$token';
        symbols.add(symbol);
        tokenToOptionMap[token] = option;
      }
    }
    
    if (symbols.isEmpty) return;
    
    // Use batch subscription (single connection for all symbols)
    debugPrint('Batch subscribing to ${symbols.length} option tokens using single WebSocket connection');
    
    // Use a mutable reference so we can cancel from within the callback
    StreamSubscription<MarketQuote>? batchSubscriptionRef;
    
    final batchSubscription = _marketDataService
        .batchSymbolWebsocketStream(credentials, symbols)
        .listen(
          (quote) async {
            // Check if OI & Option Chain data is still enabled (user might have disabled it)
            final prefs = await SharedPreferences.getInstance();
            final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
            
            if (!oiAndOptionChainEnabled) {
              // OI is disabled - cancel this subscription and stop processing
              batchSubscriptionRef?.cancel();
              debugPrint('OI & Option Chain disabled - cancelling option subscription');
              return;
            }
            
            // Route quote to correct option by extracting numeric token
            final quoteToken = quote.token ?? '';
            final numericToken = _extractNumericTokenFromQuote(quoteToken);
            final oi = quote.openInterest;
            
            // Note: Verbose debug logging disabled to reduce console spam
            // Uncomment below if you need to debug option subscriptions:
            // debugPrint('_batchSubscribeToOptions: Received quote token=$quoteToken (extracted=$numericToken), LTP=${quote.lastPrice}, OI=${oi != null ? oi : "null"}');
            
            bool matched = false;
            
            if (numericToken.isNotEmpty) {
              // Try to match by numeric token first (most reliable)
              if (tokenToOptionMap.containsKey(numericToken)) {
                // Note: Verbose debug logging disabled to reduce console spam
                // debugPrint('_batchSubscribeToOptions: Matched by numeric token $numericToken');
                _handleOptionUpdate(numericToken, quote);
                matched = true;
                return;
              }
            }
            
            // Fallback: try string matching
            for (final entry in tokenToOptionMap.entries) {
              final symbol = '${_selectedSegment}|${entry.key}';
              if (quoteToken == symbol || 
                  quoteToken.contains(entry.key) ||
                  symbol.contains(quoteToken) ||
                  quoteToken.endsWith(entry.key) ||
                  entry.key == numericToken) {
                // Note: Verbose debug logging disabled to reduce console spam
                // debugPrint('_batchSubscribeToOptions: Matched by string matching: $quoteToken -> ${entry.key}');
                _handleOptionUpdate(entry.key, quote);
                matched = true;
                break;
              }
            }
            
            // Note: Verbose debug logging disabled to reduce console spam
            // if (!matched) {
            //   debugPrint('_batchSubscribeToOptions: Quote NOT matched! token=$quoteToken, available tokens: ${tokenToOptionMap.keys.take(5).join(", ")}...');
            // }
          },
          onError: (error) {
            debugPrint('Batch subscription error: $error');
          },
        );
    
    // Store the subscription reference for cancellation from within callback
    batchSubscriptionRef = batchSubscription;
    
    // Store subscription for all tokens in this batch
    // Use a batch key to track this subscription
    final batchKey = 'batch_${symbols.length}_${DateTime.now().millisecondsSinceEpoch}';
    for (final token in tokenToOptionMap.keys) {
      _optionSubscriptions[token] = batchSubscription;
    }
    
    debugPrint('Stored batch subscription for ${tokenToOptionMap.length} tokens');
  }
  
  /// Extracts numeric token from quote token string
  /// Examples: "sf|nse_fo|52829" -> "52829", "nse_fo|52829" -> "52829", "52829" -> "52829"
  String _extractNumericTokenFromQuote(String quoteToken) {
    if (quoteToken.isEmpty) return '';
    
    // Remove prefixes like "sf|", "if|"
    String cleaned = quoteToken.replaceAll(RegExp(r'^(sf|if)\|'), '');
    
    // Extract the last numeric part (token is usually at the end after segment)
    final parts = cleaned.split('|');
    if (parts.length > 1) {
      // Last part is usually the token
      final token = parts.last.trim();
      if (RegExp(r'^\d+$').hasMatch(token)) {
        return token;
      }
    } else {
      // No pipe separator, check if entire string is numeric
      final token = cleaned.trim();
      if (RegExp(r'^\d+$').hasMatch(token)) {
        return token;
      }
    }
    
    // Fallback: try to extract any numeric sequence at the end
    final match = RegExp(r'(\d+)$').firstMatch(cleaned);
    return match?.group(1) ?? '';
  }

  void _handleNiftyUpdate(MarketQuote quote) async {
    if (!mounted) return;
    
    debugPrint('_handleNiftyUpdate: Received quote for ${quote.token}, LTP=${quote.lastPrice}, Change=${quote.change}');
    
    // Store old filtered strikes to compare
    final oldFilteredStrikes = _filteredOptionChain.map((e) => e.strike).toSet();
    final oldFilteredTokens = <String>{};
    for (final entry in _filteredOptionChain) {
      if (entry.ce != null) oldFilteredTokens.add(entry.ce!.token);
      if (entry.pe != null) oldFilteredTokens.add(entry.pe!.token);
    }
    
    final hadSpotPrice = _niftyQuote != null && _niftyQuote!.lastPrice > 0;
    final oldSpotPrice = _niftyQuote?.lastPrice ?? 0;
    
    setState(() {
      _niftyQuote = quote;
      _isConnected = true;
    });
    
    // Only re-filter if spot price actually changed significantly or we didn't have one before
    final newSpotPrice = quote.lastPrice ?? 0;
    if (newSpotPrice > 0 && (!hadSpotPrice || (newSpotPrice - oldSpotPrice).abs() / (oldSpotPrice > 0 ? oldSpotPrice : 1) > 0.01)) {
      debugPrint('Spot price changed from $oldSpotPrice to $newSpotPrice, re-filtering option chain...');
      _filterOptionChain(_optionChain);
    }
    
    // Get new filtered strikes and tokens
    final newFilteredStrikes = _filteredOptionChain.map((e) => e.strike).toSet();
    final newFilteredTokens = <String>{};
    for (final entry in _filteredOptionChain) {
      if (entry.ce != null) newFilteredTokens.add(entry.ce!.token);
      if (entry.pe != null) newFilteredTokens.add(entry.pe!.token);
    }
    
    // If we didn't have a spot price before, this is the first time we're getting it
    // We need to unsubscribe from all old subscriptions and subscribe to new filtered ones
    if (!hadSpotPrice) {
      debugPrint('First spot price received. Re-subscribing to filtered strikes...');
      // Cancel all existing subscriptions
      for (var subscription in _optionSubscriptions.values) {
        subscription.cancel();
      }
      _optionSubscriptions.clear();
      _liveOptionData.clear();
      
      // Check if OI & Option Chain data is enabled for live subscriptions
      final prefs = await SharedPreferences.getInstance();
      final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
      
      if (oiAndOptionChainEnabled) {
        // Subscribe to new filtered strikes
        final credentials = await _credentialsService.getCredentials();
        if (credentials != null && credentials.isValid && mounted) {
          debugPrint('Subscribing to ${_filteredOptionChain.length * 2} option tokens for filtered strikes...');
          _subscribeToFilteredOptions(credentials);
        }
      } else {
        debugPrint('OI & Option Chain data is disabled - skipping live subscriptions');
      }
      
      // Scroll to spot price when it first arrives
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSpotPrice();
      });
      return;
    }
    
    // Only re-subscribe if filtered strikes actually changed
    if (!oldFilteredStrikes.containsAll(newFilteredStrikes) || 
        !newFilteredStrikes.containsAll(oldFilteredStrikes)) {
      debugPrint('Filtered strikes changed. Old: ${oldFilteredStrikes.length}, New: ${newFilteredStrikes.length}');
      
      // Find tokens to unsubscribe (in old but not in new)
      final tokensToUnsubscribe = oldFilteredTokens.difference(newFilteredTokens);
      for (final token in tokensToUnsubscribe) {
        final subscription = _optionSubscriptions.remove(token);
        subscription?.cancel();
        _liveOptionData.remove(token);
      }
      
      // Find tokens to subscribe (in new but not in old)
      final tokensToSubscribe = newFilteredTokens.difference(oldFilteredTokens);
      
      // Check if OI & Option Chain data is enabled for live subscriptions
      final prefs = await SharedPreferences.getInstance();
      final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
      
      if (oiAndOptionChainEnabled) {
        // Subscribe to new tokens
        final credentials = await _credentialsService.getCredentials();
        if (credentials != null && credentials.isValid && mounted) {
          if (tokensToSubscribe.isNotEmpty) {
            debugPrint('Subscribing to ${tokensToSubscribe.length} new option tokens...');
            for (final entry in _filteredOptionChain) {
              if (entry.ce != null && tokensToSubscribe.contains(entry.ce!.token)) {
                _subscribeToOption(credentials, entry.ce!);
              }
              if (entry.pe != null && tokensToSubscribe.contains(entry.pe!.token)) {
                _subscribeToOption(credentials, entry.pe!);
              }
            }
          }
          if (tokensToUnsubscribe.isNotEmpty) {
            debugPrint('Unsubscribed from ${tokensToUnsubscribe.length} option tokens');
          }
        }
      } else {
        // OI is disabled - just unsubscribe from old tokens, don't subscribe to new ones
        if (tokensToUnsubscribe.isNotEmpty) {
          debugPrint('OI & Option Chain disabled - unsubscribed from ${tokensToUnsubscribe.length} option tokens');
        }
      }
    }
  }

  /// Build token index map for O(1) lookups instead of O(n) loops
  void _buildTokenIndexMap() {
    _tokenIndexMap.clear();
    for (int i = 0; i < _optionChain.length; i++) {
      final entry = _optionChain[i];
      if (entry.ce != null) {
        _tokenIndexMap[entry.ce!.token] = _TokenLocation(i, true);
      }
      if (entry.pe != null) {
        _tokenIndexMap[entry.pe!.token] = _TokenLocation(i, false);
      }
    }
  }

  /// Batch updates to reduce setState calls and improve performance
  void _scheduleBatchUpdate() {
    _updateBatchTimer?.cancel();
    _updateBatchTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && _pendingUpdates.isNotEmpty) {
        setState(() {
          // Updates are already applied to _liveOptionData, just trigger rebuild
          _pendingUpdates.clear();
        });
      }
    });
  }

  void _handleOptionUpdate(String token, MarketQuote quote) {
    if (!mounted) return;

    // Use O(1) lookup instead of O(n) loop
    final location = _tokenIndexMap[token];
    if (location == null) {
      debugPrint('_handleOptionUpdate: WARNING - Token $token not found in token index map!');
      return;
    }

    final entry = _optionChain[location.entryIndex];
    final baseOption = location.isCE ? entry.ce : entry.pe;
    if (baseOption == null) return;

    final existingLiveData = _liveOptionData[token];
    final previousOi = existingLiveData?.openInterest;
    final oi = quote.openInterest;
    
    // If OI is null in new quote, preserve the previous saved OI value
    // Priority: new quote OI > existing live data OI > base option OI
    final preservedOi = oi ?? existingLiveData?.openInterest ?? baseOption.openInterest;
    
    // Update data immediately (no setState yet for performance)
    _liveOptionData[token] = baseOption.copyWith(
      lastPrice: quote.lastPrice,
      change: quote.change,
      changePercent: quote.changePercent,
      volume: quote.volume,
      openInterest: preservedOi,
      lastUpdate: quote.timestamp ?? DateTime.now(),
    );

    // Batch setState calls to reduce rebuilds
    _pendingUpdates.add(token);
    _scheduleBatchUpdate();
  }

  OptionData? _getLiveOptionData(OptionData? option) {
    if (option == null) return null;
    final liveData = _liveOptionData[option.token];
    if (liveData != null) {
      return option.copyWith(
        lastPrice: liveData.lastPrice,
        change: liveData.change,
        changePercent: liveData.changePercent,
        volume: liveData.volume,
        openInterest: liveData.openInterest,
        lastUpdate: liveData.lastUpdate,
      );
    }
    return option;
  }

  void _filterOptionChain(List<OptionChainEntry> allEntries) {
    final spotPrice = _niftyQuote?.lastPrice ?? 0;
    
    if (spotPrice <= 0 || allEntries.isEmpty) {
      // If no spot price, show a default range around a middle strike (don't show ALL)
      // This prevents subscribing to hundreds of tokens
      if (allEntries.isEmpty) {
        _filteredOptionChain = [];
        return;
      }
      
      // Check if already sorted to avoid unnecessary sort
      bool isSorted = true;
      for (int i = 1; i < allEntries.length; i++) {
        if (allEntries[i].strike < allEntries[i - 1].strike) {
          isSorted = false;
          break;
        }
      }
      
      final sorted = isSorted 
          ? allEntries 
          : (List<OptionChainEntry>.from(allEntries)..sort((a, b) => a.strike.compareTo(b.strike)));
      final middleIndex = sorted.length ~/ 2;
      final startIndex = (middleIndex - _strikesAboveSpot).clamp(0, sorted.length);
      final endIndex = (middleIndex + _strikesBelowSpot + 1).clamp(0, sorted.length);
      _filteredOptionChain = sorted.sublist(startIndex, endIndex);
      debugPrint('No spot price yet. Showing default range: ${_filteredOptionChain.length} strikes');
      return;
    }

    // Check if already sorted to avoid unnecessary sort
    bool isSorted = true;
    for (int i = 1; i < allEntries.length; i++) {
      if (allEntries[i].strike < allEntries[i - 1].strike) {
        isSorted = false;
        break;
      }
    }
    
    // Only sort if needed
    final sortedEntries = isSorted 
        ? allEntries 
        : (List<OptionChainEntry>.from(allEntries)..sort((a, b) => a.strike.compareTo(b.strike)));

    // Find the strike closest to spot price using binary search for better performance
    int closestIndex = 0;
    double minDiff = double.infinity;
    for (int i = 0; i < sortedEntries.length; i++) {
      final diff = (sortedEntries[i].strike - spotPrice).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestIndex = i;
      } else {
        // Since list is sorted, we can break early if strikes are getting farther
        break;
      }
    }

    // Get strikes above and below based on current range
    final startIndex = (closestIndex - _strikesAboveSpot).clamp(0, sortedEntries.length);
    final endIndex = (closestIndex + _strikesBelowSpot + 1).clamp(0, sortedEntries.length); // +1 to include the closest one
    
    _filteredOptionChain = sortedEntries.sublist(startIndex, endIndex);
    
    debugPrint('Filtered option chain: ${_filteredOptionChain.length} strikes around spot price $spotPrice (${_strikesAboveSpot} above, ${_strikesBelowSpot} below, closest strike: ${allEntries[closestIndex].strike})');
    
    // Scroll to spot price row after filtering (only once)
    if (!_hasScrolledToSpot && spotPrice > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSpotPrice();
      });
    }
  }
  
  void _scrollToSpotPrice() {
    if (!_scrollController.hasClients || _hasScrolledToSpot) return;
    
    final niftyPrice = _niftyQuote?.lastPrice ?? 0;
    if (niftyPrice <= 0) return;
    
    final displayChain = _filteredOptionChain.isNotEmpty 
        ? _filteredOptionChain 
        : _optionChain;
    
    if (displayChain.isEmpty) return;
    
    // Find the index where spot price should be inserted
    int spotPriceIndex = -1;
    for (int i = 0; i < displayChain.length; i++) {
      if (displayChain[i].strike >= niftyPrice) {
        spotPriceIndex = i;
        break;
      }
    }
    if (spotPriceIndex == -1) {
      spotPriceIndex = displayChain.length;
    }
    
    // Wait a bit for the viewport to be ready, then scroll
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_scrollController.hasClients || !mounted) return;
      
      // Calculate approximate scroll position (each row is ~60-70 pixels)
      final estimatedRowHeight = 65.0;
      final spotPriceRowPosition = spotPriceIndex * estimatedRowHeight;
      
      // Get viewport height to center the spot price row
      final viewportHeight = _scrollController.position.viewportDimension;
      if (viewportHeight > 0) {
        final centeredScrollPosition = spotPriceRowPosition - (viewportHeight / 2) + (estimatedRowHeight / 2);
        
        // Scroll to center the spot price row in the viewport
        _scrollController.animateTo(
          centeredScrollPosition.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
        
        _hasScrolledToSpot = true;
        debugPrint('Scrolled to center spot price at index $spotPriceIndex (scroll position: $centeredScrollPosition, viewport: $viewportHeight)');
      }
    });
  }
  
  void _handleScrollUpdate(ScrollUpdateNotification notification) {
    if (!_scrollController.hasClients) return;
    
    final scrollPosition = _scrollController.position.pixels;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final scrollDelta = notification.scrollDelta ?? 0;
    
    // Detect pull at top: user is at top edge (within 2px) and trying to scroll up (pull down)
    // scrollDelta < 0 means user is dragging down (trying to pull more content from top)
    if (scrollPosition <= 2 && scrollDelta < 0) {
      // User is at top and pulling down - accumulate pull distance
      _pullDistanceTop += scrollDelta.abs();
      if (!_isPullingAbove) {
        setState(() {
          _isPullingAbove = true;
        });
      }
      
      // If user has pulled enough (80px threshold), start hold timer
      if (_pullDistanceTop >= 80 && !_isLoadingMoreAbove && _holdTimerTop == null) {
        // Start 1 second hold timer
        _holdTimerTop = Timer(const Duration(seconds: 1), () {
          if (mounted && !_isLoadingMoreAbove) {
            _loadMoreStrikesAbove();
            _pullDistanceTop = 0;
          }
          _holdTimerTop = null;
        });
      }
    } else if (scrollPosition > 2) {
      // User moved away from top - cancel timer and reset
      _holdTimerTop?.cancel();
      _holdTimerTop = null;
      if (_isPullingAbove || _pullDistanceTop > 0) {
        setState(() {
          _isPullingAbove = false;
        });
        _pullDistanceTop = 0;
      }
    }
    
    // Detect pull at bottom: user is at bottom edge (within 2px) and trying to scroll down (pull up)
    // scrollDelta > 0 means user is dragging up (trying to pull more content from bottom)
    if (scrollPosition >= maxScrollExtent - 2 && scrollDelta > 0) {
      // User is at bottom and pulling up - accumulate pull distance
      _pullDistanceBottom += scrollDelta.abs();
      if (!_isPullingBelow) {
        setState(() {
          _isPullingBelow = true;
        });
      }
      
      // If user has pulled enough (80px threshold), start hold timer
      if (_pullDistanceBottom >= 80 && !_isLoadingMoreBelow && _holdTimerBottom == null) {
        // Start 1 second hold timer
        _holdTimerBottom = Timer(const Duration(seconds: 1), () {
          if (mounted && !_isLoadingMoreBelow) {
            _loadMoreStrikesBelow();
            _pullDistanceBottom = 0;
          }
          _holdTimerBottom = null;
        });
      }
    } else if (scrollPosition < maxScrollExtent - 2) {
      // User moved away from bottom - cancel timer and reset
      _holdTimerBottom?.cancel();
      _holdTimerBottom = null;
      if (_isPullingBelow || _pullDistanceBottom > 0) {
        setState(() {
          _isPullingBelow = false;
        });
        _pullDistanceBottom = 0;
      }
    }
  }
  
  void _handleScrollEnd() {
    // Cancel any active hold timers when scroll ends
    _holdTimerTop?.cancel();
    _holdTimerTop = null;
    _holdTimerBottom?.cancel();
    _holdTimerBottom = null;
    
    // Reset pull state when scroll ends
    if (_isPullingAbove || _isPullingBelow || _pullDistanceTop > 0 || _pullDistanceBottom > 0) {
      setState(() {
        _isPullingAbove = false;
        _isPullingBelow = false;
      });
      _pullDistanceTop = 0;
      _pullDistanceBottom = 0;
    }
  }
  
  Future<void> _loadMoreStrikesAbove() async {
    if (_isLoadingMoreAbove || _optionChain.isEmpty) return;
    
    setState(() {
      _isLoadingMoreAbove = true;
    });
    
    // Simulate loading delay for better UX
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Expand strikes above by 5
    _strikesAboveSpot += 5;
    
    // Re-filter the option chain with new range
    final spotPrice = _niftyQuote?.lastPrice ?? 0;
    if (spotPrice > 0) {
      _filterOptionChain(_optionChain);
    } else {
      // If no spot price, use default range
      final sorted = List<OptionChainEntry>.from(_optionChain);
      sorted.sort((a, b) => a.strike.compareTo(b.strike));
      final middleIndex = sorted.length ~/ 2;
      final startIndex = (middleIndex - _strikesAboveSpot).clamp(0, sorted.length);
      final endIndex = (middleIndex + _strikesBelowSpot + 1).clamp(0, sorted.length);
      setState(() {
        _filteredOptionChain = sorted.sublist(startIndex, endIndex);
      });
    }
    
    // Check if OI & Option Chain data is enabled for live subscriptions
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (oiAndOptionChainEnabled) {
      // Subscribe to new option tokens
      final credentials = await _credentialsService.getCredentials();
      if (credentials != null && credentials.isValid && mounted) {
        _subscribeToFilteredOptions(credentials);
      }
    } else {
      debugPrint('OI & Option Chain data is disabled - skipping live subscriptions');
    }
    
    // Maintain scroll position (add offset for new rows)
    final estimatedRowHeight = 65.0;
    final scrollOffset = 5 * estimatedRowHeight; // 5 new rows
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.pixels + scrollOffset);
    }
    
    setState(() {
      _isLoadingMoreAbove = false;
    });
    
    debugPrint('Loaded 5 more strikes above. Total above: $_strikesAboveSpot');
  }
  
  Future<void> _loadMoreStrikesBelow() async {
    if (_isLoadingMoreBelow || _optionChain.isEmpty) return;
    
    setState(() {
      _isLoadingMoreBelow = true;
    });
    
    // Simulate loading delay for better UX
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Expand strikes below by 5
    _strikesBelowSpot += 5;
    
    // Re-filter the option chain with new range
    final spotPrice = _niftyQuote?.lastPrice ?? 0;
    if (spotPrice > 0) {
      _filterOptionChain(_optionChain);
    } else {
      // If no spot price, use default range
      final sorted = List<OptionChainEntry>.from(_optionChain);
      sorted.sort((a, b) => a.strike.compareTo(b.strike));
      final middleIndex = sorted.length ~/ 2;
      final startIndex = (middleIndex - _strikesAboveSpot).clamp(0, sorted.length);
      final endIndex = (middleIndex + _strikesBelowSpot + 1).clamp(0, sorted.length);
      setState(() {
        _filteredOptionChain = sorted.sublist(startIndex, endIndex);
      });
    }
    
    // Check if OI & Option Chain data is enabled for live subscriptions
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (oiAndOptionChainEnabled) {
      // Subscribe to new option tokens
      final credentials = await _credentialsService.getCredentials();
      if (credentials != null && credentials.isValid && mounted) {
        _subscribeToFilteredOptions(credentials);
      }
    } else {
      debugPrint('OI & Option Chain data is disabled - skipping live subscriptions');
    }
    
    setState(() {
      _isLoadingMoreBelow = false;
    });
    
    debugPrint('Loaded 5 more strikes below. Total below: $_strikesBelowSpot');
  }
  
  Widget _buildLoadingIndicator(bool isTop) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Row(
          children: [
            // Segment selector (left side)
            if (_availableSegments.isNotEmpty)
              _buildSegmentSelector(),
            // Index selector (middle) - takes remaining space
            if (_availableIndices.isNotEmpty)
              Expanded(
                child: Center(
                  child: _buildIndexSelector(),
                ),
              ),
            // Expiry selector (right side)
            if (_availableExpiries.isNotEmpty)
              _buildExpirySelectorInAppBar(),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      final isFileNotFound = _errorMessage!.toLowerCase().contains('not found') ||
          _errorMessage!.toLowerCase().contains('directory');
      
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red.shade400),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              if (isFileNotFound) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade900.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade700),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.blue.shade300, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'How to fix:',
                            style: TextStyle(
                              color: Colors.blue.shade300,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '1. Go to Settings and download the NSE F&O scrip master\n'
                        '2. The app will automatically load NIFTY options from the scrip master\n'
                        '3. All available expiries will be shown in the dropdown',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _initialize,
                icon: const Icon(Icons.replay),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildColumnHeaders(),
        Expanded(
          child: _buildOptionChainTable(),
        ),
      ],
    );
  }

  Widget _buildSegmentSelector() {
    if (_availableSegments.isEmpty) {
      return const SizedBox.shrink();
    }

    return DropdownButton<String>(
      value: _selectedSegment,
      dropdownColor: const Color(0xFF1E293B),
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      underline: const SizedBox(),
      icon: const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 20),
      items: _availableSegments.map<DropdownMenuItem<String>>((String value) {
        final displayName = OptionChainService.segmentDisplayNames[value] ?? value.toUpperCase();
        return DropdownMenuItem<String>(
          value: value,
          child: Text(displayName),
        );
      }).toList(),
      onChanged: _isLoading ? null : (String? newValue) {
        if (newValue != null) {
          _onSegmentChanged(newValue);
        }
      },
    );
  }

  Widget _buildIndexSelector() {
    if (_availableIndices.isEmpty) {
      return const Text('NIFTY 50', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold));
    }

    return DropdownButton<String>(
      value: _selectedIndex,
      dropdownColor: const Color(0xFF1E293B),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
      underline: const SizedBox(),
      icon: const Icon(Icons.arrow_drop_down, color: Colors.white, size: 24),
      items: _availableIndices.map<DropdownMenuItem<String>>((String value) {
        // Format index name for display
        String displayName = value;
        if (value == 'NIFTY') {
          displayName = 'NIFTY 50';
        } else if (value == 'BANKNIFTY') {
          displayName = 'BANKNIFTY';
        } else if (value == 'FINNIFTY') {
          displayName = 'FINNIFTY';
        }
        
        return DropdownMenuItem<String>(
          value: value,
          child: Text(displayName),
        );
      }).toList(),
      onChanged: _isLoading ? null : (String? newValue) {
        if (newValue != null) {
          _onIndexChanged(newValue);
        }
      },
    );
  }

  Widget _buildExpirySelectorInAppBar() {
    if (_availableExpiries.isEmpty) {
      return const SizedBox.shrink();
    }

    // Format expiry for display (e.g., "25NOV25" -> "25 Nov")
    String formatExpiry(String expiry) {
      if (expiry.length >= 7) {
        final day = expiry.substring(0, 2);
        final month = expiry.substring(2, 5);
        return '$day $month';
      }
      return expiry;
    }

    return DropdownButton<String>(
      value: _selectedExpiry,
      dropdownColor: const Color(0xFF1E293B),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      underline: const SizedBox(),
      icon: const Icon(Icons.arrow_drop_down, color: Colors.white, size: 20),
      items: _availableExpiries.map<DropdownMenuItem<String>>((String value) {
        return DropdownMenuItem<String>(
          value: value,
          child: Text(formatExpiry(value)),
        );
      }).toList(),
      onChanged: _isLoading ? null : (String? newValue) {
        if (newValue != null) {
          _onExpiryChanged(newValue);
        }
      },
    );
  }

  Widget _buildExpirySelector() {
    if (_availableExpiries.isEmpty) {
      return const SizedBox.shrink();
    }

    // Get nearest expiry for highlighting
    final nearestExpiry = _availableExpiries.isNotEmpty 
        ? _availableExpiries.first 
        : null; // First expiry is nearest (sorted ascending)

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF1E293B),
      child: Row(
            children: [
              const Text(
            'Expiry:',
                style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              value: _selectedExpiry,
              isExpanded: true,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(
                  color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              underline: Container(
                height: 1,
                color: Colors.white30,
              ),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
              items: _availableExpiries.map((expiry) {
                final isNearest = expiry == nearestExpiry;
                return DropdownMenuItem<String>(
                  value: expiry,
                  child: Row(
                children: [
                      Text(expiry),
                      if (isNearest) ...[
                        const SizedBox(width: 8),
                  Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.green, width: 1),
                          ),
                          child: const Text(
                            'Default',
                    style: TextStyle(
                              color: Colors.green,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }).toList(),
              onChanged: _isLoading ? null : _onExpiryChanged,
            ),
              ),
            ],
          ),
    );
  }

  Widget _buildToggleButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF1E293B),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildToggleButton('OI', !_showOI, () {
            setState(() => _showOI = false);
          }),
          const SizedBox(width: 12),
          _buildToggleButton('Price', _showOI, () {
            setState(() => _showOI = true);
          }),
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF3B82F6) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF3B82F6) : Colors.white30,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildNiftyIndexCard() {
    final quote = _niftyQuote;
    final price = quote?.lastPrice ?? 0;
    final change = quote?.change ?? 0;
    final changePercent = quote?.changePercent ?? 0;
    final isGain = change >= 0;
    final changeColor = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10, width: 1),
      ),
      child: Column(
            children: [
              Text(
            price > 0 ? price.toStringAsFixed(2) : '—',
                style: const TextStyle(
              fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
          const SizedBox(height: 8),
          Text(
                  '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} (${changePercent >= 0 ? '+' : ''}${changePercent.toStringAsFixed(2)}%)',
                  style: TextStyle(
              fontSize: 16,
                    color: changeColor,
                    fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpotPriceRow() {
    final quote = _niftyQuote;
    final spotPrice = quote?.lastPrice ?? 0;
    final change = quote?.change ?? 0;
    final changePercent = quote?.changePercent ?? 0;
    final isGain = change >= 0;
    final changeColor = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFF3B82F6),
          width: 1.5,
        ),
      ),
      child: Center(
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              TextSpan(
                text: '${_selectedIndex == 'NIFTY' ? 'NIFTY 50' : _selectedIndex} ',
                style: const TextStyle(
                  color: Color(0xFF3B82F6),
                    fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: spotPrice > 0 ? spotPrice.toStringAsFixed(2) : '—',
                style: const TextStyle(
                  color: Color(0xFFFFA500), // Orange/Yellow color
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextSpan(
                text: ' ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}',
                style: TextStyle(
                  color: changeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColumnHeaders() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: const Color(0xFF1E293B),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              'Call price',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'OI',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Strike',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'OI',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'Put price',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionChainTable() {
    if (_filteredOptionChain.isEmpty && _optionChain.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            'No option chain data available',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }

    // Use filtered chain if available, otherwise use full chain
    final displayChain = _filteredOptionChain.isNotEmpty 
        ? _filteredOptionChain 
        : _optionChain;

    final niftyPrice = _niftyQuote?.lastPrice ?? 0;
    
    // Find the index where spot price should be inserted
    int spotPriceIndex = -1;
    if (niftyPrice > 0) {
      for (int i = 0; i < displayChain.length; i++) {
        if (displayChain[i].strike >= niftyPrice) {
          spotPriceIndex = i;
          break;
        }
      }
      if (spotPriceIndex == -1) {
        spotPriceIndex = displayChain.length;
      }
    }

    return Container(
      color: const Color(0xFF0F172A),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (notification is ScrollUpdateNotification) {
            _handleScrollUpdate(notification);
          } else if (notification is ScrollEndNotification) {
            // Also check on scroll end to catch edge cases
            _handleScrollEnd();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(), // Enable overscroll bounce for pull-to-load-more
          // Cache more items for smoother scrolling
          cacheExtent: 1000,
          // Add itemExtent for better performance (approximate row height)
          itemExtent: null, // Let it calculate dynamically for variable heights
          itemCount: displayChain.length + (spotPriceIndex >= 0 ? 1 : 0) + 
                     (_isLoadingMoreAbove ? 1 : 0) + (_isLoadingMoreBelow ? 1 : 0),
        itemBuilder: (context, index) {
          final hasTopLoader = _isLoadingMoreAbove ? 1 : 0;
          final hasSpotPrice = spotPriceIndex >= 0 ? 1 : 0;
          final hasBottomLoader = _isLoadingMoreBelow ? 1 : 0;
          final dataItems = displayChain.length + hasSpotPrice;
          
          // Show loading indicator at top
          if (hasTopLoader > 0 && index == 0) {
            return _buildLoadingIndicator(true);
          }
          
          // Adjust index for loading indicator at top
          int adjustedIndex = index - hasTopLoader;
          
          // Show loading indicator at bottom
          if (hasBottomLoader > 0 && adjustedIndex >= dataItems) {
            return _buildLoadingIndicator(false);
          }
          
          // Insert spot price row at the calculated position
          if (spotPriceIndex >= 0 && adjustedIndex == spotPriceIndex) {
            return _buildSpotPriceRow();
          }
          
          // Adjust index if spot price was inserted before this item
          final actualIndex = spotPriceIndex >= 0 && adjustedIndex > spotPriceIndex 
              ? adjustedIndex - 1 
              : adjustedIndex;
          
          // Check bounds
          if (actualIndex < 0 || actualIndex >= displayChain.length) {
            return const SizedBox.shrink();
          }
          
          final entry = displayChain[actualIndex];
            final ce = _getLiveOptionData(entry.ce);
            final pe = _getLiveOptionData(entry.pe);
          // Highlight the strike closest to spot price (ATM - At The Money)
          final isAtm = niftyPrice > 0 && (entry.strike - niftyPrice).abs() < 50;
            
          // Wrap in RepaintBoundary to isolate repaints and improve scrolling performance
          return RepaintBoundary(
            child: Container(
              color: isAtm 
              ? const Color(0xFF1E3A8A).withOpacity(0.2)
              : (index % 2 == 0 ? const Color(0xFF1E293B) : const Color(0xFF0F172A)),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Row(
              children: [
                // Call price
                Expanded(
                  flex: 3,
                  child: _buildPriceCell(ce, true),
                ),
                // Call OI
                Expanded(
                  flex: 2,
                  child: _buildOICell(ce),
                ),
                // Strike price (center)
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isAtm)
                        Container(
                          width: double.infinity,
                          height: 2,
                          color: const Color(0xFF3B82F6),
                          margin: const EdgeInsets.only(bottom: 4),
                        ),
                  Text(
                    entry.strike.toStringAsFixed(0),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: isAtm ? FontWeight.bold : FontWeight.normal,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                // Put OI
                Expanded(
                  flex: 2,
                  child: _buildOICell(pe),
                ),
                // Put price
                Expanded(
                  flex: 3,
                  child: _buildPriceCell(pe, false),
                ),
              ],
            ),
          ),
          );
        },
        ),
      ),
    );
  }

  Widget _buildPriceCell(OptionData? option, bool isCall) {
    if (option == null) {
      return const RepaintBoundary(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '0.00',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 2),
            Text(
              '+0.00%',
              style: TextStyle(color: Color(0xFF34D399), fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final price = option.lastPrice ?? 0;
    final change = option.changePercent ?? 0;
    final isGain = change >= 0;
    final color = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);

    return RepaintBoundary(
      child: GestureDetector(
      onTap: () => _navigateToDetailScreen(option),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            price > 0 ? price.toStringAsFixed(2) : '0.00',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
            style: TextStyle(
              color: color,
              fontSize: 11,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      ),
    );
  }

  /// Converts OptionData to ScripSearchHit for navigation to detail screen
  ScripSearchHit _optionDataToScripSearchHit(OptionData option) {
    final segmentName = OptionChainService.segmentDisplayNames[_selectedSegment] ?? 
                       _selectedSegment.toUpperCase();
    
    // Use pTrdSymbol from CSV if available (correct format from scrip master)
    // If not available, fallback to deriving from pScripRefKey (for backward compatibility)
    String? pTrdSymbol = option.trdSymbol;
    if (pTrdSymbol == null || pTrdSymbol.isEmpty) {
      // Fallback: Try to derive from scripRefKey (may not be accurate)
      if (option.scripRefKey.isNotEmpty && option.scripRefKey.contains('.00') && 
          (option.scripRefKey.endsWith('CE') || option.scripRefKey.endsWith('PE'))) {
        pTrdSymbol = option.scripRefKey.replaceAll('.00', '');
      }
    }
    
    // Build metadata map with all available option data
    final metadata = <String, String>{
      'pSymbol': option.token,
      'pScripRefKey': option.scripRefKey,
      if (pTrdSymbol != null && pTrdSymbol.isNotEmpty) 'pTrdSymbol': pTrdSymbol,
      'pOptionType': option.optionType,
      if (option.lastPrice != null) 'lastPrice': option.lastPrice.toString(),
      if (option.bid != null) 'bid': option.bid.toString(),
      if (option.ask != null) 'ask': option.ask.toString(),
      if (option.bidQty != null) 'bidQty': option.bidQty.toString(),
      if (option.askQty != null) 'askQty': option.askQty.toString(),
      if (option.openInterest != null) 'openInterest': option.openInterest.toString(),
      if (option.volume != null) 'volume': option.volume.toString(),
      if (option.change != null) 'change': option.change.toString(),
      if (option.changePercent != null) 'changePercent': option.changePercent.toString(),
    };

    return ScripSearchHit(
      segmentCode: _selectedSegment,
      segmentName: segmentName,
      primaryField: 'pScripRefKey',
      primaryValue: option.scripRefKey.isNotEmpty ? option.scripRefKey : option.symbol,
      metadata: metadata,
    );
  }

  /// Navigates to the detail screen for the selected option
  void _navigateToDetailScreen(OptionData option) {
    final hit = _optionDataToScripSearchHit(option);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScripDetailScreen(hit: hit),
      ),
    );
  }

  Widget _buildOICell(OptionData? option) {
    if (option == null) {
      return const RepaintBoundary(
        child: Text(
          '—',
          style: TextStyle(color: Colors.white70, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }

    // Handle OI display:
    // - If OI is null/NA AND we never received OI -> show "N/A"
    // - If OI is null/NA BUT we have previous saved value -> use previous value (shouldn't happen here)
    // - If OI is 0 -> show "0" (might be valid - no open interest)
    // - If OI > 0 -> show formatted number
    final oi = option.openInterest;

    if (oi == null) {
      // OI is null/NA - this means we never received OI data from WebSocket
      // (Previous saved values are preserved in _handleOptionUpdate, so if we reach here,
      //  it means we truly never got OI data for this option)
      return const RepaintBoundary(
        child: Text(
          'N/A',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    // OI is not null - display it (even if 0, as 0 might be valid)
    return RepaintBoundary(
      child: Text(
        oi > 0 ? _formatNumber(oi) : '0',
        style: TextStyle(
          color: oi > 0 ? Colors.white70 : Colors.white54,
          fontSize: 12,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildHeaderCell(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 11,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildOptionCell(OptionData? option, String field) {
    if (option == null) {
      return const Text(
        '—',
        style: TextStyle(color: Colors.white70, fontSize: 11),
        textAlign: TextAlign.center,
      );
    }

    String text = '—';
    Color? color;

    switch (field) {
      case 'ltp':
        if (option.lastPrice != null) {
          text = option.lastPrice!.toStringAsFixed(2);
          color = Colors.white;
        }
        break;
      case 'change':
        if (option.change != null && option.changePercent != null) {
          final isGain = option.change! >= 0;
          color = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);
          text = '${option.change! >= 0 ? '+' : ''}${option.change!.toStringAsFixed(2)}\n(${option.changePercent! >= 0 ? '+' : ''}${option.changePercent!.toStringAsFixed(2)}%)';
        }
        break;
      case 'volume':
        if (option.volume != null) {
          text = _formatNumber(option.volume!);
          color = Colors.white70;
        }
        break;
      case 'oi':
        if (option.openInterest != null) {
          text = _formatNumber(option.openInterest!);
          color = Colors.white70;
        }
        break;
    }

    return Text(
      text,
      style: TextStyle(
        color: color ?? Colors.white70,
        fontSize: 11,
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _formatNumber(double value) {
    if (value >= 1e6) {
      return '${(value / 1e6).toStringAsFixed(2)}M';
    }
    if (value >= 1e3) {
      return '${(value / 1e3).toStringAsFixed(2)}K';
    }
    return value.toStringAsFixed(0);
  }
}

