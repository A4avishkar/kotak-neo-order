import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:otp/otp.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import '../models/credentials.dart';
import '../models/market_quote.dart';
import '../models/position.dart';

class MarketDataService {
  MarketDataService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  
  // WebSocket enable/disable flag - loaded from SharedPreferences
  // disableWebSocket = true means WebSocket is disabled
  static bool disableWebSocket = true; // Default to disabled, will be loaded from SharedPreferences
  static const String _prefsKeyWebsocketEnabled = 'websocket_enabled';
  
  // Initialize WebSocket setting from SharedPreferences
  static Future<void> initializeWebsocketSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_prefsKeyWebsocketEnabled);
    // disableWebSocket = !enabled (if enabled is true, disableWebSocket should be false)
    disableWebSocket = !(enabled ?? true); // Default to enabled (disableWebSocket = false)
  }
  
  // Update WebSocket setting
  static Future<void> setWebsocketEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeyWebsocketEnabled, enabled);
    disableWebSocket = !enabled; // If enabled=true, disableWebSocket=false
  }

  static final Uri _baseUrlEndpoint = Uri.parse(
    'https://lapi.kotaksecurities.com/algo-user/v5/get-base-url',
  );
  static const String _positionsEndpoint = 'quick/user/positions';

  String? _baseUrl;
  String? _editToken;
  String? _editSid;
  String? _bearerToken;
  String? _hsServerId;
  DateTime? _lastAuthenticatedAt;
  DateTime? _lastBaseUrlFetch;

  Future<void>? _authInFlight;

  // Connection pool for batch subscriptions
  final Map<String, _PooledConnection> _connectionPool = {};
  
  // Expose authentication for pooled connections
  Future<void> authenticateForPool(Credentials credentials) => _authenticate(credentials);
  String? get editTokenForPool => _editToken;
  String? get editSidForPool => _editSid;

  static const Duration _sessionValidity = Duration(minutes: 12);
  static const Duration _requestTimeout = Duration(seconds: 30);

  static const Map<String, String> _pythonHeaders = {
    'User-Agent': 'python-requests/2.31.0',
    'Accept': '*/*',
    'Accept-Encoding': 'gzip, deflate',
    'Connection': 'keep-alive',
  };

  Future<void> _authenticate(Credentials credentials) async {
    final isSessionValid =
        _editToken != null &&
        _lastAuthenticatedAt != null &&
        DateTime.now().difference(_lastAuthenticatedAt!) < _sessionValidity;

    if (isSessionValid) {
      return;
    }

    if (_authInFlight != null) {
      return _authInFlight;
    }

    final completer = Completer<void>();
    _authInFlight = completer.future;

    try {
      await _ensureBaseUrl(credentials);
      await _sessionInit(credentials);
      final viewTokens = await _totpLogin(credentials);
      final editTokens = await _totpValidate(credentials, viewTokens);
      _editToken = editTokens.token;
      _editSid = editTokens.sid;
      _hsServerId = viewTokens.hsServerId;
      _lastAuthenticatedAt = DateTime.now();
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      rethrow;
    } finally {
      _authInFlight = null;
    }
  }

  /// Performs a lightweight GET with python-requests-style headers.
  /// Use this to verify whether the current network path is blocked.
  Future<void> runConnectivityDiagnostic(Uri uri) async {
    try {
      final response = await _httpClient
          .get(uri, headers: _pythonHeaders)
          .timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print(
        'Diagnostic GET ${uri.host} → ${response.statusCode}: ${response.reasonPhrase}',
      );
    } catch (error) {
      // ignore: avoid_print
      print('Diagnostic GET ${uri.host} failed: $error');
    }
  }

  Future<MarketQuote> fetchNiftyQuote(
    Credentials credentials, {
    bool retrying = false,
  }) async {
    return fetchQuote(credentials, 'nse_cm|Nifty 50', retrying: retrying);
  }

  /// Fetches a market quote for the given symbol.
  /// Symbol format: `{segmentCode}|{tradingSymbol}` (e.g., 'nse_cm|RELIANCE' or 'nse_fo|NIFTY24JAN26000CE')
  Future<MarketQuote> fetchQuote(
    Credentials credentials,
    String symbol, {
    bool retrying = false,
  }) async {
    await _authenticate(credentials);
    await _ensureBaseUrl(credentials);

    final token = _editToken;
    String? baseUrl = _baseUrl;

    if (baseUrl == null || token == null) {
      throw StateError(
        'Not authenticated. Please configure credentials again.',
      );
    }

    final attemptedHosts = <String>{};
    Exception? lastError;

    while (baseUrl != null && attemptedHosts.add(baseUrl)) {
      try {
        final authToken = _bearerToken ?? token;
        final quote = await _fetchQuoteFromBase(baseUrl, authToken, symbol);
        _baseUrl = baseUrl;
        return quote;
      } on _AuthQuoteException {
        if (retrying) {
          rethrow;
        }
        _resetSession();
        return fetchQuote(credentials, symbol, retrying: true);
      } on _RetryableQuoteException catch (error) {
        lastError = error;
        final fallback = _alternateBaseUrl(baseUrl);
        if (fallback == null || attemptedHosts.contains(fallback)) {
          break;
        }
        baseUrl = fallback;
        _baseUrl = fallback;
        _lastBaseUrlFetch = DateTime.now();
        // ignore: avoid_print
        print(
          'MarketDataService: ${error.message}. Retrying via ${Uri.parse(fallback).host}.',
        );
      } catch (error) {
        lastError = error is Exception ? error : Exception(error.toString());
        break;
      }
    }

    throw lastError ?? Exception('Failed to fetch market data.');
  }

  /// Creates a WebSocket stream for any symbol (stocks, options, or indices)
  Stream<MarketQuote> symbolWebsocketStream(
    Credentials credentials,
    String symbol, {
    Duration initialReconnectBackoff = const Duration(seconds: 3),
  }) {
    // TEMPORARY: If WebSocket is disabled, return empty stream
    if (disableWebSocket) {
      debugPrint('MarketDataService: WebSocket disabled - returning empty stream for $symbol');
      return Stream<MarketQuote>.empty();
    }
    
    // Determine prefix: 'if' for indices (nse_cm|Nifty 50), 'sf' for stocks/options
    final isIndex =
        symbol.toLowerCase().contains('nifty') ||
        symbol.toLowerCase().contains('sensex') ||
        symbol.toLowerCase().contains('bank');
    final prefix = isIndex ? 'if' : 'sf';

    late StreamController<MarketQuote> controller;
    IOWebSocketChannel? channel;
    bool manuallyClosed = false;
    Duration backoff = initialReconnectBackoff;

    void safeSend(Uint8List bytes) {
      try {
        channel?.sink.add(bytes);
      } catch (_) {}
    }

    late Future<void> Function() connect;
    late void Function() scheduleReconnect;
    late void Function() closeChannel;

    closeChannel = () {
      try {
        channel?.sink.close();
      } catch (_) {}
      channel = null;
    };

    scheduleReconnect = () {
      if (manuallyClosed) {
        return;
      }
      closeChannel();
      Future.delayed(backoff, () {
        if (!manuallyClosed) {
          connect();
        }
      });
      backoff = backoff + backoff;
      if (backoff > const Duration(seconds: 60)) {
        backoff = const Duration(seconds: 60);
      }
    };

    connect = () async {
      if (manuallyClosed) return;
      try {
        await _authenticate(credentials);
        final token = _editToken;
        final sid = _editSid;
        if (token == null || sid == null) {
          throw StateError('Unable to authenticate for live data.');
        }

        channel = IOWebSocketChannel.connect(
          Uri.parse('wss://mlhsm.kotaksecurities.com'),
          pingInterval: const Duration(seconds: 25),
        );

        final protocol = _SampleWsProtocol();
        bool subscribed = false;

        safeSend(protocol.buildConnection(token, sid));

        channel!.stream.listen(
          (event) {
            if (controller.isClosed) {
              return;
            }
            final data = event is Uint8List
                ? event
                : event is List<int>
                ? Uint8List.fromList(event)
                : null;
            if (data == null) return;
            final parsed = protocol.parse(data);
            if (parsed.ackBytes != null) {
              safeSend(parsed.ackBytes!);
            }
            if ((parsed.connectionOk ?? false) &&
                !subscribed &&
                !manuallyClosed) {
              debugPrint(
                'MarketDataService: Connection OK, subscribing to $symbol with prefix $prefix',
              );
              safeSend(protocol.buildSubscriptionWithPrefix(symbol, prefix));
              subscribed = true;
            }
            if (parsed.subscriptionOk == true) {
              debugPrint(
                'MarketDataService: Subscription acknowledged for $symbol',
              );
            }
            if (parsed.quotes.isNotEmpty) {
              debugPrint(
                'MarketDataService: Received ${parsed.quotes.length} quote(s) for $symbol',
              );
            }
            for (final quote in parsed.quotes) {
              if (!controller.isClosed) {
                controller.add(quote);
              }
            }
          },
          onDone: () {
            if (!manuallyClosed) {
              scheduleReconnect();
            }
          },
          onError: (error, stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
            if (!manuallyClosed) {
              scheduleReconnect();
            }
          },
          cancelOnError: true,
        );

        backoff = initialReconnectBackoff;
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
        scheduleReconnect();
      }
    };

    controller = StreamController<MarketQuote>.broadcast(
      onListen: () {
        manuallyClosed = false;
        backoff = initialReconnectBackoff;
        connect();
      },
      onCancel: () {
        manuallyClosed = true;
        closeChannel();
      },
    );

    return controller.stream;
  }

  Stream<MarketQuote> niftyWebsocketStream(
    Credentials credentials, {
    Duration initialReconnectBackoff = const Duration(seconds: 3),
  }) {
    // TEMPORARY: If WebSocket is disabled, return empty stream
    if (disableWebSocket) {
      debugPrint('MarketDataService: WebSocket disabled - returning empty stream for Nifty');
      return Stream<MarketQuote>.empty();
    }
    
    late StreamController<MarketQuote> controller;
    IOWebSocketChannel? channel;
    bool manuallyClosed = false;
    Duration backoff = initialReconnectBackoff;

    void safeSend(Uint8List bytes) {
      try {
        channel?.sink.add(bytes);
      } catch (_) {}
    }

    late Future<void> Function() connect;
    late void Function() scheduleReconnect;
    late void Function() closeChannel;

    closeChannel = () {
      try {
        channel?.sink.close();
      } catch (_) {}
      channel = null;
    };

    scheduleReconnect = () {
      if (manuallyClosed) {
        return;
      }
      closeChannel();
      Future.delayed(backoff, () {
        if (!manuallyClosed) {
          connect();
        }
      });
      backoff = backoff + backoff;
      if (backoff > const Duration(seconds: 60)) {
        backoff = const Duration(seconds: 60);
      }
    };

    connect = () async {
      if (manuallyClosed) return;
      try {
        await _authenticate(credentials);
        final token = _editToken;
        final sid = _editSid;
        if (token == null || sid == null) {
          throw StateError('Unable to authenticate for live data.');
        }

        channel = IOWebSocketChannel.connect(
          Uri.parse('wss://mlhsm.kotaksecurities.com'),
          pingInterval: const Duration(seconds: 25),
        );

        final protocol = _SampleWsProtocol();
        bool subscribed = false;

        safeSend(protocol.buildConnection(token, sid));

        channel!.stream.listen(
          (event) {
            if (controller.isClosed) {
              return;
            }
            final data = event is Uint8List
                ? event
                : event is List<int>
                ? Uint8List.fromList(event)
                : null;
            if (data == null) return;
            final parsed = protocol.parse(data);
            if (parsed.ackBytes != null) {
              safeSend(parsed.ackBytes!);
            }
            if ((parsed.connectionOk ?? false) &&
                !subscribed &&
                !manuallyClosed) {
              safeSend(protocol.buildSubscription('nse_cm|Nifty 50'));
              subscribed = true;
            }
            for (final quote in parsed.quotes) {
              if (!controller.isClosed) {
                controller.add(quote);
              }
            }
          },
          onDone: () {
            if (!manuallyClosed) {
              scheduleReconnect();
            }
          },
          onError: (error, stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
            if (!manuallyClosed) {
              scheduleReconnect();
            }
          },
          cancelOnError: true,
        );

        backoff = initialReconnectBackoff;
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
        scheduleReconnect();
      }
    };

    controller = StreamController<MarketQuote>.broadcast(
      onListen: () {
        manuallyClosed = false;
        backoff = initialReconnectBackoff;
        connect();
      },
      onCancel: () {
        manuallyClosed = true;
        closeChannel();
      },
    );

    return controller.stream;
  }

  void _resetSession() {
    _editToken = null;
    _editSid = null;
    _bearerToken = null;
    _hsServerId = null;
    _baseUrl = null;
    _lastAuthenticatedAt = null;
    _lastBaseUrlFetch = null;
  }

  /// Creates a batched WebSocket stream for multiple symbols using a single connection
  /// This is much more efficient than creating separate connections for each symbol
  /// Symbols are batched in groups of 100 (API limit)
  Stream<MarketQuote> batchSymbolWebsocketStream(
    Credentials credentials,
    List<String> symbols, {
    Duration initialReconnectBackoff = const Duration(seconds: 3),
  }) {
    // TEMPORARY: If WebSocket is disabled, return empty stream
    if (disableWebSocket) {
      debugPrint('MarketDataService: WebSocket disabled - returning empty stream for batch symbols (${symbols.length} symbols)');
      return Stream<MarketQuote>.empty();
    }
    
    if (symbols.isEmpty) {
      return const Stream<MarketQuote>.empty();
    }
    
    // Determine prefix based on first symbol
    final firstSymbol = symbols.first;
    final isIndex = firstSymbol.toLowerCase().contains('nifty') ||
        firstSymbol.toLowerCase().contains('sensex') ||
        firstSymbol.toLowerCase().contains('bank');
    final prefix = isIndex ? 'if' : 'sf';
    
    // Create a stream controller that routes quotes to the correct symbol
    final controller = StreamController<MarketQuote>.broadcast();
    final symbolSet = symbols.toSet();
    
    // Use connection pool key based on credentials UCC and prefix
    final poolKey = '${credentials.ucc}_$prefix';
    
    _PooledConnection? pooledConn = _connectionPool[poolKey];
    if (pooledConn == null) {
      pooledConn = _PooledConnection(credentials, prefix, this);
      _connectionPool[poolKey] = pooledConn;
    }
    
    // Register symbols with the pooled connection
    pooledConn.subscribe(symbols, (quote) {
      // Route quote to stream if it matches one of our symbols
      final quoteSymbol = quote.token ?? '';
      if (symbolSet.any((sym) => _symbolMatches(quoteSymbol, sym))) {
        if (!controller.isClosed) {
          controller.add(quote);
        }
      }
    });
    
    // Clean up when stream is cancelled
    controller.onCancel = () {
      pooledConn?.unsubscribe(symbols);
      // Remove from pool if no more subscriptions
      if (pooledConn?.subscriptionCount == 0) {
        pooledConn?.dispose();
        _connectionPool.remove(poolKey);
      }
    };
    
    return controller.stream;
  }
  
  bool _symbolMatches(String quoteSymbol, String subscriptionSymbol) {
    // Normalize both symbols for comparison
    final quoteNorm = quoteSymbol.replaceAll('if|', '').replaceAll('sf|', '').toLowerCase();
    final subNorm = subscriptionSymbol.replaceAll('if|', '').replaceAll('sf|', '').toLowerCase();
    
    return quoteNorm == subNorm || 
           quoteNorm.endsWith(subNorm) || 
           subNorm.endsWith(quoteNorm) ||
           quoteNorm.contains(subNorm) ||
           subNorm.contains(quoteNorm);
  }

  Future<void> _ensureBaseUrl(Credentials credentials) async {
    final shouldRefetch =
        _baseUrl == null ||
        _lastBaseUrlFetch == null ||
        DateTime.now().difference(_lastBaseUrlFetch!) > _sessionValidity;

    if (!shouldRefetch) {
      return;
    }

    final uri = _baseUrlEndpoint.replace(
      queryParameters: {'id': credentials.ucc},
    );

    final response = await _httpClient
        .get(uri, headers: _pythonHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        'Unable to resolve base URL (${response.statusCode}): ${response.body}',
      );
    }

    final Map<String, dynamic> payload = jsonDecode(response.body);
    final data = payload['data'] as Map<String, dynamic>?;
    final baseUrl = data?['baseURL'] as String?;

    if (baseUrl == null || baseUrl.isEmpty) {
      throw Exception('Base URL lookup returned empty response');
    }

    _baseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    _lastBaseUrlFetch = DateTime.now();
  }

  Future<void> _sessionInit(Credentials credentials) async {
    // Kotak seldom issues consumer secrets for retail users, so we skip OAuth
    // bearer flow unless a secret is provided in future.
    _bearerToken = null;
  }

  Future<_ViewTokens> _totpLogin(
    Credentials credentials, {
    int maxRetries = 1,
  }) async {
    final uri = Uri.parse(
      'https://mis.kotaksecurities.com/login/1.0/tradeApiLogin',
    );

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': credentials.consumerKey,
      'neo-fin-key': credentials.neoFinKey ?? 'neotradeapi',
    };

    Exception? lastException;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        // Generate fresh TOTP code for each attempt
        final totpCode = OTP.generateTOTPCodeString(
          credentials.totpSecret,
          DateTime.now().millisecondsSinceEpoch,
          interval: 30,
          algorithm: Algorithm.SHA1,
          isGoogle: true,
          length: 6,
        );

        final body = jsonEncode({
          'mobileNumber': _formatMobileNumber(credentials.mobileNumber),
          'ucc': credentials.ucc,
          'totp': totpCode,
        });

        final response = await _httpClient
            .post(uri, headers: headers, body: body)
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          throw Exception(
            'TOTP login failed (${response.statusCode}): ${response.body}',
          );
        }

        final Map<String, dynamic> payload = jsonDecode(response.body);
        final data = payload['data'] as Map<String, dynamic>?;

        if (data == null ||
            (data['status']?.toString().toLowerCase() ?? '') != 'success') {
          throw Exception('TOTP login failed: ${response.body}');
        }

        return _ViewTokens(
          token: data['token'] as String,
          sid: data['sid'] as String,
          hsServerId: data['hsServerId'] as String?,
        );
      } catch (e) {
        lastException = e is Exception
            ? e
            : Exception('TOTP login request failed: $e');

        // If this is not the last attempt, wait a bit before retrying
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
      }
    }

    throw Exception(
      'TOTP login failed after ${maxRetries + 1} attempt(s): $lastException',
    );
  }

  Future<_EditTokens> _totpValidate(
    Credentials credentials,
    _ViewTokens viewTokens, {
    int maxRetries = 1,
  }) async {
    final uri = Uri.parse(
      'https://mis.kotaksecurities.com/login/1.0/tradeApiValidate',
    );

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': credentials.consumerKey,
      'sid': viewTokens.sid,
      'Auth': viewTokens.token,
      'neo-fin-key': credentials.neoFinKey ?? 'neotradeapi',
    };

    final body = jsonEncode({'mpin': credentials.mpin});

    Exception? lastException;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await _httpClient
            .post(uri, headers: headers, body: body)
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          throw Exception(
            'TOTP validate failed (${response.statusCode}): ${response.body}',
          );
        }

        final Map<String, dynamic> payload = jsonDecode(response.body);
        final data = payload['data'] as Map<String, dynamic>?;

        if (data == null ||
            (data['status']?.toString().toLowerCase() ?? '') != 'success') {
          throw Exception('TOTP validate failed: ${response.body}');
        }

        final baseUrl = data['baseUrl'] as String?;
        if (baseUrl != null && baseUrl.isNotEmpty) {
          _baseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
          _lastBaseUrlFetch = DateTime.now();
        }

        return _EditTokens(
          token: data['token'] as String,
          sid: (data['sid'] as String?) ?? viewTokens.sid,
        );
      } catch (e) {
        lastException = e is Exception
            ? e
            : Exception('TOTP validate request failed: $e');

        // If this is not the last attempt, wait a bit before retrying
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
      }
    }

    throw Exception(
      'TOTP validate failed after ${maxRetries + 1} attempt(s): $lastException',
    );
  }

  String _formatMobileNumber(String mobile) {
    var formatted = mobile.trim();
    if (formatted.startsWith('+')) {
      return formatted;
    }
    final digits = formatted.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '+91$digits';
    }
    return formatted;
  }

  Future<MarketQuote> _fetchQuoteFromBase(
    String baseUrl,
    String token,
    String symbol,
  ) async {
    final encodedSymbol = Uri.encodeComponent(symbol);
    const quoteType = 'all';

    final quotesVersion = baseUrl.contains('gw-napi')
        ? 'apim/quotes/1.0'
        : 'apim/quotes/2.0';

    final uri = Uri.parse(
      '$baseUrl$quotesVersion/quotes/neosymbol/$encodedSymbol/$quoteType',
    );

    // ignore: avoid_print
    print(
      'MarketDataService: Fetching quote from ${uri.host}${uri.path} '
      '(baseUrl: $baseUrl, symbol: $symbol)',
    );

    http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: _buildQuoteHeaders(token))
          .timeout(_requestTimeout);
    } on TimeoutException catch (error) {
      throw _RetryableQuoteException(
        'Request to ${uri.host} timed out: $error',
      );
    } on SocketException catch (error) {
      throw _RetryableQuoteException(
        'Network error contacting ${uri.host}: $error',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const _AuthQuoteException(
        'Authorization failed while fetching market data.',
      );
    }

    if (response.statusCode >= 500) {
      final reason = response.body.isNotEmpty
          ? response.body
          : response.reasonPhrase;
      // ignore: avoid_print
      print(
        'MarketDataService: Server ${uri.host} responded ${response.statusCode}',
      );
      if (response.body.isNotEmpty) {
        // ignore: avoid_print
        print('MarketDataService: Body => ${response.body}');
      }
      // 503 errors often indicate server overload - provide helpful message
      if (response.statusCode == 503) {
        throw _RetryableQuoteException(
          'Server temporarily unavailable (503). The Kotak API server may be overloaded. Please try again in a moment.',
          statusCode: response.statusCode,
        );
      }
      throw _RetryableQuoteException(
        'Server error ${response.statusCode}: $reason',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode != 200) {
      final reason = response.body.isNotEmpty
          ? response.body
          : response.reasonPhrase;
      throw Exception(
        'Failed to fetch market data (${response.statusCode}): $reason',
      );
    }

    final Map<String, dynamic> payload = jsonDecode(response.body);
    final quotes = (payload['data']?['quotes'] as List?) ?? const [];
    if (quotes.isEmpty) {
      throw Exception('No quotes available in response');
    }

    final Map<String, dynamic> quote = quotes.first as Map<String, dynamic>;
    return _marketQuoteFromRestPayload(quote);
  }

  Map<String, String> _buildQuoteHeaders(String token) {
    return <String, String>{
      ..._pythonHeaders,
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<List<Position>> fetchPositions(Credentials credentials) async {
    await _authenticate(credentials);
    await _ensureBaseUrl(credentials);

    final baseUrl = _baseUrl;
    final token = _editToken;
    final sid = _editSid;

    if (baseUrl == null || token == null || sid == null) {
      throw StateError(
        'Not authenticated. Please configure credentials again.',
      );
    }

    final uri = Uri.parse('$baseUrl$_positionsEndpoint').replace(
      queryParameters: _hsServerId?.isNotEmpty == true
          ? {'sId': _hsServerId!}
          : null,
    );

    final response = await _httpClient
        .get(
          uri,
          headers: {'Sid': sid, 'Auth': token, 'accept': 'application/json'},
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch positions (${response.statusCode}): ${response.body}',
      );
    }

    final dynamic payload = jsonDecode(response.body);
    final list = _extractPositionList(payload);
    if (list == null) {
      return const [];
    }

    return list
        .whereType<Map<String, dynamic>>()
        .map(_positionFromEntry)
        .toList();
  }

  List<dynamic>? _extractPositionList(dynamic payload) {
    if (payload is List<dynamic>) {
      return payload;
    }
    if (payload is Map<String, dynamic>) {
      for (final key in [
        'positions',
        'positionList',
        'data',
        'netPositions',
        'day',
        'dayPositions',
      ]) {
        final value = payload[key];
        if (value is List<dynamic>) {
          return value;
        }
        if (value is Map<String, dynamic>) {
          final nested = _extractPositionList(value);
          if (nested != null) return nested;
        }
      }
    }
    return null;
  }

  Position _positionFromEntry(Map<String, dynamic> entry) {
    return Position(
      symbol: _deriveSymbol(entry),
      segment: _deriveSegment(entry),
      product: _deriveProduct(entry),
      netQty: _deriveNetQty(entry),
      buyAvg: _deriveAverage(entry, true),
      sellAvg: _deriveAverage(entry, false),
      pnl: _derivePnl(entry),
    );
  }

  String _deriveSymbol(Map<String, dynamic> entry) {
    return entry['tradingSymbol']?.toString() ??
        entry['trdSym']?.toString() ??
        entry['symbol']?.toString() ??
        entry['sym']?.toString() ??
        '-';
  }

  String _deriveSegment(Map<String, dynamic> entry) {
    return entry['segment']?.toString() ??
        entry['exchangeSegment']?.toString() ??
        entry['exSeg']?.toString() ??
        entry['exchange']?.toString() ??
        '-';
  }

  String _deriveProduct(Map<String, dynamic> entry) {
    return entry['product']?.toString() ??
        entry['productCode']?.toString() ??
        entry['prodType']?.toString() ??
        entry['prod']?.toString() ??
        '-';
  }

  double _deriveNetQty(Map<String, dynamic> entry) {
    final value =
        entry['netQty'] ??
        entry['netQuantity'] ??
        (_parsePositionNumber(entry['flBuyQty']) -
            _parsePositionNumber(entry['flSellQty']));
    return _parsePositionNumber(value);
  }

  double? _deriveAverage(Map<String, dynamic> entry, bool buy) {
    final keys = buy
        ? ['buyAvgPrice', 'buyAvg', 'buyavgprice']
        : ['sellAvgPrice', 'sellAvg', 'sellavgprice'];
    for (final key in keys) {
      final value = entry[key];
      if (value != null) {
        return _parsePositionNumber(value);
      }
    }
    final qtyKey = buy ? 'flBuyQty' : 'flSellQty';
    final amtKey = buy ? 'buyAmt' : 'sellAmt';
    final qty = _parsePositionNumber(entry[qtyKey]);
    final amt = _parsePositionNumber(entry[amtKey]);
    if (qty != 0) {
      return amt / qty;
    }
    return null;
  }

  double? _derivePnl(Map<String, dynamic> entry) {
    if (entry['pnl'] != null || entry['pAndL'] != null) {
      return _parsePositionNumber(entry['pnl'] ?? entry['pAndL']);
    }
    final sellAmt = _parsePositionNumber(entry['sellAmt']);
    final buyAmt = _parsePositionNumber(entry['buyAmt']);
    final pnl = sellAmt - buyAmt;
    if (pnl == 0) return null;
    return pnl;
  }

  double _parsePositionNumber(dynamic value) {
    if (value == null || value == '' || value == '-') {
      return 0;
    }
    if (value is num) {
      return value.toDouble();
    }
    final sanitized = value.toString().replaceAll(',', '');
    return double.tryParse(sanitized) ?? 0;
  }

  String? _alternateBaseUrl(String baseUrl) {
    if (baseUrl.contains('gw-napi')) {
      return baseUrl.replaceFirst('gw-napi', 'mnapi');
    }
    if (baseUrl.contains('mnapi')) {
      return baseUrl.replaceFirst('mnapi', 'gw-napi');
    }
    return null;
  }

  MarketQuote _marketQuoteFromRestPayload(Map<String, dynamic> quote) {
    return MarketQuote(
      token: (quote['tk'] ?? 'Nifty 50').toString(),
      lastPrice: _toDouble(quote['iv']) ?? 0,
      closePrice: _toDouble(quote['ic']),
      highPrice: _toDouble(quote['highPrice']),
      lowPrice: _toDouble(quote['lowPrice']),
      openPrice: _toDouble(quote['openingPrice']),
      change: _toDouble(quote['cng']),
      changePercent: _toDouble(quote['nc']),
      volume: _toDouble(quote['v']),
      turnover: _toDouble(quote['to']),
      openInterest: _toDouble(quote['oi'] ?? quote['openInterest'] ?? quote['open_interest']),
      timestamp: _parseTimestamp(quote['tvalue']),
    );
  }

  static double? _toDouble(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      // Assume epoch milliseconds
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    }
    if (value is String) {
      // Try parsing ISO-8601 or known formats
      try {
        return DateTime.parse(value).toLocal();
      } catch (_) {
        // Some responses come as dd/mm/yyyy hh:mm:ss
        final parts = value.split(' ');
        if (parts.length == 2) {
          final dateParts = parts[0].split('/');
          final timeParts = parts[1].split(':');
          if (dateParts.length == 3 && timeParts.length >= 2) {
            final day = int.tryParse(dateParts[0]);
            final month = int.tryParse(dateParts[1]);
            final year = int.tryParse(dateParts[2]);
            final hour = int.tryParse(timeParts[0]);
            final minute = int.tryParse(timeParts[1]);
            final second = timeParts.length > 2
                ? int.tryParse(timeParts[2])
                : 0;
            if (day != null &&
                month != null &&
                year != null &&
                hour != null &&
                minute != null &&
                second != null) {
              return DateTime(year, month, day, hour, minute, second);
            }
          }
        }
      }
    }
    return null;
  }
  
  void dispose() {
    // Close all pooled connections
    for (final conn in _connectionPool.values) {
      conn.dispose();
    }
    _connectionPool.clear();
    _httpClient.close();
  }
}

/// Internal class for managing a pooled WebSocket connection with batch subscriptions
class _PooledConnection {
  final Credentials _credentials;
  final String _prefix;
  final MarketDataService _service;
  
  IOWebSocketChannel? _channel;
  _SampleWsProtocol? _protocol;
  bool _isConnected = false;
  bool _isSubscribed = false;
  bool _manuallyClosed = false;
  
  // Map of symbol -> list of callbacks
  final Map<String, List<void Function(MarketQuote)>> _subscriptions = {};
  final List<String> _pendingSymbols = [];
  List<String> _lastSubscribedSymbols = [];
  
  Duration _reconnectBackoff = const Duration(seconds: 3);
  Timer? _reconnectTimer;
  
  _PooledConnection(this._credentials, this._prefix, this._service);
  
  int get subscriptionCount => _subscriptions.length;
  
  void subscribe(List<String> symbols, void Function(MarketQuote) onQuote) {
    bool needsSubscription = false;
    
    for (final symbol in symbols) {
      if (!_subscriptions.containsKey(symbol)) {
        needsSubscription = true;
        _subscriptions[symbol] = [];
        if (!_pendingSymbols.contains(symbol)) {
          _pendingSymbols.add(symbol);
        }
      }
      _subscriptions[symbol]!.add(onQuote);
    }
    
    if (needsSubscription) {
      debugPrint('_PooledConnection: Adding ${symbols.length} symbols to subscription queue (total pending: ${_pendingSymbols.length})');
      _ensureConnected();
    }
  }
  
  void unsubscribe(List<String> symbols) {
    for (final symbol in symbols) {
      _subscriptions.remove(symbol);
      _pendingSymbols.remove(symbol);
    }
    
    if (_subscriptions.isEmpty) {
      dispose();
    }
  }
  
  Future<void> _ensureConnected() async {
    if (_channel != null && _isConnected) {
      // If already connected, subscribe to pending symbols
      if (_pendingSymbols.isNotEmpty) {
        _subscribeToPending();
      }
      return;
    }
    
    if (_reconnectTimer != null) return;
    
    _connect();
  }
  
  Future<void> _connect() async {
    if (_manuallyClosed) return;
    
    // TEMPORARY: If WebSocket is disabled, don't connect
    if (MarketDataService.disableWebSocket) {
      debugPrint('_PooledConnection: WebSocket disabled - skipping connection');
      return;
    }
    
    try {
      await _service.authenticateForPool(_credentials);
      final token = _service.editTokenForPool;
      final sid = _service.editSidForPool;
      
      if (token == null || sid == null) {
        throw StateError('Unable to authenticate for live data.');
      }
      
      _channel = IOWebSocketChannel.connect(
        Uri.parse('wss://mlhsm.kotaksecurities.com'),
        pingInterval: const Duration(seconds: 25),
      );
      
      _protocol = _SampleWsProtocol();
      _isConnected = false;
      _isSubscribed = false;
      
      _safeSend(_protocol!.buildConnection(token, sid));
      
      _channel!.stream.listen(
        (event) {
          final data = event is Uint8List
              ? event
              : event is List<int>
              ? Uint8List.fromList(event)
              : null;
          if (data == null) return;
          
          // Log raw message type for debugging
          if (data.length > 3) {
            final msgType = data[2]; // Type byte is at position 2
            debugPrint('_PooledConnection: Received message type=$msgType, length=${data.length}');
          }
          
          final parsed = _protocol!.parse(data);
          
          if (parsed.ackBytes != null) {
            _safeSend(parsed.ackBytes!);
          }
          
          if (parsed.connectionOk == true && !_isConnected) {
            _isConnected = true;
            debugPrint('_PooledConnection: Connection OK, prefix: $_prefix');
            
            if (_pendingSymbols.isNotEmpty) {
              _subscribeToPending();
            }
          }
          
          if (parsed.subscriptionOk == true) {
            _isSubscribed = true;
            debugPrint('_PooledConnection: Subscription OK for ${_lastSubscribedSymbols.length} symbols');
            if (_lastSubscribedSymbols.isNotEmpty) {
              debugPrint('_PooledConnection: Subscribed to: ${_lastSubscribedSymbols.take(5).join(", ")}${_lastSubscribedSymbols.length > 5 ? "..." : ""}');
            }
          }
          
          // Log all quotes received (not just OI ones) for debugging
          if (parsed.quotes.isNotEmpty) {
            debugPrint('_PooledConnection: Received ${parsed.quotes.length} quote(s)');
            for (final quote in parsed.quotes) {
              final token = quote.token ?? 'unknown';
              final oi = quote.openInterest;
              debugPrint('_PooledConnection: Quote - token=$token, LTP=${quote.lastPrice}, OI=${oi != null ? oi : "null"}');
            }
          } else if (parsed.connectionOk == null && parsed.subscriptionOk == null && parsed.ackBytes == null) {
            // Log if we got a message but no quotes (might be a data message we're not parsing)
            debugPrint('_PooledConnection: Received message but no quotes parsed (type might not be 6)');
          }
          
          for (final quote in parsed.quotes) {
            _routeQuote(quote);
          }
        },
        onDone: () {
          if (!_manuallyClosed) {
            _scheduleReconnect();
          }
        },
        onError: (error, stackTrace) {
          debugPrint('_PooledConnection: Error: $error');
          if (!_manuallyClosed) {
            _scheduleReconnect();
          }
        },
        cancelOnError: true,
      );
      
      _reconnectBackoff = const Duration(seconds: 3);
    } catch (error, stackTrace) {
      debugPrint('_PooledConnection: Connection error: $error');
      _scheduleReconnect();
    }
  }
  
  void _subscribeToPending() {
    if (_pendingSymbols.isEmpty || _protocol == null || !_isConnected) return;
    
    // Store symbols before clearing (for logging)
    final symbolsToSubscribe = List<String>.from(_pendingSymbols);
    
    // Batch subscribe in groups of 100
    // Format: "prefix|symbol1&prefix|symbol2&prefix|symbol3"
    const batchSize = 100;
    for (int i = 0; i < _pendingSymbols.length; i += batchSize) {
      final batch = _pendingSymbols.skip(i).take(batchSize).toList();
      // Add prefix to each symbol: "sf|nse_fo|52829&sf|nse_fo|52830"
      final prefixedBatch = batch.map((sym) => '$_prefix|$sym').join('&');
      
      debugPrint('_PooledConnection: Batch subscribing to ${batch.length} symbols (format: $_prefix|...)');
      debugPrint('_PooledConnection: Sample symbols: ${batch.take(3).join(", ")}${batch.length > 3 ? "..." : ""}');
      _safeSend(_protocol!.buildBatchSubscription(prefixedBatch, ''));
    }
    
    // Clear after sending (subscription OK will come later)
    _pendingSymbols.clear();
    
    // Store for logging when subscription OK arrives
    _lastSubscribedSymbols = symbolsToSubscribe;
  }
  
  void _routeQuote(MarketQuote quote) {
    final quoteSymbol = quote.token ?? '';
    
    // Extract numeric token from quote (e.g., "sf|nse_fo|52829" -> "52829", or "52829" -> "52829")
    final quoteToken = _extractNumericToken(quoteSymbol);
    
    // Find matching subscriptions
    // Note: Verbose debug logging disabled to reduce console spam
    // Uncomment below if you need to debug quote routing:
    // final oi = quote.openInterest;
    // debugPrint('_PooledConnection: Routing quote token=$quoteSymbol (extracted=$quoteToken), LTP=${quote.lastPrice}, OI=${oi != null ? oi : "null"}, subscriptions=${_subscriptions.length}');
    
    int matchedCount = 0;
    List<String> matchedSymbols = [];
    
    for (final entry in _subscriptions.entries) {
      final subscriptionSymbol = entry.key;
      final subscriptionToken = _extractNumericToken(subscriptionSymbol);
      
      bool matched = false;
      
      // Match by extracted numeric token (most reliable)
      if (quoteToken.isNotEmpty && subscriptionToken.isNotEmpty && quoteToken == subscriptionToken) {
        matched = true;
      } else if (_symbolMatches(quoteSymbol, subscriptionSymbol)) {
        // Fallback to string matching
        matched = true;
      }
      
      if (matched) {
        matchedCount++;
        matchedSymbols.add(subscriptionSymbol);
        for (final callback in entry.value) {
          try {
            callback(quote);
          } catch (e) {
            debugPrint('_PooledConnection: Error in callback: $e');
          }
        }
      }
    }
    
    // Note: Verbose debug logging disabled to reduce console spam
    // Uncomment below if you need to debug quote matching:
    // if (matchedCount > 0) {
    //   debugPrint('_PooledConnection: Quote matched to $matchedCount subscription(s): ${matchedSymbols.take(3).join(", ")}${matchedSymbols.length > 3 ? "..." : ""}');
    // } else {
    //   debugPrint('_PooledConnection: Quote NOT matched! token=$quoteSymbol (extracted=$quoteToken), available subscriptions: ${_subscriptions.keys.take(5).join(", ")}...');
    // }
  }
  
  /// Extracts numeric token from symbol string
  /// Examples: "sf|nse_fo|52829" -> "52829", "nse_fo|52829" -> "52829", "52829" -> "52829"
  String _extractNumericToken(String symbol) {
    if (symbol.isEmpty) return '';
    
    // Remove prefixes like "sf|", "if|"
    String cleaned = symbol.replaceAll(RegExp(r'^(sf|if)\|'), '');
    
    // Extract the last numeric part (token is usually at the end after segment)
    // Pattern: segment|token or just token
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
  
  bool _symbolMatches(String quoteSymbol, String subscriptionSymbol) {
    // Normalize both symbols for comparison
    final quoteNorm = quoteSymbol.replaceAll('if|', '').replaceAll('sf|', '').toLowerCase();
    final subNorm = subscriptionSymbol.replaceAll('if|', '').replaceAll('sf|', '').toLowerCase();
    
    return quoteNorm == subNorm || 
           quoteNorm.endsWith(subNorm) || 
           subNorm.endsWith(quoteNorm) ||
           quoteNorm.contains(subNorm) ||
           subNorm.contains(quoteNorm);
  }
  
  void _safeSend(Uint8List bytes) {
    try {
      _channel?.sink.add(bytes);
    } catch (e) {
      debugPrint('_PooledConnection: Error sending: $e');
    }
  }
  
  void _scheduleReconnect() {
    if (_manuallyClosed || _reconnectTimer != null) return;
    
    _isConnected = false;
    _isSubscribed = false;
    _closeChannel();
    
    _reconnectTimer = Timer(_reconnectBackoff, () {
      _reconnectTimer = null;
      _reconnectBackoff = Duration(
        seconds: (_reconnectBackoff.inSeconds * 2).clamp(3, 60),
      );
      _connect();
    });
  }
  
  void _closeChannel() {
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
  
  void dispose() {
    _manuallyClosed = true;
    _closeChannel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscriptions.clear();
    _pendingSymbols.clear();
  }
}

// Exception classes

class _RetryableQuoteException implements Exception {
  _RetryableQuoteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

class _AuthQuoteException implements Exception {
  const _AuthQuoteException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _ViewTokens {
  const _ViewTokens({required this.token, required this.sid, this.hsServerId});

  final String token;
  final String sid;
  final String? hsServerId;
}

class _EditTokens {
  const _EditTokens({required this.token, required this.sid});

  final String token;
  final String sid;
}

class _SampleParseResult {
  const _SampleParseResult({
    this.connectionOk,
    this.subscriptionOk,
    this.ackBytes,
    this.quotes = const [],
  });

  final bool? connectionOk;
  final bool? subscriptionOk;
  final Uint8List? ackBytes;
  final List<MarketQuote> quotes;
}

class _SampleWsProtocol {
  final Map<int, _SampleTopic> _topics = {};
  int _ackTarget = 0;
  int _counter = 0;

  Uint8List buildConnection(String token, String sid) {
    const src = 'JS_API';
    final writer =
        _SampleByteWriter(src.length + token.length + sid.length + 13)
          ..markStart()
          ..putByte(1)
          ..putByte(3)
          ..putByte(1)
          ..putShort(token.length)
          ..putString(token)
          ..putByte(2)
          ..putShort(sid.length)
          ..putString(sid)
          ..putByte(3)
          ..putShort(src.length)
          ..putString(src)
          ..markEnd();
    return writer.bytes;
  }

  Uint8List buildSubscription(String scrip) {
    return buildSubscriptionWithPrefix(scrip, 'if');
  }

  Uint8List buildSubscriptionWithPrefix(String scrip, String prefix) {
    final payload = _scripBytes(scrip, prefix);
    final writer = _SampleByteWriter(payload.length + 11)
      ..markStart()
      ..putByte(4)
      ..putByte(2)
      ..putByte(1)
      ..putShort(payload.length)
      ..putBytes(payload)
      ..putByte(2)
      ..putShort(1)
      ..putByte(2)
      ..markEnd();
    return writer.bytes;
  }

  /// Build batch subscription for multiple symbols joined with &
  /// Format: "prefix|segment|token1&prefix|segment|token2&prefix|segment|token3"
  /// If batchScrips already contains prefixes (starts with "sf|" or "if|"), pass empty string for prefix
  /// This matches the Python getScripByteArray format:
  /// - First 2 bytes: count of scrips (big-endian)
  /// - For each scrip: 1 byte length + scrip string bytes
  Uint8List buildBatchSubscription(String batchScrips, String prefix) {
    Uint8List payload;
    if (prefix.isEmpty) {
      // batchScrips already has prefixes like "sf|nse_fo|52829&sf|nse_fo|52830"
      // Split by & and encode each scrip separately (matching Python getScripByteArray)
      final scripArray = batchScrips.split('&');
      final scripsCount = scripArray.length;
      
      // Calculate total data length: 2 bytes for count + (1 byte length + scrip bytes) for each scrip
      int dataLen = 2; // For count
      for (final scrip in scripArray) {
        dataLen += 1 + scrip.length; // 1 byte for length + scrip bytes
      }
      
      payload = Uint8List(dataLen);
      int pos = 0;
      
      // Write count (big-endian short)
      payload[pos++] = (scripsCount >> 8) & 0xFF;
      payload[pos++] = scripsCount & 0xFF;
      
      // Write each scrip: 1 byte length + scrip bytes
      for (final scrip in scripArray) {
        final scripBytes = utf8.encode(scrip);
        final scripLen = scripBytes.length;
        payload[pos++] = scripLen & 0xFF; // Length byte
        payload.setRange(pos, pos + scripLen, scripBytes);
        pos += scripLen;
      }
    } else {
      // For backward compatibility, use _scripBytes (adds prefix to entire string)
      payload = _scripBytes(batchScrips, prefix);
    }
    
    final writer = _SampleByteWriter(payload.length + 11)
      ..markStart()
      ..putByte(4)
      ..putByte(2)
      ..putByte(1)
      ..putShort(payload.length)
      ..putBytes(payload)
      ..putByte(2)
      ..putShort(1)
      ..putByte(2)
      ..markEnd();
    return writer.bytes;
  }

  _SampleParseResult parse(Uint8List data) {
    var pos = 0;
    final _ = _bufToInt(data, pos, 2);
    pos += 2;
    final type = data[pos++];

    if (type == 1) {
      final connectionOk = _parseConnectionAck(data, pos);
      return _SampleParseResult(connectionOk: connectionOk);
    }

    if (type == 4 || type == 5) {
      final status = _parseStatus(data, pos);
      return _SampleParseResult(subscriptionOk: status);
    }

    if (type != 6) {
      // Log unexpected message types for debugging
      if (type != 3) { // Type 3 is ACK, which is normal
        debugPrint('_SampleWsProtocol: Received unexpected message type=$type (expected 6 for quotes)');
      }
      return const _SampleParseResult();
    }

    Uint8List? ackBytes;
    if (_ackTarget > 0) {
      _counter += 1;
      final msgNum = _bufToInt(data, pos, 4);
      pos += 4;
      if (_counter == _ackTarget) {
        ackBytes = _buildAck(msgNum);
        _counter = 0;
      }
    }

    final responses = _bufToInt(data, pos, 2);
    pos += 2;
    
    debugPrint('_SampleWsProtocol: Parsing type 6 message with $responses response(s)');

    final quotes = <MarketQuote>[];

    for (var i = 0; i < responses; i++) {
      pos += 2;
      final respType = data[pos++];
      debugPrint('_SampleWsProtocol: Response $i: type=$respType (83=SNAP, 85=UPDATE)');
      if (respType == 83) {
        final topicId = _bufToInt(data, pos, 4);
        pos += 4;
        final nameLen = data[pos++];
        final name = utf8.decode(data.sublist(pos, pos + nameLen));
        pos += nameLen;
        // Handle both 'if|' (index feed) and 'sf|' (scrip feed) prefixes
        if (!name.startsWith('if|') && !name.startsWith('sf|')) {
          pos = _skipSnapshot(data, pos);
          continue;
        }
        debugPrint(
          '_SampleWsProtocol: Parsing snapshot for $name (type: ${name.startsWith('if|') ? 'index' : 'scrip'})',
        );
        final topic = name.startsWith('if|')
            ? _SampleIndexTopic()
            : _SampleScripTopic();
        // Store the topic name as the symbol (field ID 52) so quotes have the correct token
        // This ensures quotes have token like "sf|nse_fo|52829" matching our subscription format
        topic.setString(52, name);
        final fixedCount = data[pos++];
        for (var j = 0; j < fixedCount; j++) {
          final value = _bufToInt(data, pos, 4);
          topic.setLong(j, value);
          pos += 4;
        }
        topic.syncPrecision();
        final stringCount = data[pos++];
        for (var j = 0; j < stringCount; j++) {
          final fid = data[pos++];
          final len = data[pos++];
          final value = utf8.decode(data.sublist(pos, pos + len));
          pos += len;
          topic.setString(fid, value);
          // If field 52 (symbol) is set again, it will overwrite our topic name
          // But that's okay - the API might provide a different symbol format
        }
        _topics[topicId] = topic;
        final quote = topic.toMarketQuote('SNAP');
        debugPrint(
          '_SampleWsProtocol: Created snapshot quote for $name: LTP=${quote.lastPrice}, Change=${quote.change}',
        );
        quotes.add(quote);
      } else if (respType == 85) {
        final topicId = _bufToInt(data, pos, 4);
        pos += 4;
        final topic = _topics[topicId];
        if (topic == null) {
          debugPrint('_SampleWsProtocol: Update for unknown topic_$topicId, skipping (topic list has ${_topics.length} topics)');
          final count = data[pos++];
          pos += count * 4;
          continue;
        }
        final fixedCount = data[pos++];
        for (var j = 0; j < fixedCount; j++) {
          final value = _bufToInt(data, pos, 4);
          topic.setLong(j, value);
          pos += 4;
        }
        topic.syncPrecision(); // Ensure precision is synced for updates too
        final quote = topic.toMarketQuote('SUB');
        final token = quote.token ?? 'unknown';
        final oi = quote.openInterest;
        // Note: Verbose debug logging disabled to reduce console spam
        // Uncomment below if you need to debug WebSocket protocol parsing:
        // debugPrint(
        //   '_SampleWsProtocol: Created update quote for topic_$topicId (token=$token): LTP=${quote.lastPrice}, OI=${oi != null ? oi : "null"}, Change=${quote.change}',
        // );
        quotes.add(quote);
      } else {
        debugPrint('_SampleWsProtocol: Unknown response type: $respType');
      }
    }

    return _SampleParseResult(quotes: quotes, ackBytes: ackBytes);
  }

  bool _parseConnectionAck(Uint8List data, int pos) {
    final fieldCount = data[pos++];
    var ok = false;
    if (fieldCount >= 1) {
      pos += 1;
      final len = _bufToInt(data, pos, 2);
      pos += 2;
      final status = utf8.decode(data.sublist(pos, pos + len));
      pos += len;
      ok = status == 'K';
    }
    if (fieldCount >= 2) {
      pos += 1;
      final len = _bufToInt(data, pos, 2);
      pos += 2;
      _ackTarget = _bufToInt(data, pos, len);
    }
    return ok;
  }

  bool _parseStatus(Uint8List data, int pos) {
    final fieldCount = data[pos++];
    if (fieldCount == 0) return false;
    pos += 1;
    final len = _bufToInt(data, pos, 2);
    pos += 2;
    final status = utf8.decode(data.sublist(pos, pos + len));
    return status == 'K';
  }

  Uint8List _buildAck(int msg) {
    final writer = _SampleByteWriter(11)
      ..markStart()
      ..putByte(3)
      ..putByte(1)
      ..putByte(1)
      ..putShort(4)
      ..putInt(msg)
      ..markEnd();
    return writer.bytes;
  }

  Uint8List _scripBytes(String scrip, String prefix) {
    final joined = '$prefix|$scrip';
    final encoded = utf8.encode(joined);
    final buffer = Uint8List(encoded.length + 3);
    buffer[0] = 0;
    buffer[1] = 1;
    buffer[2] = encoded.length;
    buffer.setRange(3, encoded.length + 3, encoded);
    return buffer;
  }

  int _bufToInt(Uint8List data, int start, int len) {
    var value = 0;
    for (var i = 0; i < len; i++) {
      value = (value << 8) | data[start + i];
    }
    return value;
  }

  int _skipSnapshot(Uint8List data, int pos) {
    final fixedCount = data[pos++];
    pos += fixedCount * 4;
    final stringCount = data[pos++];
    for (var i = 0; i < stringCount; i++) {
      pos += 1;
      final len = data[pos++];
      pos += len;
    }
    return pos;
  }
}

class _SampleByteWriter {
  _SampleByteWriter(int size) : bytes = Uint8List(size);
  final Uint8List bytes;
  var _pos = 0;
  var _start = 0;

  void markStart() {
    _start = _pos;
    _pos += 2;
  }

  void markEnd() {
    final len = _pos - _start - 2;
    bytes[_start] = (len >> 8) & 0xFF;
    bytes[_start + 1] = len & 0xFF;
  }

  void putByte(int value) => bytes[_pos++] = value & 0xFF;

  void putShort(int value) {
    bytes[_pos++] = (value >> 8) & 0xFF;
    bytes[_pos++] = value & 0xFF;
  }

  void putInt(int value) {
    bytes[_pos++] = (value >> 24) & 0xFF;
    bytes[_pos++] = (value >> 16) & 0xFF;
    bytes[_pos++] = (value >> 8) & 0xFF;
    bytes[_pos++] = value & 0xFF;
  }

  void putString(String value) {
    final data = utf8.encode(value);
    for (final b in data) {
      bytes[_pos++] = b;
    }
  }

  void putBytes(List<int> values) {
    for (final b in values) {
      bytes[_pos++] = b;
    }
  }
}

abstract class _SampleTopic {
  final List<int?> _values = List<int?>.filled(100, null);
  final List<String?> _strings = List<String?>.filled(60, null);
  static const int _trash = -2147483648;

  void setLong(int index, int value) {
    _values[index] = value == _trash ? null : value;
  }

  void setString(int index, String value) {
    _strings[index] = value;
  }

  void syncPrecision();

  MarketQuote toMarketQuote(String requestType);
}

class _SampleIndexTopic extends _SampleTopic {
  static const int _idxLtp = 2;
  static const int _idxClose = 3;
  static const int _idxHigh = 5;
  static const int _idxLow = 6;
  static const int _idxOpen = 7;
  static const int _idxMultiplier = 8;
  static const int _idxPrecision = 9;
  static const int _idxChange = 10;
  static const int _idxPerChange = 11;
  static const int _idxTimestamp = 4;
  static const int _idxSymbol = 52;

  @override
  void syncPrecision() {
    _values[_idxPrecision] ??= 2;
    _values[_idxMultiplier] ??= 1;
  }

  @override
  MarketQuote toMarketQuote(String requestType) {
    final precision = _values[_idxPrecision] ?? 2;
    final multiplier = _values[_idxMultiplier] ?? 1;
    final scale = math.pow(10, precision) * multiplier;

    double? scaled(int? raw) {
      if (raw == null) return null;
      return raw / scale;
    }

    final lastPrice = scaled(_values[_idxLtp]) ?? 0;
    final close = scaled(_values[_idxClose]);
    final high = scaled(_values[_idxHigh]);
    final low = scaled(_values[_idxLow]);
    final open = scaled(_values[_idxOpen]);

    double? change;
    double? changePct;
    if (close != null && close != 0) {
      change = lastPrice - close;
      changePct = (change / close) * 100;
    }

    return MarketQuote(
      token: _strings[_idxSymbol] ?? 'Nifty 50',
      lastPrice: lastPrice,
      closePrice: close,
      highPrice: high,
      lowPrice: low,
      openPrice: open,
      change: change,
      changePercent: changePct,
      volume: null,
      turnover: null,
      timestamp: _timestampFromSeconds(_values[_idxTimestamp]),
      isSnapshot:
          !(requestType.toUpperCase() == 'SUB' ||
              requestType.toUpperCase() == 'UPDATE'),
    );
  }

  DateTime? _timestampFromSeconds(int? raw) {
    if (raw == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      raw * 1000,
      isUtc: true,
    ).toLocal();
  }
}

class _SampleScripTopic extends _SampleTopic {
  // Scrip feed field indices (different from index feed)
  static const int _idxVolume = 4;
  static const int _idxLtp = 5;
  static const int _idxVwap = 13;
  static const int _idxLow = 14;
  static const int _idxHigh = 15;
  static const int _idxOpen = 20;
  static const int _idxClose = 21;
  static const int _idxMultiplier = 23;
  static const int _idxPrecision = 24;
  static const int _idxChange = 25;
  static const int _idxPerChange = 26;
  static const int _idxTurnover = 27;
  // OI field index - from SCRIP_MAPPING[22] = DataType("oi", FieldTypes["LONG"])
  // OI is stored as a raw LONG (integer) value, not scaled
  static const int _idxOpenInterest = 22; // Correct OI field index from SCRIP_MAPPING
  static const int _idxTimestamp = 3; // ltt
  static const int _idxSymbol = 52;

  @override
  void syncPrecision() {
    _values[_idxPrecision] ??= 2;
    _values[_idxMultiplier] ??= 1;
  }

  @override
  MarketQuote toMarketQuote(String requestType) {
    final precision = _values[_idxPrecision] ?? 2;
    final multiplier = _values[_idxMultiplier] ?? 1;
    final scale = math.pow(10, precision) * multiplier;

    double? scaled(int? raw) {
      if (raw == null) return null;
      return raw / scale;
    }

    final lastPrice = scaled(_values[_idxLtp]) ?? 0;
    final close = scaled(_values[_idxClose]);
    final high = scaled(_values[_idxHigh]);
    final low = scaled(_values[_idxLow]);
    final open = scaled(_values[_idxOpen]);
    final volume = _values[_idxVolume]?.toDouble();
    final turnover = scaled(_values[_idxTurnover]);
    
    // OI is at index 22 (from SCRIP_MAPPING[22] = DataType("oi", FieldTypes["LONG"]))
    // OI is stored as a raw LONG (integer) value, NOT scaled
    // 
    // IMPORTANT: OI format clarification
    // - Python script (fetch_all_strikes_data copy.py) uses OI as-is without conversion
    // - CSV output shows OI values matching what we receive (e.g., 2458425, 3088800)
    // - These values appear to be in CONTRACTS (not lots)
    // - NIFTY options lot size is 50, so if OI were in lots, we'd multiply by 50
    // - But matching Python script behavior, we use raw value as-is
    // 
    // If OI values seem incorrect, verify:
    // 1. Are they in lots (need * 50) or contracts (use as-is)?
    // 2. Compare with Python script output CSV to confirm format
    final rawOI = _values[_idxOpenInterest];
    double? openInterest;
    
    if (rawOI != null) {
      // Use raw value directly (matching Python script behavior)
      // If you need OI in lots instead of contracts, divide by 50 here
      // If you need OI in contracts from lots, multiply by 50 here
      openInterest = rawOI.toDouble();
    }
    
    // Debug: Log OI value with format info
    final token = _strings[_idxSymbol] ?? 'unknown';
    // Note: Verbose debug logging disabled to reduce console spam
    // Uncomment below if you need to debug OI parsing:
    // if (rawOI != null) {
    //   // Calculate both interpretations for debugging
    //   final asContracts = openInterest;
    //   final asLots = openInterest! / 50.0;
    //   debugPrint('_SampleScripTopic[$token]: OI at index 22: raw=$rawOI, asContracts=$asContracts, asLots=${asLots.toStringAsFixed(1)}');
    // } else {
    //   debugPrint('_SampleScripTopic[$token]: OI at index 22: null (field not set)');
    // }

    double? change;
    double? changePct;
    if (close != null && close != 0) {
      change = lastPrice - close;
      changePct = (change / close) * 100;
    } else {
      // Try to use pre-calculated change if available
      change = scaled(_values[_idxChange]);
      final perChangeStr = _strings[_idxPerChange];
      if (perChangeStr != null) {
        changePct = double.tryParse(perChangeStr);
      }
    }

    return MarketQuote(
      token: _strings[_idxSymbol] ?? 'Unknown',
      lastPrice: lastPrice,
      closePrice: close,
      highPrice: high,
      lowPrice: low,
      openPrice: open,
      change: change,
      changePercent: changePct,
      volume: volume,
      turnover: turnover,
      openInterest: openInterest,
      timestamp: _timestampFromSeconds(_values[_idxTimestamp]),
      isSnapshot:
          !(requestType.toUpperCase() == 'SUB' ||
              requestType.toUpperCase() == 'UPDATE'),
    );
  }

  DateTime? _timestampFromSeconds(int? raw) {
    if (raw == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      raw * 1000,
      isUtc: true,
    ).toLocal();
  }
}
