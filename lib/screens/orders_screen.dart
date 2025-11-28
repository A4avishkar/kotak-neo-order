import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/credentials.dart';
import '../services/credentials_service.dart';
import '../services/kotak_api_service.dart';
import '../services/scrip_search_service.dart';
import 'take_position_screen.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final _credentialsService = CredentialsService();
  final _apiService = KotakApiService();
  final _scripSearchService = ScripSearchService();
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _orderBookData;
  List<dynamic> _orders = [];

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        throw Exception('Please configure credentials first');
      }

      final orderBookData = await _apiService.executeOrderBookFetch(credentials);
      
      // Debug: Print the response structure
      print('Order Book Response Keys: ${orderBookData.keys}');
      if (orderBookData['data'] != null) {
        print('Data type: ${orderBookData['data'].runtimeType}');
        if (orderBookData['data'] is Map) {
          print('Data keys: ${(orderBookData['data'] as Map).keys}');
        }
      }
      
      if (mounted) {
        setState(() {
          _orderBookData = orderBookData;
          // Extract orders from response - API typically returns data in 'data' field
          // Handle different possible response structures
          if (orderBookData['data'] != null) {
            if (orderBookData['data'] is List) {
              _orders = orderBookData['data'] as List;
              if (_orders.isNotEmpty) {
                print('First order keys: ${(_orders.first as Map).keys}');
              }
            } else if (orderBookData['data'] is Map) {
              final dataMap = orderBookData['data'] as Map;
              if (dataMap['orders'] is List) {
                _orders = dataMap['orders'] as List;
              } else if (dataMap['orderList'] is List) {
                _orders = dataMap['orderList'] as List;
              } else if (dataMap['FnoOrderBook'] is List) {
                _orders = dataMap['FnoOrderBook'] as List;
              } else if (dataMap['CmOrderBook'] is List) {
                _orders = dataMap['CmOrderBook'] as List;
              } else {
                // Try to find any list in the data map
                _orders = dataMap.values
                    .whereType<List>()
                    .expand((list) => list)
                    .toList();
              }
              if (_orders.isNotEmpty) {
                print('First order keys: ${(_orders.first as Map).keys}');
              }
            }
          } else if (orderBookData['orders'] is List) {
            _orders = orderBookData['orders'] as List;
          } else if (orderBookData['orderList'] is List) {
            _orders = orderBookData['orderList'] as List;
          } else if (orderBookData['FnoOrderBook'] is List) {
            _orders = orderBookData['FnoOrderBook'] as List;
          } else if (orderBookData['CmOrderBook'] is List) {
            _orders = orderBookData['CmOrderBook'] as List;
          }
          _isLoading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String _getOrderStatus(dynamic order) {
    if (order is Map) {
      // Try multiple field names for status
      final status = order['status']?.toString() ?? 
             order['orderStatus']?.toString() ?? 
             order['st']?.toString() ??
             order['ordStatus']?.toString() ??
             order['orderSt']?.toString() ??
             order['state']?.toString() ??
             order['ordStat']?.toString() ??
             order['stat']?.toString() ??
             order['statDesc']?.toString() ??
             order['ordStatDesc']?.toString();
      if (status != null && status.isNotEmpty && status != 'null') {
        return status;
      }
    }
    return 'Unknown';
  }

  String _getSymbol(dynamic order) {
    if (order is Map) {
      // Try all possible field names for symbol
      // Prefer trdSym (trading symbol) which shows full symbol like "NIFTY25NOV25900PE"
      final symbol = order['trdSym']?.toString() ??  // Full trading symbol from terminal output
             order['ts']?.toString() ??  // Most common in Kotak API
             order['tradingSymbol']?.toString() ?? 
             order['symbol']?.toString() ?? 
             order['trdSymbol']?.toString() ??
             order['instrument']?.toString() ??
             order['scripName']?.toString() ??
             order['scrip']?.toString() ??
             order['instrumentName']?.toString() ??
             order['name']?.toString() ??
             order['sym']?.toString();  // Base symbol like "NIFTY"
      if (symbol != null && symbol.isNotEmpty && symbol != 'null') {
        return symbol;
      }
    }
    return 'N/A';
  }

  String _getTransactionType(dynamic order) {
    if (order is Map) {
      final tt = order['tt']?.toString() ??  // Most common in Kotak API
                 order['transactionType']?.toString() ?? 
                 order['side']?.toString() ??
                 order['trdType']?.toString() ??
                 order['trxnType']?.toString() ??
                 order['buySell']?.toString() ??
                 order['bs']?.toString() ??  // Buy/Sell abbreviation
                 '';
      final ttUpper = tt.toUpperCase();
      if (ttUpper == 'B' || ttUpper == 'BUY' || ttUpper == 'BUY') {
        return 'BUY';
      } else if (ttUpper == 'S' || ttUpper == 'SELL' || ttUpper == 'SELL') {
        return 'SELL';
      }
    }
    return 'N/A';
  }

  String _getQuantity(dynamic order) {
    if (order is Map) {
      final qty = order['qt']?.toString() ??  // Most common in Kotak API
             order['quantity']?.toString() ?? 
             order['qty']?.toString() ??
             order['orderQty']?.toString() ??
             order['ordQty']?.toString() ??
             order['brdLtQty']?.toString() ??  // From terminal output
             '';
      if (qty != null && qty.isNotEmpty && qty != '0' && qty != 'null') {
        return qty;
      }
    }
    return '0';
  }

  String? _getFilledQuantity(dynamic order) {
    if (order is Map) {
      // From terminal output: fldQty is the filled quantity
      final filledQty = order['fldQty']?.toString() ??  // Most common in Kotak API
                       order['filledQty']?.toString() ??
                       order['filled']?.toString() ??
                       order['exeQty']?.toString() ??
                       order['execQty']?.toString() ??
                       order['exe']?.toString() ??
                       '';
      if (filledQty != null && filledQty.isNotEmpty && filledQty != '0' && filledQty != 'null') {
        return filledQty;
      }
    }
    return null;
  }

  String? _getPendingQuantity(dynamic order) {
    if (order is Map) {
      // From terminal output: unFldSz is the unfilled/pending quantity
      final pendingQty = order['unFldSz']?.toString() ??  // Most common in Kotak API
                        order['pendingQty']?.toString() ??
                        order['pending']?.toString() ??
                        order['remQty']?.toString() ??
                        order['remainingQty']?.toString() ??
                        '';
      if (pendingQty != null && pendingQty.isNotEmpty && pendingQty != '0' && pendingQty != 'null') {
        return pendingQty;
      }
    }
    return null;
  }

  String? _getCancelledQuantity(dynamic order) {
    if (order is Map) {
      // From terminal output: cnlQty is the cancelled quantity
      final cancelledQty = order['cnlQty']?.toString() ??
                         order['cancelledQty']?.toString() ??
                         order['cancelQty']?.toString() ??
                         '';
      if (cancelledQty != null && cancelledQty.isNotEmpty && cancelledQty != '0' && cancelledQty != 'null') {
        return cancelledQty;
      }
    }
    return null;
  }

  String? _getRejectionReason(dynamic order) {
    if (order is Map) {
      // From terminal output: rejRsn is the rejection reason
      final reason = order['rejRsn']?.toString() ??
                    order['rejectionReason']?.toString() ??
                    order['rejectReason']?.toString() ??
                    '';
      if (reason != null && reason.isNotEmpty && reason != '--' && reason != 'null') {
        return reason;
      }
    }
    return null;
  }

  String? _getExchangeOrderId(dynamic order) {
    if (order is Map) {
      // From terminal output: exOrdId is the exchange order ID
      final exOrderId = order['exOrdId']?.toString() ??
                       order['exchangeOrderId']?.toString() ??
                       order['exchOrderId']?.toString() ??
                       '';
      if (exOrderId != null && exOrderId.isNotEmpty && exOrderId != 'null') {
        return exOrderId;
      }
    }
    return null;
  }

  String? _getOrderDateTime(dynamic order) {
    if (order is Map) {
      // From terminal output: ordDtTm is the order date time
      final dateTime = order['ordDtTm']?.toString() ??
                      order['orderDateTime']?.toString() ??
                      order['orderDate']?.toString() ??
                      order['ordEntTm']?.toString() ??  // Order entry time
                      '';
      if (dateTime != null && dateTime.isNotEmpty && dateTime != 'null') {
        return dateTime;
      }
    }
    return null;
  }

  String? _getExchangeConfirmTime(dynamic order) {
    if (order is Map) {
      // From terminal output: exCfmTm is the exchange confirm time
      final confirmTime = order['exCfmTm']?.toString() ??
                         order['exchangeConfirmTime']?.toString() ??
                         order['exchConfirmTime']?.toString() ??
                         '';
      if (confirmTime != null && confirmTime.isNotEmpty && confirmTime != 'NA' && confirmTime != 'null') {
        return confirmTime;
      }
    }
    return null;
  }

  String? _getUpdateTime(dynamic order) {
    if (order is Map) {
      // From terminal output: hsUpTm is the update time (e.g., "2025/11/25 12:07:45")
      final updateTime = order['hsUpTm']?.toString() ??
                        order['updateTime']?.toString() ??
                        order['updTime']?.toString() ??
                        order['lastUpdateTime']?.toString() ??
                        '';
      if (updateTime != null && updateTime.isNotEmpty && updateTime != 'NA' && updateTime != 'null') {
        return updateTime;
      }
    }
    return null;
  }

  String _getPrice(dynamic order) {
    if (order is Map) {
      final price = order['pr']?.toString() ??  // Most common in Kotak API
                    order['price']?.toString() ?? 
                    order['limitPrice']?.toString() ??
                    order['ordPrice']?.toString() ??
                    order['orderPrice']?.toString() ??
                    order['lmtPrice']?.toString() ??
                    order['triggerPrice']?.toString() ??
                    '';
      if (price != null && price.isNotEmpty && price != '0' && price != 'null') {
        try {
          final priceNum = double.parse(price);
          if (priceNum > 0) {
            return '₹${priceNum.toStringAsFixed(2)}';
          }
        } catch (e) {
          // Ignore parse errors
        }
      }
      return 'MKT';
    }
    return 'MKT';
  }

  String? _getAveragePrice(dynamic order) {
    if (order is Map) {
      final avgPrice = order['avgPrc']?.toString() ??  // From terminal output
                      order['averagePrice']?.toString() ??
                      order['avgPrice']?.toString() ??
                      order['exePrc']?.toString() ??
                      order['execPrice']?.toString() ??
                      '';
      if (avgPrice != null && avgPrice.isNotEmpty && avgPrice != '0' && avgPrice != 'null') {
        try {
          final priceNum = double.parse(avgPrice);
          if (priceNum > 0) {
            return '₹${priceNum.toStringAsFixed(2)}';
          }
        } catch (e) {
          // Ignore parse errors
        }
      }
    }
    return null;
  }

  String _getProduct(dynamic order) {
    if (order is Map) {
      final product = order['pc']?.toString() ??  // Most common in Kotak API
             order['product']?.toString() ?? 
             order['productType']?.toString() ??
             order['prd']?.toString() ??
             order['prod']?.toString();
      if (product != null && product.isNotEmpty && product != 'null') {
        return product;
      }
    }
    return 'N/A';
  }

  String? _getSegment(dynamic order) {
    if (order is Map) {
      final segment = order['segment']?.toString() ?? 
             order['exch']?.toString() ?? 
             order['exchange']?.toString() ??
             order['seg']?.toString() ??
             order['exSeg']?.toString() ??
             '';
      if (segment.isNotEmpty && segment != 'null') {
        return segment.toLowerCase();
      }
    }
    return null;
  }

  String? _getPriceValue(dynamic order) {
    if (order is Map) {
      final price = order['pr']?.toString() ?? 
                    order['price']?.toString() ?? 
                    order['limitPrice']?.toString() ??
                    order['ordPrice']?.toString() ??
                    order['orderPrice']?.toString() ??
                    order['lmtPrice']?.toString() ??
                    '';
      if (price.isNotEmpty && price != '0' && price != 'null') {
        try {
          final priceNum = double.parse(price);
          if (priceNum > 0) {
            return priceNum.toStringAsFixed(2);
          }
        } catch (e) {
          // Ignore parse errors
        }
      }
    }
    return null;
  }

  String _getOrderType(dynamic order) {
    if (order is Map) {
      final orderType = order['pt']?.toString() ??  // Most common in Kotak API
             order['orderType']?.toString() ?? 
             order['type']?.toString() ??
             order['ordType']?.toString() ??
             order['ordTyp']?.toString();
      if (orderType != null && orderType.isNotEmpty && orderType != 'null') {
        return orderType;
      }
    }
    return 'N/A';
  }

  String _getOrderId(dynamic order) {
    if (order is Map) {
      final orderId = order['nOrdNo']?.toString() ??  // Most common in Kotak API
             order['orderId']?.toString() ?? 
             order['id']?.toString() ??
             order['ordId']?.toString() ??
             order['orderNo']?.toString() ??
             order['orderNumber']?.toString() ??
             order['nOrdNum']?.toString() ??
             order['ordNo']?.toString();
      if (orderId != null && orderId.isNotEmpty && orderId != 'null') {
        return orderId;
      }
    }
    return 'N/A';
  }

  Color _getStatusColor(String status) {
    final lowerStatus = status.toLowerCase();
    if (lowerStatus.contains('complete') || 
        lowerStatus.contains('executed') || 
        lowerStatus.contains('filled') ||
        lowerStatus.contains('traded') ||
        lowerStatus.contains('fully executed')) {
      return Colors.green;
    } else if (lowerStatus.contains('pending') || 
               lowerStatus.contains('open') || 
               lowerStatus.contains('active') ||
               lowerStatus.contains('trigger pending') ||
               lowerStatus.contains('validation pending')) {
      return Colors.orange;
    } else if (lowerStatus.contains('reject') || 
               lowerStatus.contains('cancel') || 
               lowerStatus.contains('error') ||
               lowerStatus.contains('cancelled') ||
               lowerStatus.contains('rejected') ||
               lowerStatus.contains('expired')) {
      return Colors.red;
    }
    return Colors.grey;
  }

  Color _getTransactionColor(String transactionType) {
    if (transactionType == 'BUY') {
      return Colors.green;
    } else if (transactionType == 'SELL') {
      return Colors.red;
    }
    return Colors.grey;
  }

  Future<void> _reorderOrder(dynamic order) async {
    final symbol = _getSymbol(order);
    final segment = _getSegment(order) ?? 'nse_fo';
    final quantity = _getQuantity(order);
    final price = _getPriceValue(order);
    
    if (symbol == 'N/A' || symbol.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot reorder: Symbol not found in order data'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Show loading dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      // Determine search filter based on segment
      ScripSearchFilter filter = ScripSearchFilter.all;
      if (segment.toLowerCase().contains('_fo')) {
        filter = ScripSearchFilter.fno;
      } else if (segment.toLowerCase().contains('_cm')) {
        filter = ScripSearchFilter.stocks;
      }

      // Try multiple search strategies with optimized limits for speed:
      // 1. First try by default field (pScripRefKey for F&O, pDesc for CM) - limit 3 for speed
      List<ScripSearchHit> searchResults = await _scripSearchService.search(
        symbol,
        limit: 3, // Lower limit for faster search
        filter: filter,
      );

      // 2. If no results, try searching by trading symbol (pTrdSymbol) - limit 3 for speed
      if (searchResults.isEmpty) {
        searchResults = await _scripSearchService.searchByTradingSymbol(
          symbol,
          limit: 3, // Lower limit for faster search
          filter: filter,
        );
      }

      // 3. If still no results and it's F&O, try searching without filter (all segments) - limit 3 for speed
      if (searchResults.isEmpty && segment.toLowerCase().contains('_fo')) {
        searchResults = await _scripSearchService.searchByTradingSymbol(
          symbol,
          limit: 3, // Lower limit for faster search
          filter: ScripSearchFilter.all,
        );
      }

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      if (searchResults.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Symbol "$symbol" not found in scrip master. Tried searching by pScripRefKey and pTrdSymbol.'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }

      // Use the first matching result
      final selectedHit = searchResults.first;

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TakePositionScreen(
            hit: selectedHit,
            initialQuantity: quantity != '0' ? quantity : null,
            initialPrice: price,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog if still open
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error searching for symbol: ${error.toString()}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadOrders,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Builder(
        builder: (context) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _loadOrders,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_orders.isEmpty) {
      return Builder(
        builder: (context) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.inbox_outlined, size: 64, color: Colors.white70),
              const SizedBox(height: 16),
              Text(
                'No orders found',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Your order book is empty',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadOrders,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadOrders,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _orders.length,
        itemBuilder: (context, index) {
          final order = _orders[index];
          final status = _getOrderStatus(order);
          final symbol = _getSymbol(order);
          final transactionType = _getTransactionType(order);
          final quantity = _getQuantity(order);
          final price = _getPrice(order);
          final avgPrice = _getAveragePrice(order);
          final filledQty = _getFilledQuantity(order);
          final pendingQty = _getPendingQuantity(order);
          final cancelledQty = _getCancelledQuantity(order);
          final rejectionReason = _getRejectionReason(order);
          final exchangeOrderId = _getExchangeOrderId(order);
          final orderDateTime = _getOrderDateTime(order);
          final exchangeConfirmTime = _getExchangeConfirmTime(order);
          final updateTime = _getUpdateTime(order);
          final product = _getProduct(order);
          final orderType = _getOrderType(order);
          final orderId = _getOrderId(order);

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              onTap: () {
                // Show order details
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Order Details'),
                    content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildDetailRow('Order ID', orderId),
                          if (exchangeOrderId != null)
                            _buildDetailRow('Exchange Order ID', exchangeOrderId),
                          _buildDetailRow('Symbol', symbol),
                          _buildDetailRow('Transaction', transactionType),
                          _buildDetailRow('Quantity', quantity),
                          if (filledQty != null)
                            _buildDetailRow('Filled Qty', filledQty),
                          if (pendingQty != null)
                            _buildDetailRow('Pending Qty', pendingQty),
                          if (cancelledQty != null)
                            _buildDetailRow('Cancelled Qty', cancelledQty),
                          _buildDetailRow('Order Price', price),
                          if (avgPrice != null)
                            _buildDetailRow('Avg Exec Price', avgPrice),
                          _buildDetailRow('Product', product),
                          _buildDetailRow('Order Type', orderType),
                          _buildDetailRow('Status', status),
                          if (orderDateTime != null)
                            _buildDetailRow('Order Time', orderDateTime),
                          if (exchangeConfirmTime != null)
                            _buildDetailRow('Exchange Confirm Time', exchangeConfirmTime),
                          if (updateTime != null)
                            _buildDetailRow('Update Time', updateTime),
                          if (rejectionReason != null)
                            _buildDetailRow('Rejection Reason', rejectionReason),
                          const SizedBox(height: 16),
                          const Text(
                            'All Fields:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          if (order is Map)
                            ...order.entries.map((entry) => _buildDetailRow(
                                  entry.key.toString(),
                                  entry.value?.toString() ?? 'null',
                                )),
                          const SizedBox(height: 16),
                          const Text(
                            'Full Order Data (JSON):',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              order is Map
                                  ? const JsonEncoder.withIndent('  ').convert(order)
                                  : order.toString(),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context); // Close details dialog
                          _reorderOrder(order);
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reorder'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            symbol,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _getStatusColor(status).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _getStatusColor(status),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            status.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: _getStatusColor(status),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _getTransactionColor(transactionType)
                                .withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            transactionType,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _getTransactionColor(transactionType),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$quantity @ $price',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                    if (filledQty != null || pendingQty != null || avgPrice != null || cancelledQty != null) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (filledQty != null && filledQty != '0')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Filled: $filledQty',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.green,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (pendingQty != null && pendingQty != '0')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Pending: $pendingQty',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (cancelledQty != null && cancelledQty != '0')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Cancelled: $cancelledQty',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.red,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (avgPrice != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Avg: $avgPrice',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.blue,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (rejectionReason != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.red.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.error_outline, size: 16, color: Colors.red),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    rejectionReason,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.red,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (updateTime != null) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const SizedBox(width: 24), // Align with text
                                  Icon(Icons.access_time, size: 12, color: Colors.red.withOpacity(0.7)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Time: $updateTime',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.red.withOpacity(0.8),
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    if (updateTime != null && rejectionReason == null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.access_time, size: 12, color: Colors.white60),
                          const SizedBox(width: 4),
                          Text(
                            updateTime,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Product: $product',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          'Type: $orderType',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Order ID: $orderId',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
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
}

