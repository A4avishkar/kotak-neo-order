class OrderRequest {
  final String segment;
  final String symbol;
  final String transactionType; // B or S
  final String product; // MIS, NRML, CNC, etc.
  final String orderType; // L, MKT, SL, SL-M
  final int quantity;
  final double? price;
  final String? tag;

  OrderRequest({
    required this.segment,
    required this.symbol,
    required this.transactionType,
    required this.product,
    required this.orderType,
    required this.quantity,
    this.price,
    this.tag,
  });

  Map<String, dynamic> toJson() {
    return {
      'segment': segment,
      'symbol': symbol,
      'transactionType': transactionType,
      'product': product,
      'orderType': orderType,
      'quantity': quantity,
      'price': price,
      'tag': tag,
    };
  }
}

