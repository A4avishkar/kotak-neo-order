import 'package:flutter/material.dart';
import '../models/credentials.dart';
import '../models/position.dart';
import '../services/credentials_service.dart';
import '../services/kotak_api_service.dart';
import '../services/market_data_service.dart';
import '../services/scrip_search_service.dart';
import 'take_position_screen.dart';

class PositionsScreen extends StatefulWidget {
  const PositionsScreen({super.key});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  final _credentialsService = CredentialsService();
  final _apiService = KotakApiService();
  final _marketDataService = MarketDataService();
  final _scripSearchService = ScripSearchService();

  List<Position>? _positions;
  bool _isLoadingPositions = false;
  String? _positionsError;

  List<dynamic>? _holdings;
  bool _isLoadingHoldings = false;
  String? _holdingsError;

  int _tabIndex = 0; // 0 = Positions, 1 = Holdings

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    if (_tabIndex == 0) {
      _loadPositions();
    } else {
      _loadHoldings();
    }
  }

  Future<void> _loadPositions() async {
    final credentials = await _credentialsService.getCredentials();
    if (credentials == null) {
      return;
    }
    setState(() {
      _isLoadingPositions = true;
      _positionsError = null;
    });
    try {
      final positions = await _marketDataService.fetchPositions(credentials);
      if (!mounted) return;
      setState(() {
        _positions = positions;
        _isLoadingPositions = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingPositions = false;
        _positionsError = _cleanErrorMessage(error.toString());
      });
    }
  }

  Future<void> _loadHoldings() async {
    final credentials = await _credentialsService.getCredentials();
    if (credentials == null || !credentials.isValid) {
      return;
    }
    setState(() {
      _isLoadingHoldings = true;
      _holdingsError = null;
    });
    try {
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
      
      setState(() {
        _holdings = holdings;
        _isLoadingHoldings = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingHoldings = false;
        _holdingsError = _cleanErrorMessage(error.toString());
      });
    }
  }

  String _cleanErrorMessage(String message) {
    return message.replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final credentials = _credentialsService.getCredentials();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Positions & Holdings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadData,
          ),
        ],
      ),
      body: FutureBuilder<Credentials?>(
        future: credentials,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: Text('Configure credentials to view positions.'));
          }

          return Column(
            children: [
              // Tabs for Positions and Holdings
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTabButton(
                        'Positions',
                        0,
                        Icons.swap_horiz,
                      ),
                    ),
                    Expanded(
                      child: _buildTabButton(
                        'Holdings',
                        1,
                        Icons.account_balance_wallet,
                      ),
                    ),
                  ],
                ),
              ),
              // Content based on selected tab
              Expanded(
                child: _tabIndex == 0
                    ? _buildPositionsList()
                    : _buildHoldingsList(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabButton(String label, int index, IconData icon) {
    final isSelected = _tabIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          _tabIndex = index;
        });
        _loadData();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1E3A8A) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: isSelected ? Colors.white : Colors.white70),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPositionsList() {
    if (_isLoadingPositions) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_positionsError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 52, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              _positionsError!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadPositions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_positions == null || _positions!.isEmpty) {
      return const Center(child: Text('No open positions found.'));
    }

    return RefreshIndicator(
      onRefresh: _loadPositions,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        cacheExtent: 500,
        itemCount: _positions!.length,
        itemBuilder: (context, index) {
          final position = _positions![index];
          final pnl = position.pnl ?? 0;
          final pnlColor =
              pnl >= 0 ? const Color(0xFF34D399) : const Color(0xFFF87171);
          return RepaintBoundary(
            child: Card(
              margin: const EdgeInsets.symmetric(vertical: 8),
              child: InkWell(
                onTap: () {
                  _showPositionDetails(position);
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
                              position.symbol,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            position.segment,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _positionChip('Product', position.product),
                          const SizedBox(width: 8),
                          _positionChip('Net Qty', position.netQty.toStringAsFixed(0)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _positionMetric('Buy Avg', position.buyAvg),
                          _positionMetric('Sell Avg', position.sellAvg),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('P&L',
                                  style: TextStyle(color: Colors.white70)),
                              const SizedBox(height: 4),
                              Text(
                                pnl.toStringAsFixed(2),
                                style: TextStyle(
                                  color: pnlColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHoldingsList() {
    if (_isLoadingHoldings) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_holdingsError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 52, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              _holdingsError!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadHoldings,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_holdings == null || _holdings!.isEmpty) {
      return const Center(child: Text('No holdings found.'));
    }

    return RefreshIndicator(
      onRefresh: _loadHoldings,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        cacheExtent: 500,
        itemCount: _holdings!.length,
        itemBuilder: (context, index) {
          final holding = _holdings![index];
          if (holding is! Map) {
            return const SizedBox.shrink();
          }
          
          // Extract fields using correct field names from Python CLI
          final symbol = (holding['displaySymbol'] ??
                         holding['instrumentName'] ??
                         holding['symbol'] ?? 
                         holding['tradingSymbol'] ?? 
                         'N/A').toString();
          
          final quantity = (holding['quantity'] ??
                           holding['qty'] ?? 
                           '0').toString();
          
          final avgPrice = (holding['averagePrice'] ??
                           holding['avgPrice'] ?? 
                           0).toString();
          
          final ltp = (holding['closingPrice'] ??
                      holding['ltp'] ?? 
                      holding['lastPrice'] ??
                      holding['mktValue'] ??
                      0).toString();
          
          final pnl = (holding['unrealisedGainLoss'] ??
                     holding['unrealizedGainLoss'] ??
                     holding['pnl'] ?? 
                     0).toString();
          
          final pnlValue = double.tryParse(pnl) ?? 0;
          final pnlColor = pnlValue >= 0 
              ? const Color(0xFF34D399) 
              : const Color(0xFFF87171);
          
          final segment = (holding['exchangeSegment'] ??
                         holding['segment'] ?? 
                         'N/A').toString();
          
          return RepaintBoundary(
            child: Card(
              margin: const EdgeInsets.symmetric(vertical: 8),
              child: InkWell(
                onTap: () {
                  _showHoldingDetails(holding, symbol, segment, quantity, avgPrice, ltp, pnl);
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
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            segment,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _positionChip('Qty', quantity),
                          const SizedBox(width: 8),
                          _positionChip('Avg Price', '₹$avgPrice'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _positionMetric('LTP', double.tryParse(ltp)),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('P&L',
                                  style: TextStyle(color: Colors.white70)),
                              const SizedBox(height: 4),
                              Text(
                                '₹${pnlValue.toStringAsFixed(2)}',
                                style: TextStyle(
                                  color: pnlColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _positionChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionMetric(String label, double? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54)),
        const SizedBox(height: 4),
        Text(
          value != null ? value.toStringAsFixed(2) : '-',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  void _showPositionDetails(Position position) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Position Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('Symbol', position.symbol),
              _buildDetailRow('Segment', position.segment),
              _buildDetailRow('Product', position.product),
              _buildDetailRow('Net Quantity', position.netQty.toStringAsFixed(0)),
              if (position.buyAvg != null)
                _buildDetailRow('Buy Avg', position.buyAvg!.toStringAsFixed(2)),
              if (position.sellAvg != null)
                _buildDetailRow('Sell Avg', position.sellAvg!.toStringAsFixed(2)),
              if (position.pnl != null)
                _buildDetailRow('P&L', position.pnl!.toStringAsFixed(2)),
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
              _reorderPosition(position);
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

  Future<void> _reorderPosition(Position position) async {
    final symbol = position.symbol;
    final segment = position.segment.toLowerCase();
    
    if (symbol.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot reorder: Symbol not found in position data'),
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
      if (segment.contains('_fo')) {
        filter = ScripSearchFilter.fno;
      } else if (segment.contains('_cm')) {
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
      if (searchResults.isEmpty && segment.contains('_fo')) {
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

      // Determine quantity and price from position
      // Use netQty as quantity (absolute value)
      final quantity = position.netQty.abs().toStringAsFixed(0);
      // Use buyAvg or sellAvg as initial price if available
      String? initialPrice;
      if (position.netQty > 0 && position.buyAvg != null) {
        // Long position - use buy avg
        initialPrice = position.buyAvg!.toStringAsFixed(2);
      } else if (position.netQty < 0 && position.sellAvg != null) {
        // Short position - use sell avg
        initialPrice = position.sellAvg!.toStringAsFixed(2);
      }

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TakePositionScreen(
            hit: selectedHit,
            initialQuantity: quantity != '0' ? quantity : null,
            initialPrice: initialPrice,
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

  void _showHoldingDetails(
    dynamic holding,
    String symbol,
    String segment,
    String quantity,
    String avgPrice,
    String ltp,
    String pnl,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Holding Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('Symbol', symbol),
              _buildDetailRow('Segment', segment),
              _buildDetailRow('Quantity', quantity),
              _buildDetailRow('Avg Price', '₹$avgPrice'),
              _buildDetailRow('LTP', '₹$ltp'),
              _buildDetailRow('P&L', '₹$pnl'),
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
              _reorderHolding(holding, symbol, segment, quantity, avgPrice);
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
  }

  Future<void> _reorderHolding(
    dynamic holding,
    String symbol,
    String segment,
    String quantity,
    String avgPrice,
  ) async {
    if (symbol.isEmpty || symbol == 'N/A') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot reorder: Symbol not found in holding data'),
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
      final segLower = segment.toLowerCase();
      if (segLower.contains('_fo')) {
        filter = ScripSearchFilter.fno;
      } else if (segLower.contains('_cm')) {
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
      if (searchResults.isEmpty && segLower.contains('_fo')) {
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

      // Use quantity and avgPrice from holding
      final qty = quantity != '0' ? quantity : null;
      final price = avgPrice != '0' && avgPrice.isNotEmpty ? avgPrice : null;

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TakePositionScreen(
            hit: selectedHit,
            initialQuantity: qty,
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
}

