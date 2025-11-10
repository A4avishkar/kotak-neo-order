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

  String generateTotpCode(String secret) {
    return OTP.generateTOTPCodeString(
      secret,
      DateTime.now().millisecondsSinceEpoch,
      algorithm: Algorithm.SHA1,
      isGoogle: true,
    );
  }

  Future<Map<String, dynamic>> totpLogin(
    Credentials credentials,
  ) async {
    final url = Uri.parse("$baseUrl/$totpLoginEndpoint");
    final totpCode = generateTotpCode(credentials.totpSecret);
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

    final body = jsonEncode({
      "mobileNumber": mobileNumber,
      "ucc": credentials.ucc,
      "totp": totpCode
    });

    try {
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
      throw Exception('TOTP login request failed: $e');
    }
  }

  Future<Map<String, dynamic>> totpValidate(
    Credentials credentials,
    String sid,
    String viewToken,
  ) async {
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
      throw Exception('TOTP validate request failed: $e');
    }
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

    final url = Uri.parse("$baseUrl/$placeOrderEndpoint").replace(
      queryParameters: {"sId": serverId},
    );

    final headers = {
      "Sid": editSid,
      "Auth": editToken,
      "Content-Type": "application/x-www-form-urlencoded"
    };

    // Order body parameters
    // Note: For NSE options, date format might need zero-padding (e.g., 011NOV25 instead of 11NOV25)
    final symbol = orderRequest.symbol;
    
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

  Future<Map<String, dynamic>> executeOrderPlacement(
    Credentials credentials,
    OrderRequest orderRequest,
  ) async {
    // Step 1: TOTP Login
    final loginResult = await totpLogin(credentials);
    final viewToken = loginResult['viewToken'] as String;
    final sid = loginResult['sid'] as String;

    // Step 2: TOTP Validate
    final validateResult = await totpValidate(credentials, sid, viewToken);
    final editToken = validateResult['editToken'] as String;
    final editSid = validateResult['editSid'] as String;
    final serverId = validateResult['serverId'] as String;
    final orderBaseUrl = validateResult['baseUrl'] as String;

    // Step 3: Place Order
    final orderResult = await placeOrder(
      orderBaseUrl,
      editToken,
      editSid,
      serverId,
      orderRequest,
    );

    return orderResult;
  }
}

