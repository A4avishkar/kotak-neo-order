import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:otp/otp.dart';
import '../models/credentials.dart';
import '../models/order_request.dart';

class KotakApiService {
  static const String baseUrl = "https://mis.kotaksecurities.com";
  static const String totpLoginEndpoint = "login/1.0/tradeApiLogin";
  static const String totpValidateEndpoint = "login/1.0/tradeApiValidate";
  static const String placeOrderEndpoint = "quick/order/rule/ms/place";
  static const String defaultNeoFinKey = "neotradeapi";
  
  // Session management - cache tokens to avoid unnecessary TOTP verifications
  String? _editToken;
  String? _editSid;
  String? _serverId;
  String? _orderBaseUrl;
  DateTime? _lastAuthenticatedAt;
  Future<void>? _authInFlight;
  
  static const Duration _sessionValidity = Duration(minutes: 12);

  // Exchange segment mapping
  static final Map<String, String> exchangeSegmentMap = {
    "nse_cm": "nse_cm",
    "NSE": "nse_cm",
    "nse": "nse_cm",
    "BSE": "bse_cm",
    "bse": "bse_cm",
    "bse_cm": "bse_cm",
    "NFO": "nse_fo",
    "nse_fo": "nse_fo",
    "nfo": "nse_fo",
    "BFO": "bse_fo",
    "bse_fo": "bse_fo",
    "bfo": "bse_fo",
    "CDS": "cde_fo",
    "cde_fo": "cde_fo",
    "cds": "cde_fo",
    "BCD": "bcs-fo",
    "bcs-fo": "bcs-fo",
    "bcd": "bcs-fo",
    "MCX": "mcx",
    "mcx": "mcx",
    "mcx_fo": "mcx"
  };

  // Product mapping
  static final Map<String, String> productMap = {
    "Normal": "NRML",
    "NRML": "NRML",
    "CNC": "CNC",
    "cnc": "CNC",
    "Cash and Carry": "CNC",
    "MIS": "MIS",
    "mis": "MIS",
    "INTRADAY": "INTRADAY",
    "intraday": "INTRADAY",
    "Cover Order": "CO",
    "co": "CO",
    "CO": "CO",
    "BO": "BO",
    "Bracket Order": "BO",
    "bo": "BO"
  };

  // Order type mapping
  static final Map<String, String> orderTypeMap = {
    "Limit": "L",
    "L": "L",
    "l": "L",
    "MKT": "MKT",
    "mkt": "MKT",
    "Market": "MKT",
    "sl": "SL",
    "SL": "SL",
    "Stop loss limit": "SL",
    "Stop loss market": "SL-M",
    "SL-M": "SL-M",
    "sl-m": "SL-M",
    "Spread": "SP",
    "SP": "SP",
    "sp": "SP",
    "2L": "2L",
    "2l": "2L",
    "Two Leg": "2L",
    "3L": "3L",
    "3l": "3L",
    "Three leg": "3L"
  };

  /// Normalizes option symbol format for order placement API
  /// The Kotak API expects pTrdSymbol format WITHOUT .00 (e.g., SENSEX25NOV84600PE)
  /// Based on Python CLI: pScripRefKey (with .00) gets resolved to pTrdSymbol (without .00)
  /// This function ensures symbols with .00 are converted to the format without .00
  /// Only call this for F&O options, not for stocks
  String normalizeOptionSymbol(String symbol) {
    final originalSymbol = symbol;
    symbol = symbol.trim().toUpperCase();
    
    // Only normalize if it's an option (ends with CE or PE)
    if (!symbol.endsWith('CE') && !symbol.endsWith('PE')) {
      // Not an option, return as-is
      print('Symbol normalization: "$originalSymbol" -> (no change, not an option)');
      return originalSymbol;
    }
    
    // If symbol contains .00, remove it (convert pScripRefKey format to pTrdSymbol format)
    // The API accepts pTrdSymbol format which does NOT have .00
    if (symbol.contains('.00')) {
      final withoutDotZero = symbol.replaceAll('.00', '');
      print('Symbol normalization: "$originalSymbol" -> "$withoutDotZero" (removed .00)');
      return withoutDotZero;
    }
    
    // If symbol doesn't have .00, use as-is (already in correct pTrdSymbol format)
    print('Symbol normalization: "$originalSymbol" -> (no change, already correct format)');
    return originalSymbol;
  }

  String generateTotpCode(String secret) {
    return OTP.generateTOTPCodeString(
      secret,
      DateTime.now().millisecondsSinceEpoch,
      algorithm: Algorithm.SHA1,
      isGoogle: true,
    );
  }

  Future<Map<String, dynamic>> totpLogin(
    Credentials credentials, {
    int maxRetries = 1,
  }) async {
    final url = Uri.parse("$baseUrl/$totpLoginEndpoint");
    final neoFinKey = credentials.neoFinKey ?? defaultNeoFinKey;

    String mobileNumber = credentials.mobileNumber;
    if (mobileNumber.length == 10 && !mobileNumber.startsWith('+')) {
      mobileNumber = '+91$mobileNumber';
    }

    final headers = {
      'Authorization': credentials.consumerKey,
      'neo-fin-key': neoFinKey,
      'Content-Type': 'application/json'
    };

    Exception? lastException;
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        // Generate fresh TOTP code for each attempt
        final totpCode = generateTotpCode(credentials.totpSecret);
        
        final body = jsonEncode({
          "mobileNumber": mobileNumber,
          "ucc": credentials.ucc,
          "totp": totpCode
        });

        final response = await http.post(
          url,
          headers: headers,
          body: body,
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          throw Exception(
              'TOTP login failed: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);
        if (data['data']?['status'] != 'success') {
          throw Exception('TOTP login failed: ${data.toString()}');
        }

        final viewToken = data['data']?['token'];
        final sid = data['data']?['sid'];

        if (viewToken == null || sid == null) {
          throw Exception('Missing token or sid in response: ${data.toString()}');
        }

        return {
          'viewToken': viewToken,
          'sid': sid,
          'data': data,
        };
      } catch (e) {
        lastException = e is Exception ? e : Exception('TOTP login request failed: $e');
        
        // If this is not the last attempt, wait a bit before retrying
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
      }
    }
    
    throw Exception('TOTP login failed after ${maxRetries + 1} attempt(s): $lastException');
  }

  Future<Map<String, dynamic>> totpValidate(
    Credentials credentials,
    String sid,
    String viewToken, {
    int maxRetries = 1,
  }) async {
    final url = Uri.parse("$baseUrl/$totpValidateEndpoint");
    final neoFinKey = credentials.neoFinKey ?? defaultNeoFinKey;

    final headers = {
      'Authorization': credentials.consumerKey,
      'sid': sid,
      'Auth': viewToken,
      'neo-fin-key': neoFinKey
    };

    final body = jsonEncode({
      "mpin": credentials.mpin
    });

    Exception? lastException;
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await http.post(
          url,
          headers: headers,
          body: body,
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          throw Exception(
              'TOTP validate failed: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);
        if (data['data']?['status'] != 'success') {
          throw Exception('TOTP validate failed: ${data.toString()}');
        }

        final editToken = data['data']?['token'];
        final editSid = data['data']?['sid'];
        final serverId = data['data']?['hsServerId'] ?? '';
        final baseUrl = data['data']?['baseUrl'];

        if (editToken == null || editSid == null || baseUrl == null) {
          throw Exception(
              'Missing required fields in response: ${data.toString()}');
        }

        return {
          'editToken': editToken,
          'editSid': editSid,
          'serverId': serverId,
          'baseUrl': baseUrl,
          'data': data,
        };
      } catch (e) {
        lastException = e is Exception ? e : Exception('TOTP validate request failed: $e');
        
        // If this is not the last attempt, wait a bit before retrying
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
      }
    }
    
    throw Exception('TOTP validate failed after ${maxRetries + 1} attempt(s): $lastException');
  }

  Future<Map<String, dynamic>> placeOrder(
    String baseUrl,
    String editToken,
    String editSid,
    String serverId,
    OrderRequest orderRequest,
  ) async {
    // Map convenience values
    final exchangeSegment =
        exchangeSegmentMap[orderRequest.segment] ?? orderRequest.segment;
    final productMapped =
        productMap[orderRequest.product] ?? orderRequest.product;
    final orderType =
        orderTypeMap[orderRequest.orderType] ?? orderRequest.orderType;
    final quantity = orderRequest.quantity.toString();
    final limitPrice = orderRequest.price?.toString() ?? "0";

    if (orderType.toUpperCase() == 'L' && orderRequest.price == null) {
      throw Exception("Limit order requires price");
    }

    // Only include sId in query params if it's not empty (matches Python CLI behavior)
    final url = serverId.isNotEmpty
        ? Uri.parse("$baseUrl/$placeOrderEndpoint").replace(
            queryParameters: {"sId": serverId},
          )
        : Uri.parse("$baseUrl/$placeOrderEndpoint");

    final headers = {
      "Sid": editSid,
      "Auth": editToken,
      "Content-Type": "application/x-www-form-urlencoded"
    };

    // Order body parameters
    // Match Python CLI approach: normalize option symbols (only for F&O options, not stocks)
    // Python CLI: resolves pScripRefKey → pTrdSymbol from CSV, then tries both formats
    // Dart: symbol candidates already try pTrdSymbol first, then pScripRefKey variants
    // Normalization removes .00 if present (matches Python's "without .00" variant)
    // For stocks (nse_cm, bse_cm): use symbol as-is (no normalization)
    final isFnoSegment = exchangeSegment.toLowerCase().contains('_fo');
    final symbol = isFnoSegment 
        ? normalizeOptionSymbol(orderRequest.symbol)
        : orderRequest.symbol; // Stocks: use as-is
    print('Order placement - Segment: $exchangeSegment, Original symbol: ${orderRequest.symbol}, Normalized: $symbol');
    
    final orderData = {
      "am": "NO", // AMO
      "dq": "0", // Disclosed quantity
      "es": exchangeSegment,
      "mp": "0", // Market protection
      "pc": productMapped,
      "pf": "N", // Portfolio flag
      "pr": limitPrice,
      "pt": orderType,
      "qt": quantity,
      "rt": "DAY", // Validity
      "tp": "0", // Trigger price
      "ts": symbol, // Trading symbol
      "tt": orderRequest.transactionType, // Transaction type (B/S)
      "ig": orderRequest.tag ?? "MOBILE_APP_${DateTime.now().millisecondsSinceEpoch}", // Tag - always unique
      "os": "NEOTRADEAPI" // Order source
    };

    // Format as form-urlencoded with jData
    final body = {
      "jData": jsonEncode(orderData)
    };

    try {
      final response = await http.post(
        url,
        headers: headers,
        body: body,
      ).timeout(const Duration(seconds: 30));

      final responseData = jsonDecode(response.body);
      
      // Debug: Log the response for troubleshooting
      print('API Response Status: ${response.statusCode}');
      print('API Response Body: ${response.body}');
      print('Symbol sent: $symbol');
      
      if (response.statusCode != 200) {
        // Try to extract error message from response
        String errorMsg = response.body;
        if (responseData is Map) {
          errorMsg = responseData['message'] ?? 
                    responseData['error'] ?? 
                    responseData['data']?['message'] ?? 
                    responseData['data']?['error'] ??
                    response.body;
        }
        throw Exception('Place order failed: $errorMsg');
      }

      // Check if response indicates an error even with 200 status
      if (responseData is Map) {
        final status = responseData['status'] ?? responseData['data']?['status'];
        if (status != null && status.toString().toLowerCase() != 'success') {
          // Try to get detailed error message
          String errorMsg = responseData['message'] ?? 
                          responseData['error'] ?? 
                          responseData['data']?['message'] ?? 
                          responseData['data']?['error'] ??
                          responseData['data']?['emsg'] ??
                          responseData['emsg'] ??
                          'Order placement failed';
          
          // If we have more details, include them
          if (responseData['data'] is Map) {
            final data = responseData['data'] as Map;
            final additionalInfo = data['errorDescription'] ?? 
                                  data['description'] ?? 
                                  data['reason'] ?? '';
            if (additionalInfo.isNotEmpty) {
              errorMsg = '$errorMsg: $additionalInfo';
            }
          }
          
          throw Exception(errorMsg);
        }
      }

      return responseData;
    } catch (e) {
      if (e.toString().contains('Place order failed:')) {
        rethrow;
      }
      throw Exception('Place order request failed: $e');
    }
  }

  Future<Map<String, dynamic>> fetchOrderBook(
    String baseUrl,
    String editToken,
    String editSid,
    String serverId,
  ) async {
    final url = Uri.parse("$baseUrl/quick/user/orders").replace(
      queryParameters: serverId.isNotEmpty ? {"sId": serverId} : {},
    );

    final headers = {
      "Sid": editSid,
      "Auth": editToken,
      "accept": "application/json",
    };

    try {
      final response = await http.get(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
            'Fetch order book failed: ${response.statusCode} - ${response.body}');
      }

      final data = jsonDecode(response.body);
      return data;
    } catch (e) {
      throw Exception('Fetch order book request failed: $e');
    }
  }

  Future<Map<String, dynamic>> fetchHoldings(
    String baseUrl,
    String editToken,
    String editSid,
    String serverId,
  ) async {
    final url = Uri.parse("$baseUrl/portfolio/v1/holdings").replace(
      queryParameters: serverId.isNotEmpty ? {"sId": serverId} : {},
    );

    final headers = {
      "Sid": editSid,
      "Auth": editToken,
      "accept": "*/*",
    };

    try {
      final response = await http.get(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
            'Fetch holdings failed: ${response.statusCode} - ${response.body}');
      }

      final data = jsonDecode(response.body);
      return data;
    } catch (e) {
      throw Exception('Fetch holdings request failed: $e');
    }
  }

  /// Authenticates and caches session tokens if needed
  /// Reuses existing tokens if session is still valid (within 12 minutes)
  Future<void> _ensureAuthenticated(Credentials credentials) async {
    final isSessionValid =
        _editToken != null &&
        _editSid != null &&
        _orderBaseUrl != null &&
        _lastAuthenticatedAt != null &&
        DateTime.now().difference(_lastAuthenticatedAt!) < _sessionValidity;

    if (isSessionValid) {
      return;
    }

    // If authentication is already in progress, wait for it
    if (_authInFlight != null) {
      return _authInFlight;
    }

    final completer = Completer<void>();
    _authInFlight = completer.future;

    try {
      // Step 1: TOTP Login
      final loginResult = await totpLogin(credentials);
      final viewToken = loginResult['viewToken'] as String;
      final sid = loginResult['sid'] as String;

      // Step 2: TOTP Validate
      final validateResult = await totpValidate(credentials, sid, viewToken);
      _editToken = validateResult['editToken'] as String;
      _editSid = validateResult['editSid'] as String;
      _serverId = validateResult['serverId'] as String;
      _orderBaseUrl = validateResult['baseUrl'] as String;
      _lastAuthenticatedAt = DateTime.now();
      
      completer.complete();
    } catch (error, stackTrace) {
      _resetSession();
      completer.completeError(error, stackTrace);
      rethrow;
    } finally {
      _authInFlight = null;
    }
  }

  void _resetSession() {
    _editToken = null;
    _editSid = null;
    _serverId = null;
    _orderBaseUrl = null;
    _lastAuthenticatedAt = null;
  }

  Future<Map<String, dynamic>> executeOrderPlacement(
    Credentials credentials,
    OrderRequest orderRequest,
  ) async {
    // Ensure we have valid authentication tokens (cached or fresh)
    await _ensureAuthenticated(credentials);

    if (_editToken == null || _editSid == null || _orderBaseUrl == null) {
      throw Exception('Authentication failed: missing tokens');
    }

    try {
      // Place Order using cached tokens
      final orderResult = await placeOrder(
        _orderBaseUrl!,
        _editToken!,
        _editSid!,
        _serverId ?? '',
        orderRequest,
      );

      return orderResult;
    } catch (e) {
      // If order placement fails with auth error, reset session and retry once
      if (e.toString().contains('401') || 
          e.toString().contains('403') || 
          e.toString().contains('Unauthorized') ||
          e.toString().contains('Authentication')) {
        _resetSession();
        // Retry once with fresh authentication
        await _ensureAuthenticated(credentials);
        return await placeOrder(
          _orderBaseUrl!,
          _editToken!,
          _editSid!,
          _serverId ?? '',
          orderRequest,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> executeOrderBookFetch(
    Credentials credentials,
  ) async {
    // Ensure we have valid authentication tokens (cached or fresh)
    await _ensureAuthenticated(credentials);

    if (_editToken == null || _editSid == null || _orderBaseUrl == null) {
      throw Exception('Authentication failed: missing tokens');
    }

    try {
      // Fetch Order Book using cached tokens
      final orderBookResult = await fetchOrderBook(
        _orderBaseUrl!,
        _editToken!,
        _editSid!,
        _serverId ?? '',
      );

      return orderBookResult;
    } catch (e) {
      // If fetch fails with auth error, reset session and retry once
      if (e.toString().contains('401') || 
          e.toString().contains('403') || 
          e.toString().contains('Unauthorized') ||
          e.toString().contains('Authentication')) {
        _resetSession();
        // Retry once with fresh authentication
        await _ensureAuthenticated(credentials);
        return await fetchOrderBook(
          _orderBaseUrl!,
          _editToken!,
          _editSid!,
          _serverId ?? '',
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> executeHoldingsFetch(
    Credentials credentials,
  ) async {
    // Ensure we have valid authentication tokens (cached or fresh)
    await _ensureAuthenticated(credentials);

    if (_editToken == null || _editSid == null || _orderBaseUrl == null) {
      throw Exception('Authentication failed: missing tokens');
    }

    try {
      // Fetch Holdings using cached tokens
      final holdingsResult = await fetchHoldings(
        _orderBaseUrl!,
        _editToken!,
        _editSid!,
        _serverId ?? '',
      );

      return holdingsResult;
    } catch (e) {
      // If fetch fails with auth error, reset session and retry once
      if (e.toString().contains('401') || 
          e.toString().contains('403') || 
          e.toString().contains('Unauthorized') ||
          e.toString().contains('Authentication')) {
        _resetSession();
        // Retry once with fresh authentication
        await _ensureAuthenticated(credentials);
        return await fetchHoldings(
          _orderBaseUrl!,
          _editToken!,
          _editSid!,
          _serverId ?? '',
        );
      }
      rethrow;
    }
  }
}

