class Position {
  const Position({
    required this.symbol,
    required this.segment,
    required this.product,
    required this.netQty,
    this.buyAvg,
    this.sellAvg,
    this.pnl,
  });

  final String symbol;
  final String segment;
  final String product;
  final double netQty;
  final double? buyAvg;
  final double? sellAvg;
  final double? pnl;
}

