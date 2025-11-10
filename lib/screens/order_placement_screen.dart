import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/order_request.dart';
import '../models/credentials.dart';
import '../services/credentials_service.dart';
import '../services/kotak_api_service.dart';
import 'credentials_screen.dart';

class OrderPlacementScreen extends StatefulWidget {
  const OrderPlacementScreen({super.key});

  @override
  State<OrderPlacementScreen> createState() => _OrderPlacementScreenState();
}

class _OrderPlacementScreenState extends State<OrderPlacementScreen> {
  final _formKey = GlobalKey<FormState>();
  final _segmentController = TextEditingController(text: 'nse_fo');
  final _symbolController = TextEditingController();
  final _quantityController = TextEditingController();
  final _priceController = TextEditingController();
  final _tagController = TextEditingController();
  
  String _transactionType = 'B'; // B or S
  String _product = 'MIS'; // MIS, NRML, CNC
  String _orderType = 'MKT'; // L, MKT, SL, SL-M
  
  final _credentialsService = CredentialsService();
  final _apiService = KotakApiService();
  bool _isLoading = false;
  bool _isDryRun = true;

  final List<String> _segments = [
    'nse_cm',
    'bse_cm',
    'nse_fo',
    'bse_fo',
    'cde_fo',
    'bcs-fo',
    'mcx',
  ];

  final List<String> _products = ['MIS', 'NRML', 'CNC', 'CO', 'BO'];
  final List<String> _orderTypes = ['MKT', 'L', 'SL', 'SL-M'];

  @override
  void dispose() {
    _segmentController.dispose();
    _symbolController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_orderType == 'L' && _priceController.text.isEmpty) {
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
    });

    try {
      final credentials = await _credentialsService.getCredentials();
      if (credentials == null || !credentials.isValid) {
        throw Exception('Please configure credentials first');
      }

      // Generate unique tag for each order to ensure it's treated as new
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final random = Random().nextInt(10000);
      final uniqueTag = _tagController.text.trim().isEmpty
          ? 'MOBILE_APP_${timestamp}_$random'
          : '${_tagController.text.trim()}_${timestamp}_$random';

      final orderRequest = OrderRequest(
        segment: _segmentController.text.trim(),
        symbol: _symbolController.text.trim().toUpperCase(),
        transactionType: _transactionType,
        product: _product,
        orderType: _orderType,
        quantity: int.parse(_quantityController.text.trim()),
        price: _priceController.text.isNotEmpty
            ? double.parse(_priceController.text.trim())
            : null,
        tag: uniqueTag,
      );

      if (_isDryRun) {
        // Show preview
        if (mounted) {
          _showOrderPreview(orderRequest);
        }
      } else {
        // Execute order
        final result = await _apiService.executeOrderPlacement(
          credentials,
          orderRequest,
        );

        if (mounted) {
          _showOrderResult(result);
        }
      }
    } catch (e) {
      if (mounted) {
        // Extract a cleaner error message
        String errorMessage = e.toString();
        if (errorMessage.contains('Exception: ')) {
          errorMessage = errorMessage.replaceFirst('Exception: ', '');
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showOrderPreview(OrderRequest orderRequest) {
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
              _buildPreviewRow('Symbol', orderRequest.symbol),
              _buildPreviewRow('Transaction', orderRequest.transactionType == 'B' ? 'BUY' : 'SELL'),
              _buildPreviewRow('Product', orderRequest.product),
              _buildPreviewRow('Order Type', orderRequest.orderType),
              _buildPreviewRow('Quantity', orderRequest.quantity.toString()),
              if (orderRequest.price != null)
                _buildPreviewRow('Price', orderRequest.price!.toStringAsFixed(2)),
              if (orderRequest.tag != null)
                _buildPreviewRow('Tag', orderRequest.tag!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _isDryRun = false;
              });
              _placeOrder();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Place Order'),
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

  void _showOrderResult(Map<String, dynamic> result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Order Result'),
        content: SingleChildScrollView(
          child: Text(
            result.toString(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Place Order'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CredentialsScreen(),
                ),
              );
              if (result == true) {
                // Credentials updated
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: _isDryRun ? Colors.orange.shade50 : Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(
                        _isDryRun ? Icons.warning : Icons.check_circle,
                        color: _isDryRun ? Colors.orange : Colors.green,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _isDryRun
                              ? 'DRY RUN MODE - Preview only'
                              : 'LIVE MODE - Orders will be placed',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _isDryRun ? Colors.orange.shade900 : Colors.green.shade900,
                          ),
                        ),
                      ),
                      Switch(
                        value: !_isDryRun,
                        onChanged: (value) {
                          setState(() {
                            _isDryRun = !value;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _segmentController.text,
                decoration: const InputDecoration(
                  labelText: 'Exchange Segment *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: _segments.map((segment) {
                  return DropdownMenuItem(
                    value: segment,
                    child: Text(segment.toUpperCase()),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _segmentController.text = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _symbolController,
                decoration: const InputDecoration(
                  labelText: 'Trading Symbol *',
                  hintText: 'e.g., NIFTY25NOVFUT, NIFTY04NOV2525700.00PE',
                  helperText: 'Enter exact symbol from exchange. For options: INDEX+DDMMMYY+STRIKE+CE/PE',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.tag),
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter trading symbol';
                  }
                  // Basic format check - ensure it's not just whitespace
                  if (value.trim().isEmpty) {
                    return 'Please enter a valid trading symbol';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('BUY'),
                      value: 'B',
                      groupValue: _transactionType,
                      onChanged: (value) {
                        setState(() {
                          _transactionType = value!;
                        });
                      },
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('SELL'),
                      value: 'S',
                      groupValue: _transactionType,
                      onChanged: (value) {
                        setState(() {
                          _transactionType = value!;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _product,
                decoration: const InputDecoration(
                  labelText: 'Product *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.category),
                ),
                items: _products.map((product) {
                  return DropdownMenuItem(
                    value: product,
                    child: Text(product),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _product = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _orderType,
                decoration: const InputDecoration(
                  labelText: 'Order Type *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.list),
                ),
                items: _orderTypes.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(type),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _orderType = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantityController,
                decoration: const InputDecoration(
                  labelText: 'Quantity *',
                  hintText: 'Enter quantity',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.numbers),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter quantity';
                  }
                  if (int.tryParse(value) == null || int.parse(value) <= 0) {
                    return 'Please enter a valid quantity';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _priceController,
                decoration: InputDecoration(
                  labelText: _orderType == 'L' ? 'Price *' : 'Price (Optional)',
                  hintText: 'Enter price',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.currency_rupee),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                ],
                validator: (value) {
                  if (_orderType == 'L') {
                    if (value == null || value.isEmpty) {
                      return 'Price is required for Limit orders';
                    }
                    if (double.tryParse(value) == null || double.parse(value) <= 0) {
                      return 'Please enter a valid price';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _tagController,
                decoration: const InputDecoration(
                  labelText: 'Tag (Optional)',
                  hintText: 'Custom tag for order',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label),
                ),
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _isLoading ? null : _placeOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isDryRun ? Colors.orange : Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text(
                        _isDryRun ? 'Preview Order' : 'Place Order',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

