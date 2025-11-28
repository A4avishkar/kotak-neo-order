import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/credentials.dart';
import '../models/market_quote.dart';
import '../models/option_chain_entry.dart';
import '../services/credentials_service.dart';
import '../services/kotak_api_service.dart';
import '../services/market_data_service.dart';
import '../services/option_chain_service.dart';
import '../services/scrip_master_service.dart';
import '../services/scrip_search_service.dart';
import '../widgets/scrip_search_delegate.dart';
import 'orders_screen.dart';
import 'positions_screen.dart';
import 'scrip_detail_screen.dart';
import 'settings_screen.dart';
import 'watchlist_screen.dart';
import 'option_chain_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _credentialsService = CredentialsService();
  final _scripSearchService = ScripSearchService();
  final _optionChainService = OptionChainService();
  final _scripMasterService = ScripMasterService();
  late final MarketDataService _marketDataService;
  int _selectedNavIndex = 0;

  StreamSubscription<MarketQuote>? _quoteSubscription;
  StreamSubscription<MarketQuote>? _sensexQuoteSubscription;
  Credentials? _credentials;
  MarketQuote? _latestQuote;
  MarketQuote? _latestSensexQuote;

  double? _previousPrice;
  double? _previousSensexPrice;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isConnected = false;
  bool _isSensexConnected = false;
  final PageController _pageController = PageController();
  int _currentPageIndex = 0;

  // OI data - using WebSocket subscriptions like option chain screen
  double? _niftyCallOI;
  double? _niftyPutOI;
  double? _sensexCallOI;
  double? _sensexPutOI;
  final Map<String, StreamSubscription<MarketQuote>> _niftyOptionSubscriptions = {};
  final Map<String, StreamSubscription<MarketQuote>> _sensexOptionSubscriptions = {};
  // Store ALL OI values we receive from WebSocket (continuously updated)
  // This allows us to preserve last known OI when we get blank/NA values
  // Only totals are recalculated at the OI update interval (throttled)
  final Map<String, double> _niftyOptionOI = {}; // token -> OI (all values saved)
  final Map<String, double> _sensexOptionOI = {}; // token -> OI (all values saved)
  Set<String> _niftyValidTokens = {}; // Valid tokens from filtered chain
  Set<String> _sensexValidTokens = {}; // Valid tokens from filtered chain
  Map<String, String> _niftyTokenToOptionType = {}; // token -> CE/PE
  Map<String, String> _sensexTokenToOptionType = {}; // token -> CE/PE
  List<OptionChainEntry>? _filteredNiftyChain; // Filtered chain for OI calculation
  List<OptionChainEntry>? _filteredSensexChain; // Filtered chain for OI calculation
  Timer? _niftyResubscribeTimer; // Debounce timer for re-subscriptions
  Timer? _sensexResubscribeTimer; // Debounce timer for re-subscriptions
  Timer? _niftyOiUpdateTimer; // Timer for throttled OI total recalculation (Nifty)
  Timer? _sensexOiUpdateTimer; // Timer for throttled OI total recalculation (Sensex)
  DateTime? _lastNiftyOiUpdate; // Last time Nifty OI totals were recalculated
  DateTime? _lastSensexOiUpdate; // Last time Sensex OI totals were recalculated
  Timer? _scripMasterCheckTimer; // Timer to periodically check for scrip master availability
  bool _niftyOiErrorShown = false; // Track if error notification was shown for Nifty
  bool _sensexOiErrorShown = false; // Track if error notification was shown for Sensex

  @override
  void initState() {
    super.initState();
    _marketDataService = MarketDataService();
    _initialize();
    _startScripMasterCheckTimer();
  }

  @override
  void dispose() {
    _quoteSubscription?.cancel();
    _sensexQuoteSubscription?.cancel();
    _cancelAllOptionSubscriptions();
    _niftyResubscribeTimer?.cancel();
    _sensexResubscribeTimer?.cancel();
    _niftyOiUpdateTimer?.cancel();
    _sensexOiUpdateTimer?.cancel();
    _scripMasterCheckTimer?.cancel();
    _pageController.dispose();
    _marketDataService.dispose();
    super.dispose();
  }

  void _cancelAllOptionSubscriptions() {
    for (final subscription in _niftyOptionSubscriptions.values) {
      subscription.cancel();
    }
    _niftyOptionSubscriptions.clear();
    for (final subscription in _sensexOptionSubscriptions.values) {
      subscription.cancel();
    }
    _sensexOptionSubscriptions.clear();
  }

  Future<void> _initialize() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isConnected = false;
    });

    Credentials? stored;
    try {
      stored = await _credentialsService.getCredentials();
    } catch (_) {
      stored = null;
    }
    if (!mounted) return;

    if (stored != null && stored.isValid) {
      _credentials = stored;
    } else {
      _credentials = null;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Please configure your credentials in Settings.';
      });
      return;
    }
    _startWebsocketStream();
    
    // Check if OI & Option Chain data is enabled
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (oiAndOptionChainEnabled) {
      // Start periodic OI recalculation timer (uses OI update interval from settings)
      _startPeriodicOiRecalculation();
      // Start OI subscriptions after a delay to ensure CMP is available
      // OI subscriptions need CMP to filter strikes correctly
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _startOiSubscriptions();
        }
      });
    } else {
      debugPrint('OI & Option Chain data is disabled in settings - skipping OI subscriptions');
    }
  }

  Future<void> _startOiSubscriptions() async {
    final credentials = _credentials;
    if (credentials == null) return;

    // Subscribe to Nifty options for OI
    _subscribeToIndexOptions(credentials, 'NIFTY', 'nse_fo', true);
    
    // Subscribe to Sensex options for OI
    _subscribeToIndexOptions(credentials, 'SENSEX', 'bse_fo', false);
  }

  Future<void> _subscribeToIndexOptions(
    Credentials credentials,
    String symbol,
    String segment,
    bool isNifty,
  ) async {
    // Check if OI & Option Chain data is enabled BEFORE doing any work
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (!oiAndOptionChainEnabled) {
      debugPrint('[$symbol] OI & Option Chain data is disabled - skipping subscription');
      return;
    }
    
    try {
      // Get current market price (CMP) for filtering
      double? cmp;
      if (isNifty && _latestQuote != null) {
        cmp = _latestQuote!.lastPrice;
      } else if (!isNifty && _latestSensexQuote != null) {
        cmp = _latestSensexQuote!.lastPrice;
      }
      
      // If CMP not available yet, wait a bit and retry
      if (cmp == null || cmp <= 0) {
        debugPrint('$symbol CMP not available yet, waiting...');
        // Wait 2 seconds and retry
        await Future.delayed(const Duration(seconds: 2));
        if (isNifty && _latestQuote != null) {
          cmp = _latestQuote!.lastPrice;
        } else if (!isNifty && _latestSensexQuote != null) {
          cmp = _latestSensexQuote!.lastPrice;
        }
      }
      
      if (cmp == null || cmp <= 0) {
        debugPrint('$symbol CMP still not available, skipping OI subscription');
        return;
      }

      // Load nearest expiry option chain - ALL strikes
      final optionChain = await _optionChainService.loadNearestExpiry(
        symbol: symbol,
        segment: segment,
      );

      if (optionChain.isEmpty) return;

      // For SENSEX: Filter strikes dynamically based on current CMP (CMP ± 15000)
      // This captures ITM, ATM, and near OTM strikes for live market data
      // The app automatically re-subscribes when CMP changes significantly (>50 points)
      // For NIFTY: Filter strikes (25 OTM + 67 ITM+ATM) for performance
      final filteredChain = isNifty 
          ? _filterStrikesOptimized(optionChain, cmp, otmStrikes: 25, itmAtmStrikes: 67)
          : _filterStrikesForSensex(optionChain, cmp); // Filter SENSEX strikes dynamically around current CMP
      
      // Store filtered chain for OI calculation
      if (isNifty) {
        _filteredNiftyChain = filteredChain;
      } else {
        _filteredSensexChain = filteredChain;
      }

      final subscriptions = isNifty ? _niftyOptionSubscriptions : _sensexOptionSubscriptions;
      final optionOIMap = isNifty ? _niftyOptionOI : _sensexOptionOI;

      debugPrint('$symbol CMP: ₹$cmp');
      if (isNifty) {
        debugPrint('Filtering strikes: 25 OTM + 67 ITM+ATM (optimized)');
      } else {
        debugPrint('Filtering SENSEX strikes: CMP ± 15000 (dynamic, adapts to current CMP)');
      }
      debugPrint('Subscribing to OI for ${filteredChain.length} strikes (${filteredChain.length * 2} options) for $symbol');

      // Collect all symbols for batch subscription (much more efficient than individual connections)
      final symbolsToSubscribe = <String>[];
      final tokenToSymbolMap = <String, String>{};
      final tokenToOptionTypeMap = <String, String>{}; // Track CE/PE for each token
      final validTokens = <String>{}; // Track all valid tokens from filtered chain
      
      for (final entry in filteredChain) {
        if (!mounted) break;

        // Add CE symbol
        if (entry.ce != null) {
          final token = entry.ce!.token;
          validTokens.add(token);
          if (!subscriptions.containsKey(token)) {
            final symbolStr = '$segment|$token';
            symbolsToSubscribe.add(symbolStr);
            tokenToSymbolMap[token] = symbolStr;
            tokenToOptionTypeMap[token] = 'CE';
          }
        }

        // Add PE symbol
        if (entry.pe != null) {
          final token = entry.pe!.token;
          validTokens.add(token);
          if (!subscriptions.containsKey(token)) {
            final symbolStr = '$segment|$token';
            symbolsToSubscribe.add(symbolStr);
            tokenToSymbolMap[token] = symbolStr;
            tokenToOptionTypeMap[token] = 'PE';
          }
        }
      }
      
      // Store valid tokens for validation during OI updates
      if (isNifty) {
        _niftyValidTokens = validTokens;
        _niftyTokenToOptionType = tokenToOptionTypeMap;
      } else {
        _sensexValidTokens = validTokens;
        _sensexTokenToOptionType = tokenToOptionTypeMap;
      }

      if (symbolsToSubscribe.isEmpty) {
        debugPrint('No new symbols to subscribe to for $symbol');
        return;
      }

      // Use batch subscription (single connection for all symbols)
      debugPrint('Batch subscribing to ${symbolsToSubscribe.length} symbols using single WebSocket connection');
      debugPrint('[$symbol] Subscribed tokens: ${tokenToSymbolMap.keys.take(10).join(", ")}${tokenToSymbolMap.length > 10 ? "..." : ""} (total: ${tokenToSymbolMap.length})');
      
      // Track which tokens we've received data for
      final receivedTokens = <String>{};
      
      // Use a mutable reference so we can cancel from within the callback
      StreamSubscription<MarketQuote>? batchSubscriptionRef;
      
      final batchSubscription = _marketDataService
          .batchSymbolWebsocketStream(credentials, symbolsToSubscribe)
          .listen(
            (quote) async {
              // Check if OI & Option Chain data is still enabled (user might have disabled it)
              final prefs = await SharedPreferences.getInstance();
              final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
              
              if (!oiAndOptionChainEnabled) {
                // OI is disabled - cancel this subscription and stop processing
                batchSubscriptionRef?.cancel();
                debugPrint('[$symbol] OI & Option Chain disabled - cancelling subscription');
                return;
              }
              
              // Route quote to correct token
              // Quote token format from WebSocket: "sf|segment|token" (e.g., "sf|nse_fo|52829")
              // Our subscription format: "segment|token" (e.g., "nse_fo|52829")
              final quoteToken = quote.token ?? '';
              
              // Debug: Log ALL received quotes (not just ones with OI) to see what's coming
              debugPrint('[$symbol] Received quote: token="$quoteToken", OI=${quote.openInterest ?? "null"}, LTP=${quote.lastPrice}');
              
              // Try to match with our token map
              // Improved matching: extract numeric token from quote and match exactly
              bool matched = false;
              String? matchedToken;
              
              // Extract numeric token from quote token (handles formats like "sf|nse_fo|52829", "if|bse_fo|12345", etc.)
              String? extractNumericToken(String tokenStr) {
                // Try to extract numeric token from various formats
                // Format examples: "sf|nse_fo|52829", "if|bse_fo|12345", "52829", "nse_fo|52829"
                final parts = tokenStr.split('|');
                if (parts.length >= 2) {
                  // Format: "prefix|segment|token" or "segment|token"
                  final lastPart = parts.last;
                  if (RegExp(r'^\d+$').hasMatch(lastPart)) {
                    return lastPart;
                  }
                } else if (RegExp(r'^\d+$').hasMatch(tokenStr)) {
                  // Direct numeric token
                  return tokenStr;
                }
                return null;
              }
              
              final extractedToken = extractNumericToken(quoteToken);
              
              if (extractedToken != null && tokenToSymbolMap.containsKey(extractedToken)) {
                // Exact token match - most reliable
                matchedToken = extractedToken;
                matched = true;
              } else {
                // Fallback: try matching by symbol string
                for (final entry in tokenToSymbolMap.entries) {
                  final symbolStr = entry.value; // e.g., "nse_fo|52829"
                  final token = entry.key; // e.g., "52829"
                  
                  // Normalize quote token by removing "sf|" or "if|" prefix
                  final normalizedQuoteToken = quoteToken
                      .replaceFirst(RegExp(r'^(sf|if)\|'), '')
                      .toLowerCase();
                  final normalizedSymbolStr = symbolStr.toLowerCase();
                  
                  // Check if quote matches this symbol (exact match preferred)
                  if (normalizedQuoteToken == normalizedSymbolStr ||
                      quoteToken == symbolStr) {
                    matched = true;
                    matchedToken = token;
                    break;
                  }
                }
              }
              
              if (matched && matchedToken != null) {
                // Validate token is in our filtered chain before processing
                final validTokens = isNifty ? _niftyValidTokens : _sensexValidTokens;
                if (validTokens.contains(matchedToken)) {
                  receivedTokens.add(matchedToken); // Track that we received data for this token
                  debugPrint('[$symbol] ✓ Matched: quoteToken="$quoteToken" -> subscription="${tokenToSymbolMap[matchedToken]}" (token=$matchedToken), OI=${quote.openInterest ?? "null"}');
                  _handleOptionOIUpdate(matchedToken, quote.openInterest, isNifty);
                } else {
                  debugPrint('[$symbol] ⚠️ Matched token $matchedToken but not in filtered chain, ignoring');
                }
              }
              
              if (!matched) {
                // Log unmatched quotes - they might be for different symbols or formats
                if (quoteToken.contains('|')) {
                  debugPrint('[$symbol] ✗ Unmatched quote: token="$quoteToken", OI=${quote.openInterest ?? "null"} (sample subscriptions: ${tokenToSymbolMap.values.take(3).join(", ")}...)');
                }
              }
            },
            onError: (error) {
              debugPrint('Batch subscription error for $symbol: $error');
            },
          );
      
      // Store the subscription reference for cancellation from within callback
      batchSubscriptionRef = batchSubscription;
      
      // Store subscription (using first token as key for tracking)
      if (tokenToSymbolMap.isNotEmpty) {
        final firstToken = tokenToSymbolMap.keys.first;
        subscriptions[firstToken] = batchSubscription;
      }

      debugPrint('Batch subscribed to ${symbolsToSubscribe.length} options for $symbol OI (using single WebSocket connection)');
      debugPrint('Filtered strikes: ${filteredChain.length} (${filteredChain.length * 2} total options: ${filteredChain.where((e) => e.ce != null).length} CE + ${filteredChain.where((e) => e.pe != null).length} PE)');
      
      // Periodic checks for missing data (at 5s, 10s, 15s) to track data arrival
      // This helps identify if critical data is truly missing or just delayed
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        final allSubscribedTokens = tokenToSymbolMap.keys.toSet();
        final missingTokens = allSubscribedTokens.difference(receivedTokens);
        if (missingTokens.isNotEmpty) {
          // Categorize missing tokens
          if (cmp != null) {
            final missingItmAtmTokens = <String>[];
            final missingNearOtmTokens = <String>[];
            final missingFarOtmTokens = <String>[];
            for (final token in missingTokens) {
              for (final entry in filteredChain) {
                if (entry.ce?.token == token || entry.pe?.token == token) {
                  final strike = entry.strike;
                  final distance = (strike - cmp).abs();
                  if (distance <= 500) {
                    missingItmAtmTokens.add(token);
                  } else if (distance <= 1000) {
                    missingNearOtmTokens.add(token);
                  } else {
                    missingFarOtmTokens.add(token);
                  }
                  break;
                }
              }
            }
            // Only warn about critical/important missing data at 5s
            if (missingItmAtmTokens.isNotEmpty || missingNearOtmTokens.isNotEmpty) {
              debugPrint('[$symbol] ⚠️ After 5s: ${missingItmAtmTokens.length} ITM/ATM + ${missingNearOtmTokens.length} Near OTM tokens still pending (${missingFarOtmTokens.length} Far OTM pending)');
            }
          }
        } else {
          debugPrint('[$symbol] ✓ All ${allSubscribedTokens.length} subscribed tokens received data within 5 seconds');
        }
      });
      
      // Final check at 15 seconds - this is more reliable
      Future.delayed(const Duration(seconds: 15), () {
        if (!mounted) return;
        final allSubscribedTokens = tokenToSymbolMap.keys.toSet();
        final missingTokens = allSubscribedTokens.difference(receivedTokens);
        if (missingTokens.isNotEmpty) {
          // Use actual OI map to verify (more reliable than receivedTokens)
          final actuallyMissing = <String>[];
          for (final token in missingTokens) {
            final oi = isNifty ? _niftyOptionOI[token] : _sensexOptionOI[token];
            if (oi == null) {
              actuallyMissing.add(token);
            }
          }
          
          if (actuallyMissing.isNotEmpty) {
            debugPrint('[$symbol] ⚠️ After 15s: ${actuallyMissing.length} tokens still missing data:');
            // Categorize
            if (cmp != null) {
              final missingItmAtmTokens = <String>[];
              final missingNearOtmTokens = <String>[];
              final missingFarOtmTokens = <String>[];
              for (final token in actuallyMissing) {
                for (final entry in filteredChain) {
                  if (entry.ce?.token == token || entry.pe?.token == token) {
                    final strike = entry.strike;
                    final distance = (strike - cmp).abs();
                    if (distance <= 500) {
                      missingItmAtmTokens.add('$token (strike=$strike, dist=${distance.toStringAsFixed(0)})');
                    } else if (distance <= 1000) {
                      missingNearOtmTokens.add('$token (strike=$strike, dist=${distance.toStringAsFixed(0)})');
                    } else {
                      missingFarOtmTokens.add('$token (strike=$strike, dist=${distance.toStringAsFixed(0)})');
                    }
                    break;
                  }
                }
              }
              if (missingItmAtmTokens.isNotEmpty) {
                debugPrint('  ⚠️ CRITICAL: ${missingItmAtmTokens.length} ITM/ATM tokens: ${missingItmAtmTokens.take(10).join(", ")}${missingItmAtmTokens.length > 10 ? "..." : ""}');
              }
              if (missingNearOtmTokens.isNotEmpty) {
                debugPrint('  ⚠️ IMPORTANT: ${missingNearOtmTokens.length} Near OTM tokens: ${missingNearOtmTokens.take(10).join(", ")}${missingNearOtmTokens.length > 10 ? "..." : ""}');
              }
              if (missingFarOtmTokens.isNotEmpty) {
                debugPrint('  ℹ️ Less Critical: ${missingFarOtmTokens.length} Far OTM tokens: ${missingFarOtmTokens.take(10).join(", ")}${missingFarOtmTokens.length > 10 ? "..." : ""}');
              }
            }
          } else {
            debugPrint('[$symbol] ✓ All tokens received data (verified via OI map)');
          }
        } else {
          debugPrint('[$symbol] ✓ All ${allSubscribedTokens.length} subscribed tokens received data');
        }
      });

      // Clear error state on successful subscription
      if (isNifty) {
        _niftyOiErrorShown = false;
      } else {
        _sensexOiErrorShown = false;
      }
      
      // Clear any existing error notification
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }

      // Note: OI data will arrive via WebSocket and trigger _updateTotalOI automatically
      // We rely on WebSocket snapshots for all OI data to avoid REST API 503 errors
    } catch (e) {
      debugPrint('Error subscribing to $symbol OI: $e');
      
      // Track that error was shown
      if (isNifty) {
        _niftyOiErrorShown = true;
      } else {
        _sensexOiErrorShown = true;
      }
      
      // Show user-visible error message
      if (mounted) {
        final errorMsg = e.toString();
        final cleanMsg = errorMsg.contains('Exception: ') 
            ? errorMsg.replaceFirst('Exception: ', '')
            : errorMsg;
        
        // Extract the key message (first line)
        final lines = cleanMsg.split('\n');
        final shortMsg = lines.isNotEmpty ? lines.first : cleanMsg;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$symbol OI: $shortMsg'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 10), // Longer duration
            action: SnackBarAction(
              label: 'Settings',
              textColor: Colors.white,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
              },
            ),
          ),
        );
      }
    }
  }

  /// Filter strikes with optimized strategy: 25 OTM + 67 ITM+ATM
  /// This reduces load while keeping meaningful OI data (far OTM has low OI impact)
  /// 
  /// Strategy:
  /// - 67 ITM+ATM strikes around CMP (covers most active trading)
  /// - 25 OTM strikes above CMP (for CE OTM)
  /// - 25 OTM strikes below CMP (for PE OTM)
  /// Total: ~92 strikes (vs 80 with old method, but more focused on high-OI areas)
  List<OptionChainEntry> _filterStrikesOptimized(
    List<OptionChainEntry> optionChain,
    double cmp, {
    int otmStrikes = 25,
    int itmAtmStrikes = 67,
  }) {
    // Extract all unique strike prices
    final strikeMap = <double, OptionChainEntry>{};
    for (final entry in optionChain) {
      final strike = entry.strike;
      strikeMap[strike] = entry;
    }

    if (strikeMap.isEmpty) return [];

    // Sort strikes
    final sortedStrikes = strikeMap.keys.toList()..sort();

    // Find ATM (closest to CMP)
    double? atmStrike;
    double minDistance = double.infinity;
    for (final strike in sortedStrikes) {
      final distance = (strike - cmp).abs();
      if (distance < minDistance) {
        minDistance = distance;
        atmStrike = strike;
      }
    }

    if (atmStrike == null) return [];

    // Find ATM index
    final atmIdx = sortedStrikes.indexOf(atmStrike);

    // Calculate ITM+ATM range: strikes around ATM (covers both CE and PE ITM)
    // For CE: ITM = strikes below CMP, OTM = strikes above CMP
    // For PE: ITM = strikes above CMP, OTM = strikes below CMP
    // So ITM+ATM range should cover strikes around CMP (both sides)
    final itmAtmHalf = (itmAtmStrikes / 2).ceil(); // Split ITM+ATM around ATM
    final itmAtmStartIdx = (atmIdx - itmAtmHalf).clamp(0, sortedStrikes.length);
    final itmAtmEndIdx = (atmIdx + itmAtmHalf + 1).clamp(0, sortedStrikes.length);

    // OTM strikes above CMP (for CE OTM)
    final otmAboveEndIdx = sortedStrikes.length;
    final otmAboveStartIdx = (itmAtmEndIdx).clamp(0, sortedStrikes.length);
    final otmAboveCount = (otmAboveEndIdx - otmAboveStartIdx).clamp(0, otmStrikes);

    // OTM strikes below CMP (for PE OTM)
    final otmBelowStartIdx = 0;
    final otmBelowEndIdx = (itmAtmStartIdx).clamp(0, sortedStrikes.length);
    final otmBelowCount = (otmBelowEndIdx - otmBelowStartIdx).clamp(0, otmStrikes);

    // Collect filtered entries
    final filteredEntries = <OptionChainEntry>{};
    
    // Add ITM+ATM strikes (around CMP)
    for (int i = itmAtmStartIdx; i < itmAtmEndIdx; i++) {
      final strike = sortedStrikes[i];
      if (strikeMap.containsKey(strike)) {
        filteredEntries.add(strikeMap[strike]!);
      }
    }
    
    // Add OTM strikes above CMP (CE OTM) - take last N strikes
    if (otmAboveCount > 0) {
      final otmAboveActualStart = (otmAboveEndIdx - otmAboveCount).clamp(otmAboveStartIdx, sortedStrikes.length);
      for (int i = otmAboveActualStart; i < otmAboveEndIdx; i++) {
        final strike = sortedStrikes[i];
        if (strikeMap.containsKey(strike) && !filteredEntries.contains(strikeMap[strike])) {
          filteredEntries.add(strikeMap[strike]!);
        }
      }
    }
    
    // Add OTM strikes below CMP (PE OTM) - take first N strikes
    if (otmBelowCount > 0) {
      final otmBelowActualEnd = (otmBelowStartIdx + otmBelowCount).clamp(0, otmBelowEndIdx);
      for (int i = otmBelowStartIdx; i < otmBelowActualEnd; i++) {
        final strike = sortedStrikes[i];
        if (strikeMap.containsKey(strike) && !filteredEntries.contains(strikeMap[strike])) {
          filteredEntries.add(strikeMap[strike]!);
        }
      }
    }

    // Convert to list and sort by strike price
    final result = filteredEntries.toList();
    result.sort((a, b) {
      final strikeA = a.strike;
      final strikeB = b.strike;
      return strikeA.compareTo(strikeB);
    });

    return result;
  }

  /// Filter SENSEX strikes dynamically based on current CMP
  /// For live market data, we filter strikes around current CMP to capture active options
  /// SENSEX has larger strike intervals, so we use a wider range than NIFTY
  /// The app automatically re-subscribes when CMP changes significantly (>50 points)
  List<OptionChainEntry> _filterStrikesForSensex(
    List<OptionChainEntry> optionChain,
    double cmp,
  ) {
    // Extract all unique strike prices
    final strikeMap = <double, OptionChainEntry>{};
    for (final entry in optionChain) {
      final strike = entry.strike;
      strikeMap[strike] = entry;
    }

    if (strikeMap.isEmpty) return [];

    // Filter strikes within range around CMP
    // SENSEX typically has strikes in 100-point intervals
    // Use a dynamic range: CMP ± 15000 to capture ITM, ATM, and near OTM strikes
    // This ensures we get all active options while filtering out far OTM strikes
    // The range adapts automatically when CMP changes (app re-subscribes when CMP changes >50 points)
    const maxDistance = 15000.0;
    
    final filteredEntries = <OptionChainEntry>[];
    for (final entry in optionChain) {
      final distance = (entry.strike - cmp).abs();
      if (distance <= maxDistance) {
        filteredEntries.add(entry);
      }
    }

    // Sort by strike price
    filteredEntries.sort((a, b) => a.strike.compareTo(b.strike));

    return filteredEntries;
  }

  /// Handle OI updates from WebSocket (continuously received)
  /// 
  /// IMPORTANT: We save ALL OI values we receive, but only calculate totals
  /// at the OI update interval (throttled). This means:
  /// - OI is fetched continuously via WebSocket (real-time)
  /// - All OI values are saved in the map (preserved)
  /// - Totals are only recalculated when user wants (OI update interval from settings)
  /// - When OI is blank/NA, we preserve the last known value from the map
  void _handleOptionOIUpdate(String token, double? oi, bool isNifty) {
    if (!mounted) return;

    final optionOIMap = isNifty ? _niftyOptionOI : _sensexOptionOI;
    final validTokens = isNifty ? _niftyValidTokens : _sensexValidTokens;
    final symbol = isNifty ? 'NIFTY' : 'SENSEX';
    
    // CRITICAL: Only process OI updates for tokens that are in our filtered chain
    // This prevents including OI from tokens we didn't subscribe to
    if (!validTokens.contains(token)) {
      debugPrint('[$symbol] ⚠️ Ignoring OI update for token $token (not in filtered chain)');
      return;
    }
    
    // Handle OI updates:
    // 1. If OI is null/NA - preserve last known value (don't remove)
    //    (null might mean "no update" or "not available yet", not "invalid")
    // 2. If OI is valid (> 0 and < 1 billion) - update the value in map
    // 3. If OI is explicitly invalid (0, negative, or > 1 billion) - remove it
    
    if (oi == null) {
      // Null/NA OI - preserve last known value if exists
      // Don't remove - the quote might just not have OI data yet
      if (!optionOIMap.containsKey(token)) {
        debugPrint('[$symbol] OI is null/NA for token $token (no previous value to preserve)');
      } else {
        debugPrint('[$symbol] OI is null/NA for token $token, preserving last known value: ${optionOIMap[token]}');
      }
      // Keep existing value in map if it exists
      return; // Don't trigger recalculation if no change
    }
    
    // OI is not null - check if it's valid
    if (oi > 0 && oi < 1000000000) {
      // Valid OI value - update it
      final previousOi = optionOIMap[token];
      optionOIMap[token] = oi;
      if (previousOi != null && previousOi != oi) {
        debugPrint('[$symbol] OI updated for token $token: $previousOi -> $oi');
      }
    } else {
      // Explicitly invalid OI (0, negative, or sentinel value like 2147483648.0)
      // Remove it so totals don't include invalid data
      if (oi <= 0) {
        debugPrint('[$symbol] Removing invalid OI for token $token: $oi (zero or negative)');
      } else if (oi >= 1000000000) {
        debugPrint('[$symbol] Removing invalid OI for token $token: $oi (sentinel/error value)');
      }
      optionOIMap.remove(token);
    }

    // IMPORTANT: We save the OI value immediately, but only trigger totals
    // recalculation at the OI update interval (throttled). This means:
    // - OI values are continuously fetched and saved (real-time)
    // - Totals are only recalculated when user wants (OI update interval)
    // - All OI values are preserved in the map for later use
    _scheduleThrottledOiUpdate(isNifty);
  }

  /// Schedule a throttled OI total recalculation using the interval from settings
  /// This ensures we don't recalculate on every single quote update (which can be very frequent)
  /// Uses debouncing: if quotes arrive quickly, we only recalculate once per interval
  void _scheduleThrottledOiUpdate(bool isNifty) async {
    if (!mounted) return;

    // Load OI update interval from settings
    final prefs = await SharedPreferences.getInstance();
    final oiUpdateIntervalSeconds = prefs.getDouble('oi_update_interval_seconds') ?? 30.0;
    
    final updateTimer = isNifty ? _niftyOiUpdateTimer : _sensexOiUpdateTimer;
    final lastUpdate = isNifty ? _lastNiftyOiUpdate : _lastSensexOiUpdate;
    
    // Cancel existing timer (debounce - reset timer on each quote)
    updateTimer?.cancel();
    
    // Check if enough time has passed since last update
    final now = DateTime.now();
    bool shouldUpdateNow = false;
    
    if (lastUpdate == null) {
      // First update - do it immediately
      shouldUpdateNow = true;
    } else {
      final timeSinceLastUpdate = now.difference(lastUpdate).inMilliseconds;
      final intervalMs = (oiUpdateIntervalSeconds * 1000).round();
      
      if (timeSinceLastUpdate >= intervalMs) {
        // Enough time has passed, update immediately
        shouldUpdateNow = true;
      } else {
        // Schedule update for remaining time (debounce)
        final remainingMs = intervalMs - timeSinceLastUpdate;
        if (isNifty) {
          _niftyOiUpdateTimer = Timer(Duration(milliseconds: remainingMs), () {
            if (mounted) {
              _updateTotalOI(isNifty);
              _lastNiftyOiUpdate = DateTime.now();
            }
          });
        } else {
          _sensexOiUpdateTimer = Timer(Duration(milliseconds: remainingMs), () {
            if (mounted) {
              _updateTotalOI(isNifty);
              _lastSensexOiUpdate = DateTime.now();
            }
          });
        }
      }
    }
    
    if (shouldUpdateNow) {
      _updateTotalOI(isNifty);
      if (isNifty) {
        _lastNiftyOiUpdate = now;
      } else {
        _lastSensexOiUpdate = now;
      }
    }
  }

  void _updateTotalOI(bool isNifty) {
    if (!mounted) return;

    final optionOIMap = isNifty ? _niftyOptionOI : _sensexOptionOI;
    
    // Calculate totals from current OI map
    double totalCallOI = 0;
    double totalPutOI = 0;

    // We need to know which tokens are CE vs PE, so we need the option chain
    // For now, let's store this info when we subscribe
    // But a simpler approach: just sum all OI values we have
    // The issue is we don't know which is CE vs PE from just the token
    
    // Better approach: track CE and PE separately when subscribing
    // For now, let's use a simpler method - sum all and divide by 2 as approximation
    // Or better: store CE/PE info when subscribing
    
    // Actually, let's store the option type when we subscribe
    final subscriptions = isNifty ? _niftyOptionSubscriptions : _sensexOptionSubscriptions;
    
    // We need to match tokens to their option type (CE/PE)
    // Let's load the chain and match tokens
    _loadChainAndCalculateOI(isNifty, optionOIMap, subscriptions);
  }

  Future<void> _loadChainAndCalculateOI(
    bool isNifty,
    Map<String, double> optionOIMap,
    Map<String, StreamSubscription<MarketQuote>> subscriptions,
  ) async {
    try {
      final symbol = isNifty ? 'NIFTY' : 'SENSEX';
      
      // Use filtered chain (40 above + 40 below CMP) - same as Python script
      final filteredChain = isNifty ? _filteredNiftyChain : _filteredSensexChain;
      
      if (filteredChain == null || filteredChain.isEmpty) {
        debugPrint('$symbol: No filtered chain available yet');
        return;
      }

      if (!mounted) return;

      double totalCallOI = 0;
      double totalPutOI = 0;
      int callCount = 0;
      int putCount = 0;
      int missingCallCount = 0;
      int missingPutCount = 0;
      
      // Track missing strikes by category for analysis
      // Categories: ITM/ATM (critical), Near OTM (important), Far OTM (less important)
      final missingItmAtmStrikes = <double>[];
      final missingNearOtmStrikes = <double>[];
      final missingFarOtmStrikes = <double>[];
      final missingItmAtmCallTokens = <String>[];
      final missingItmAtmPutTokens = <String>[];
      final missingNearOtmCallTokens = <String>[];
      final missingNearOtmPutTokens = <String>[];
      final missingFarOtmCallTokens = <String>[];
      final missingFarOtmPutTokens = <String>[];
      
      // Get CMP for strike categorization
      double? cmp;
      if (isNifty && _latestQuote != null) {
        cmp = _latestQuote!.lastPrice;
      } else if (!isNifty && _latestSensexQuote != null) {
        cmp = _latestSensexQuote!.lastPrice;
      }

      // Calculate totals from FILTERED options only (matching Python script)
      // This ensures we get the same OI totals as the CSV file
      // Note: Missing/NA OI values are excluded from totals (not counted as 0)
      for (final entry in filteredChain) {
        final strike = entry.strike;
        double? distanceFromCmp;
        if (cmp != null) {
          distanceFromCmp = (strike - cmp).abs();
        }
        final isItmAtm = distanceFromCmp != null && distanceFromCmp <= 500; // Within 500 points = ITM/ATM (CRITICAL)
        final isNearOtm = distanceFromCmp != null && distanceFromCmp > 500 && distanceFromCmp <= 1000; // 500-1000 points = Near OTM (IMPORTANT)
        final isFarOtm = distanceFromCmp != null && distanceFromCmp > 1000; // Beyond 1000 points = Far OTM (less important)
        
        // Sum CE OI (use LAST KNOWN/UPDATED value from map if available)
        // The map contains the most recent OI value received from WebSocket for each token
        // If a token hasn't received data yet, it won't be in the map (null check below)
        // If a token received null/NA OI, the last known value is preserved in the map
        if (entry.ce != null) {
          final token = entry.ce!.token;
          // CRITICAL: Only use OI from tokens in our filtered chain
          // This ensures we don't include OI from tokens we didn't subscribe to
          final validTokens = isNifty ? _niftyValidTokens : _sensexValidTokens;
          if (!validTokens.contains(token)) {
            debugPrint('[$symbol] ⚠️ Skipping CE token $token (not in filtered chain)');
            missingCallCount++;
            // Skip this CE but continue processing PE for this strike
          } else {
            final oi = optionOIMap[token]; // Get last known/updated OI value
            // Only include valid OI values in totals
            // Missing/NA OI (null) is excluded - this is correct behavior
            // Invalid OI (0, negative, or sentinel) is also excluded
            if (oi != null && oi > 0 && oi < 1000000000) {
              totalCallOI += oi; // Using last known/updated OI value
              callCount++;
            } else {
              // OI is missing (null/NA) or invalid - don't include in totals
              missingCallCount++;
              // Track missing strikes by category
              if (isItmAtm) {
                if (!missingItmAtmStrikes.contains(strike)) {
                  missingItmAtmStrikes.add(strike);
                }
                missingItmAtmCallTokens.add('${entry.ce!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              } else if (isNearOtm) {
                if (!missingNearOtmStrikes.contains(strike)) {
                  missingNearOtmStrikes.add(strike);
                }
                missingNearOtmCallTokens.add('${entry.ce!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              } else if (isFarOtm) {
                if (!missingFarOtmStrikes.contains(strike)) {
                  missingFarOtmStrikes.add(strike);
                }
                missingFarOtmCallTokens.add('${entry.ce!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              }
            }
          }
        }
        // Sum PE OI (use LAST KNOWN/UPDATED value from map if available)
        // The map contains the most recent OI value received from WebSocket for each token
        // If a token hasn't received data yet, it won't be in the map (null check below)
        // If a token received null/NA OI, the last known value is preserved in the map
        if (entry.pe != null) {
          final token = entry.pe!.token;
          // CRITICAL: Only use OI from tokens in our filtered chain
          // This ensures we don't include OI from tokens we didn't subscribe to
          final validTokens = isNifty ? _niftyValidTokens : _sensexValidTokens;
          if (!validTokens.contains(token)) {
            debugPrint('[$symbol] ⚠️ Skipping PE token $token (not in filtered chain)');
            missingPutCount++;
            // Skip this PE
          } else {
            final oi = optionOIMap[token]; // Get last known/updated OI value
            // Only include valid OI values in totals
            // Missing/NA OI (null) is excluded - this is correct behavior
            if (oi != null && oi > 0 && oi < 1000000000) {
              totalPutOI += oi; // Using last known/updated OI value
              putCount++;
            } else {
              // OI is missing (null/NA) or invalid - don't include in totals
              missingPutCount++;
              // Track missing strikes by category
              if (isItmAtm) {
                if (!missingItmAtmStrikes.contains(strike)) {
                  missingItmAtmStrikes.add(strike);
                }
                missingItmAtmPutTokens.add('${entry.pe!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              } else if (isNearOtm) {
                if (!missingNearOtmStrikes.contains(strike)) {
                  missingNearOtmStrikes.add(strike);
                }
                missingNearOtmPutTokens.add('${entry.pe!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              } else if (isFarOtm) {
                if (!missingFarOtmStrikes.contains(strike)) {
                  missingFarOtmStrikes.add(strike);
                }
                missingFarOtmPutTokens.add('${entry.pe!.token} (strike=$strike, dist=${distanceFromCmp?.toStringAsFixed(0) ?? "?"})');
              }
            }
          }
        }
      }
      
      // Log detailed analysis of missing data
      debugPrint('$symbol MISSING OI ANALYSIS:');
      debugPrint('  ⚠️ CRITICAL - ITM/ATM missing: ${missingItmAtmStrikes.length} strikes (${missingItmAtmCallTokens.length} CE + ${missingItmAtmPutTokens.length} PE)');
      if (missingItmAtmStrikes.isNotEmpty) {
        missingItmAtmStrikes.sort();
        debugPrint('    ITM/ATM missing strikes: ${missingItmAtmStrikes.take(10).join(", ")}${missingItmAtmStrikes.length > 10 ? "..." : ""}');
        if (missingItmAtmCallTokens.isNotEmpty) {
          debugPrint('    ITM/ATM missing CE tokens (first 5): ${missingItmAtmCallTokens.take(5).join(", ")}');
        }
        if (missingItmAtmPutTokens.isNotEmpty) {
          debugPrint('    ITM/ATM missing PE tokens (first 5): ${missingItmAtmPutTokens.take(5).join(", ")}');
        }
      }
      debugPrint('  ⚠️ IMPORTANT - Near OTM missing: ${missingNearOtmStrikes.length} strikes (${missingNearOtmCallTokens.length} CE + ${missingNearOtmPutTokens.length} PE)');
      if (missingNearOtmStrikes.isNotEmpty) {
        missingNearOtmStrikes.sort();
        debugPrint('    Near OTM missing strikes: ${missingNearOtmStrikes.take(10).join(", ")}${missingNearOtmStrikes.length > 10 ? "..." : ""}');
        if (missingNearOtmCallTokens.isNotEmpty) {
          debugPrint('    Near OTM missing CE tokens (first 5): ${missingNearOtmCallTokens.take(5).join(", ")}');
        }
        if (missingNearOtmPutTokens.isNotEmpty) {
          debugPrint('    Near OTM missing PE tokens (first 5): ${missingNearOtmPutTokens.take(5).join(", ")}');
        }
      }
      debugPrint('  ℹ️ Less Critical - Far OTM missing: ${missingFarOtmStrikes.length} strikes (${missingFarOtmCallTokens.length} CE + ${missingFarOtmPutTokens.length} PE)');
      if (missingFarOtmStrikes.isNotEmpty && missingFarOtmStrikes.length <= 20) {
        missingFarOtmStrikes.sort();
        debugPrint('    Far OTM missing strikes: ${missingFarOtmStrikes.join(", ")}');
      }

      // Calculate completion percentage
      final totalExpected = filteredChain.length * 2; // CE + PE for each strike
      final totalReceived = callCount + putCount;
      final completionPercent = totalExpected > 0 ? (totalReceived / totalExpected * 100) : 0.0;
      
      final filterDesc = isNifty ? 'filtered: 25 OTM + 67 ITM+ATM' : 'filtered: CMP ± 15000 (dynamic)';
      debugPrint('$symbol OI totals ($filterDesc): Call=${totalCallOI.toStringAsFixed(0)} ($callCount options, $missingCallCount missing), Put=${totalPutOI.toStringAsFixed(0)} ($putCount options, $missingPutCount missing)');
      debugPrint('$symbol OI map size: ${optionOIMap.length} tokens with OI data');
      debugPrint('$symbol OI completion: $totalReceived/$totalExpected (${completionPercent.toStringAsFixed(1)}%)');

      if (mounted) {
        setState(() {
          if (isNifty) {
            // Only show OI if we have at least 50% of data (to avoid showing partial/incomplete data)
            if (completionPercent >= 50.0) {
              _niftyCallOI = totalCallOI > 0 ? totalCallOI : null;
              _niftyPutOI = totalPutOI > 0 ? totalPutOI : null;
            } else {
              // Data is incomplete - set to null to avoid showing misleading partial totals
              _niftyCallOI = null;
              _niftyPutOI = null;
            }
            debugPrint('NIFTY OI updated: Call=${_niftyCallOI?.toStringAsFixed(0) ?? "null"}, Put=${_niftyPutOI?.toStringAsFixed(0) ?? "null"} (${completionPercent.toStringAsFixed(1)}% complete)');
          } else {
            // Only show OI if we have at least 50% of data
            // For SENSEX: Apply multiplier to match CSV summary format
            // CSV summary shows values that are half of calculated totals (likely due to lot size/multiplier)
            // We'll use the raw totals for now, but this can be adjusted if needed
            if (completionPercent >= 50.0) {
              _sensexCallOI = totalCallOI > 0 ? totalCallOI : null;
              _sensexPutOI = totalPutOI > 0 ? totalPutOI : null;
            } else {
              // Data is incomplete - set to null
              _sensexCallOI = null;
              _sensexPutOI = null;
            }
            debugPrint('SENSEX OI updated: Call=${_sensexCallOI?.toStringAsFixed(0) ?? "null"}, Put=${_sensexPutOI?.toStringAsFixed(0) ?? "null"} (${completionPercent.toStringAsFixed(1)}% complete)');
            debugPrint('SENSEX OI calculation: Raw totals from ${callCount} CE + ${putCount} PE options');
          }
        });
      }
    } catch (e) {
      debugPrint('Error calculating OI totals: $e');
    }
  }


  void _startWebsocketStream() {
    final credentials = _credentials;
    if (credentials == null) {
      return;
    }
    
    // Check if WebSocket is enabled
    if (MarketDataService.disableWebSocket) {
      debugPrint('WebSocket is disabled - skipping stream initialization');
      setState(() {
        _isLoading = false;
        _errorMessage = 'WebSocket is disabled in Settings';
        _isConnected = false;
        _isSensexConnected = false;
      });
      return;
    }

    // Start Nifty stream
    _quoteSubscription?.cancel();
    _quoteSubscription = _marketDataService
        .niftyWebsocketStream(credentials)
        .listen(
          _handleQuoteUpdate,
          onError: (error) {
            if (!mounted) return;
            setState(() {
              _isConnected = false;
              _isLoading = false;
              _errorMessage =
                  'Live feed unavailable. ${_cleanErrorMessage(error.toString())}';
            });
          },
        );

    // Start Sensex stream
    _sensexQuoteSubscription?.cancel();
    _sensexQuoteSubscription = _marketDataService
        .symbolWebsocketStream(credentials, 'bse_cm|SENSEX')
        .listen(
          _handleSensexQuoteUpdate,
          onError: (error) {
            if (!mounted) return;
            setState(() {
              _isSensexConnected = false;
            });
          },
        );

    setState(() {
      _isLoading = false;
      _errorMessage = null;
    });
  }

  /// Start periodic OI recalculation timer (safety net)
  /// Ensures OI totals are recalculated at the specified interval from settings
  /// even if no new quotes arrive (acts as a backup to throttled updates)
  /// Note: The main mechanism is throttled updates when quotes arrive
  void _startPeriodicOiRecalculation() async {
    final prefs = await SharedPreferences.getInstance();
    final oiUpdateIntervalSeconds = prefs.getDouble('oi_update_interval_seconds') ?? 30.0;
    
    debugPrint('OI recalculation: Using interval from settings: ${oiUpdateIntervalSeconds}s');
    debugPrint('OI recalculation: Totals will update every ${oiUpdateIntervalSeconds}s (throttled when quotes arrive)');
    
    // Note: We don't create periodic timers here because throttled updates handle it
    // This function is kept for future use if we need a safety net timer
  }

  /// Start periodic timer to check if scrip master files are available and retry subscription
  void _startScripMasterCheckTimer() {
    // Check every 10 seconds if scrip master is available
    _scripMasterCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final credentials = _credentials;
      if (credentials == null || !credentials.isValid) return;
      
      // Check if Nifty scrip master is available and retry if needed
      if (_niftyOiErrorShown) {
        try {
          final state = await _scripMasterService.describeLocal();
          final nseFoStatus = state.segments.firstWhere(
            (s) => s.segmentCode == 'nse_fo',
            orElse: () => state.segments.first,
          );
          
          if (nseFoStatus.state != ScripMasterSegmentState.missing) {
            debugPrint('NSE F&O scrip master now available, retrying Nifty OI subscription...');
            _niftyOiErrorShown = false;
            // Clear any existing error notification
            if (mounted) {
              ScaffoldMessenger.of(context).clearSnackBars();
            }
            // Retry subscription
            _subscribeToIndexOptions(credentials, 'NIFTY', 'nse_fo', true);
          }
        } catch (e) {
          debugPrint('Error checking NSE F&O scrip master: $e');
        }
      }
      
      // Check if Sensex scrip master is available and retry if needed
      if (_sensexOiErrorShown) {
        try {
          final state = await _scripMasterService.describeLocal();
          final bseFoStatus = state.segments.firstWhere(
            (s) => s.segmentCode == 'bse_fo',
            orElse: () => state.segments.first,
          );
          
          if (bseFoStatus.state != ScripMasterSegmentState.missing) {
            debugPrint('BSE F&O scrip master now available, retrying Sensex OI subscription...');
            _sensexOiErrorShown = false;
            // Clear any existing error notification
            if (mounted) {
              ScaffoldMessenger.of(context).clearSnackBars();
            }
            // Retry subscription
            _subscribeToIndexOptions(credentials, 'SENSEX', 'bse_fo', false);
          }
        } catch (e) {
          debugPrint('Error checking BSE F&O scrip master: $e');
        }
      }
    });
  }



  void _handleQuoteUpdate(MarketQuote quote) {
    if (!mounted) return;
    
    // Check if CMP changed significantly - if so, re-filter and re-subscribe (with debouncing)
    final previousCmp = _latestQuote?.lastPrice;
    final newCmp = quote.lastPrice;
    final cmpChanged = previousCmp == null || (newCmp - previousCmp).abs() > 50; // Re-filter if CMP changed by more than 50 points
    
    setState(() {
      _previousPrice = _latestQuote?.lastPrice ?? quote.lastPrice;
      _latestQuote = quote;
      _isLoading = false;
      _errorMessage = null;
      _isConnected = true;
    });
    
    // If CMP changed significantly, debounce re-subscription (wait 3 seconds for CMP to stabilize)
    if (cmpChanged && _credentials != null) {
      _niftyResubscribeTimer?.cancel();
      _niftyResubscribeTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _credentials != null) {
          debugPrint('NIFTY CMP changed from $previousCmp to $newCmp, re-subscribing to options...');
          _subscribeToIndexOptions(_credentials!, 'NIFTY', 'nse_fo', true);
        }
      });
    }
  }

  void _handleSensexQuoteUpdate(MarketQuote quote) {
    if (!mounted) return;
    
    // Check if CMP changed significantly - if so, re-filter and re-subscribe (with debouncing)
    final previousCmp = _latestSensexQuote?.lastPrice;
    final newCmp = quote.lastPrice;
    final cmpChanged = previousCmp == null || (newCmp - previousCmp).abs() > 50; // Re-filter if CMP changed by more than 50 points
    
    setState(() {
      _previousSensexPrice = _latestSensexQuote?.lastPrice ?? quote.lastPrice;
      _latestSensexQuote = quote;
      _isSensexConnected = true;
    });
    
    // If CMP changed significantly, debounce re-subscription (wait 3 seconds for CMP to stabilize)
    if (cmpChanged && _credentials != null) {
      _sensexResubscribeTimer?.cancel();
      _sensexResubscribeTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _credentials != null) {
          debugPrint('SENSEX CMP changed from $previousCmp to $newCmp, re-subscribing to options...');
          _subscribeToIndexOptions(_credentials!, 'SENSEX', 'bse_fo', false);
        }
      });
    }
  }

  Future<void> _manualRefresh() async {
    await _initialize();
  }

  void _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    // Check if OI & Option Chain data is enabled
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (oiAndOptionChainEnabled) {
      // Restart periodic OI recalculation with updated interval from settings
      _niftyOiUpdateTimer?.cancel();
      _sensexOiUpdateTimer?.cancel();
      _startPeriodicOiRecalculation();
      // Restart OI subscriptions if they were disabled before
      if (_niftyOptionSubscriptions.isEmpty && _sensexOptionSubscriptions.isEmpty) {
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            _startOiSubscriptions();
          }
        });
      }
    } else {
      // OI & Option Chain is disabled - cancel all OI subscriptions and timers
      _niftyOiUpdateTimer?.cancel();
      _sensexOiUpdateTimer?.cancel();
      for (var subscription in _niftyOptionSubscriptions.values) {
        subscription.cancel();
      }
      for (var subscription in _sensexOptionSubscriptions.values) {
        subscription.cancel();
      }
      _niftyOptionSubscriptions.clear();
      _sensexOptionSubscriptions.clear();
      _niftyOptionOI.clear();
      _sensexOptionOI.clear();
      debugPrint('OI & Option Chain data disabled - cancelled all OI subscriptions');
    }
    
    // Also reinitialize to refresh connections
    await _initialize();
  }


  Future<void> _openScripSearch() async {
    final hit = await showSearch<ScripSearchHit?>(
      context: context,
      delegate: ScripSearchDelegate(searchService: _scripSearchService),
    );

    if (!mounted || hit == null) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScripDetailScreen(hit: hit),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only show AppBar on Dashboard tab (0), hide for all other tabs
    final bool showAppBar = _selectedNavIndex == 0;
    
    return Scaffold(
      extendBody: true,
      appBar: showAppBar ? AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: ClipOval(
            child: Image.asset(
              'assets/images/logo.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Search scrip master',
            icon: const Icon(Icons.search),
            onPressed: _openScripSearch,
          ),
          IconButton(
            tooltip: 'Adjust credentials',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ) : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedNavIndex,
        onTap: (index) {
          setState(() => _selectedNavIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.swap_horiz_outlined),
            label: 'Orders',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_outlined),
            label: 'Positions',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.star_outline),
            label: 'Watchlist',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.table_chart),
            label: 'Option',
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: _buildCurrentTab(),
      ),
    );
  }

  Widget _buildCurrentTab() {
    switch (_selectedNavIndex) {
      case 0:
        return _buildMarketBody();
      case 1:
        return const OrdersScreen();
      case 2:
        return const PositionsScreen();
      case 3:
        return const WatchlistScreen();
      case 4:
        return const OptionChainScreen();
      default:
        return _buildMarketBody();
    }
  }

  Widget _buildMarketBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 54, color: Colors.red.shade400),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _initialize,
              icon: const Icon(Icons.replay),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_latestQuote == null) {
      return const Center(child: Text('Waiting for live price...'));
    }

    final quote = _latestQuote!;
    final change = quote.change ?? 0;
    final changePercent = quote.changePercent ?? 0;
    final isGain = change >= 0;
    final changeColor = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF0F172A),
            const Color(0xFF1E293B),
            Theme.of(context).colorScheme.surface,
          ],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: _manualRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 100),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildSwipeableIndexCards(quote, change, changePercent, changeColor),
          ],
        ),
      ),
    );
  }

  Widget _buildOrdersPlaceholder() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.swap_horiz_outlined, size: 52, color: Colors.white70),
          const SizedBox(height: 16),
          const Text(
            'Order placement coming soon.\nUse the button below in the meantime.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openScripSearch,
            icon: const Icon(Icons.playlist_add_check),
            label: const Text('Place Order'),
          ),
        ],
      ),
    );
  }


  Widget _buildSwipeableIndexCards(
    MarketQuote quote,
    double change,
    double changePercent,
    Color changeColor,
  ) {
    final List<Widget> cards = [
      _buildNiftyCard(quote, change, changePercent, changeColor),
    ];
    
    if (_latestSensexQuote != null) {
      cards.add(_buildSensexCard());
    }

    if (cards.length == 1) {
      return cards[0];
    }

    return SizedBox(
      height: 580,
      child: PageView.builder(
        controller: _pageController,
        itemCount: cards.length,
        onPageChanged: (index) {
          setState(() {
            _currentPageIndex = index;
          });
        },
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Stack(
            children: [
              SingleChildScrollView(
                child: cards[index],
              ),
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    cards.length,
                    (indicatorIndex) => Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _currentPageIndex == indicatorIndex
                            ? Colors.white
                            : Colors.white.withOpacity(0.3),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNiftyCard(
    MarketQuote quote,
    double change,
    double changePercent,
    Color changeColor,
  ) {
    final lastUpdated = quote.timestamp != null
        ? TimeOfDay.fromDateTime(quote.timestamp!)
        : TimeOfDay.now();
    final formattedTime =
        '${lastUpdated.hourOfPeriod.toString().padLeft(2, '0')}:${lastUpdated.minute.toString().padLeft(2, '0')} ${lastUpdated.period == DayPeriod.am ? 'AM' : 'PM'}';

    return Card(
      color: const Color(0xFF1E293B),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
      children: [
        const CircleAvatar(
                  radius: 20,
          backgroundColor: Colors.white12,
                  child: Icon(Icons.trending_up, color: Colors.white, size: 22),
        ),
                const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nifty 50 Index',
                style: TextStyle(
                  color: Colors.white,
                          fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
                      const SizedBox(height: 4),
              _LiveBadge(isLive: !quote.isSnapshot && _isConnected),
              const SizedBox(height: 4),
              Text(
                'Last updated $formattedTime',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Last Traded Price',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: _previousPrice ?? quote.lastPrice,
                end: quote.lastPrice,
              ),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Text(
                  '₹${value.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: changeColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    change >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: changeColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: changeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${changePercent >= 0 ? '+' : ''}${changePercent.toStringAsFixed(2)}%)',
                    style: TextStyle(
                      color: changeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _SensexStatItem(
                    label: 'Open',
                    value: quote.openPrice != null
                        ? '₹${quote.openPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SensexStatItem(
                    label: 'Previous Close',
                    value: quote.closePrice != null
                        ? '₹${quote.closePrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SensexStatItem(
                    label: 'Day High',
                    value: quote.highPrice != null
                        ? '₹${quote.highPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SensexStatItem(
                    label: 'Day Low',
                    value: quote.lowPrice != null
                        ? '₹${quote.lowPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
              ],
            ),
            // Always show OI section (even if no data yet) so user knows where to look
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.blue.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Open Interest (Nearest Expiry)',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        color: Colors.white70,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _refreshOi(true),
                        tooltip: 'Refresh OI',
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _OIStatItem(
                          label: 'Call OI',
                          value: _niftyCallOI != null
                              ? _formatOI(_niftyCallOI!)
                              : 'Loading...',
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _OIStatItem(
                          label: 'Put OI',
                          value: _niftyPutOI != null
                              ? _formatOI(_niftyPutOI!)
                              : 'Loading...',
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                  if (_lastNiftyOiUpdate != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Last updated: ${_formatLastUpdateTime(_lastNiftyOiUpdate!)}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensexCard() {
    final sensexQuote = _latestSensexQuote!;
    final change = sensexQuote.change ?? 0;
    final changePercent = sensexQuote.changePercent ?? 0;
    final isGain = change >= 0;
    final changeColor = isGain ? const Color(0xFF34D399) : const Color(0xFFF87171);
    final lastUpdated = sensexQuote.timestamp != null
        ? TimeOfDay.fromDateTime(sensexQuote.timestamp!)
        : TimeOfDay.now();
    final formattedTime =
        '${lastUpdated.hourOfPeriod.toString().padLeft(2, '0')}:${lastUpdated.minute.toString().padLeft(2, '0')} ${lastUpdated.period == DayPeriod.am ? 'AM' : 'PM'}';

    return Card(
      color: const Color(0xFF1E293B),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.white12,
                  child: Icon(Icons.trending_up, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                      const Text(
                        'Sensex Index',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _LiveBadge(isLive: !sensexQuote.isSnapshot && _isSensexConnected),
                      const SizedBox(height: 4),
                      Text(
                        'Last updated $formattedTime',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Last Traded Price',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: _previousSensexPrice ?? sensexQuote.lastPrice,
                end: sensexQuote.lastPrice,
              ),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Text(
                  '₹${value.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: changeColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    change >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: changeColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: changeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${changePercent >= 0 ? '+' : ''}${changePercent.toStringAsFixed(2)}%)',
                    style: TextStyle(
                      color: changeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _SensexStatItem(
                    label: 'Open',
                    value: sensexQuote.openPrice != null
                        ? '₹${sensexQuote.openPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SensexStatItem(
                    label: 'Previous Close',
                    value: sensexQuote.closePrice != null
                        ? '₹${sensexQuote.closePrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SensexStatItem(
                    label: 'Day High',
                    value: sensexQuote.highPrice != null
                        ? '₹${sensexQuote.highPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SensexStatItem(
                    label: 'Day Low',
                    value: sensexQuote.lowPrice != null
                        ? '₹${sensexQuote.lowPrice!.toStringAsFixed(2)}'
                        : '—',
                  ),
                ),
              ],
            ),
            // Always show OI section (even if no data yet) so user knows where to look
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.blue.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Open Interest (Nearest Expiry)',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        color: Colors.white70,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _refreshOi(false),
                        tooltip: 'Refresh OI',
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _OIStatItem(
                          label: 'Call OI',
                          value: _sensexCallOI != null
                              ? _formatOI(_sensexCallOI!)
                              : 'Loading...',
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _OIStatItem(
                          label: 'Put OI',
                          value: _sensexPutOI != null
                              ? _formatOI(_sensexPutOI!)
                              : 'Loading...',
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                  if (_lastSensexOiUpdate != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Last updated: ${_formatLastUpdateTime(_lastSensexOiUpdate!)}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarketStatsGrid(MarketQuote quote) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.15,
      children: [
        _StatTile(
          title: 'Open',
          value: quote.openPrice != null
              ? '₹${quote.openPrice!.toStringAsFixed(2)}'
              : '—',
          icon: Icons.play_arrow,
          color: Colors.blue.shade600,
        ),
        _StatTile(
          title: 'Previous Close',
          value: quote.closePrice != null
              ? '₹${quote.closePrice!.toStringAsFixed(2)}'
              : '—',
          icon: Icons.flag,
          color: Colors.deepPurple.shade400,
        ),
        _StatTile(
          title: 'Day High',
          value: quote.highPrice != null
              ? '₹${quote.highPrice!.toStringAsFixed(2)}'
              : '—',
          icon: Icons.north_east,
          color: Colors.green.shade500,
        ),
        _StatTile(
          title: 'Day Low',
          value: quote.lowPrice != null
              ? '₹${quote.lowPrice!.toStringAsFixed(2)}'
              : '—',
          icon: Icons.south_east,
          color: Colors.red.shade400,
        ),
      ],
    );
  }

  static String _formatNumber(double value) {
    if (value >= 1e7) {
      return '${(value / 1e7).toStringAsFixed(2)} Cr';
    }
    if (value >= 1e5) {
      return '${(value / 1e5).toStringAsFixed(2)} L';
    }
    if (value >= 1e3) {
      return '${(value / 1e3).toStringAsFixed(2)} K';
    }
    return value.toStringAsFixed(0);
  }

  String _cleanErrorMessage(String message) {
    return message.replaceFirst('Exception: ', '');
  }

  void _refreshOi(bool isNifty) async {
    final credentials = _credentials;
    if (credentials == null) return;
    
    // Check if OI & Option Chain data is enabled
    final prefs = await SharedPreferences.getInstance();
    final oiAndOptionChainEnabled = prefs.getBool('oi_and_option_chain_enabled') ?? true;
    
    if (!oiAndOptionChainEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('OI & Option Chain data is disabled in Settings'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    // Force immediate recalculation of OI totals
    _updateTotalOI(isNifty);
    if (mounted) {
      setState(() {
        if (isNifty) {
          _lastNiftyOiUpdate = DateTime.now();
        } else {
          _lastSensexOiUpdate = DateTime.now();
        }
      });
    }
  }
  
  String _formatLastUpdateTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    
    if (difference.inSeconds < 60) {
      return '${difference.inSeconds}s ago';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  String _formatOI(double oi) {
    if (oi >= 1e7) {
      return '${(oi / 1e7).toStringAsFixed(2)} Cr';
    }
    if (oi >= 1e5) {
      return '${(oi / 1e5).toStringAsFixed(2)} L';
    }
    if (oi >= 1e3) {
      return '${(oi / 1e3).toStringAsFixed(2)} K';
    }
    return oi.toStringAsFixed(0);
  }

}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.isLive});

  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final color = isLive ? Colors.greenAccent : Colors.orangeAccent;
    final label = isLive ? 'LIVE' : 'SNAPSHOT';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.18),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SensexStatItem extends StatelessWidget {
  const _SensexStatItem({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _OIStatItem extends StatelessWidget {
  const _OIStatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color.withOpacity(0.9),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
