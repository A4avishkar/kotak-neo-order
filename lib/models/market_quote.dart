class MarketQuote {
  final String token;
  final double lastPrice;
  final double? closePrice;
  final double? highPrice;
  final double? lowPrice;
  final double? openPrice;
  final double? change;
  final double? changePercent;
  final double? volume;
  final double? turnover;
  final double? openInterest;
  final DateTime? timestamp;
  final bool isSnapshot;

  const MarketQuote({
    required this.token,
    required this.lastPrice,
    this.closePrice,
    this.highPrice,
    this.lowPrice,
    this.openPrice,
    this.change,
    this.changePercent,
    this.volume,
    this.turnover,
    this.openInterest,
    this.timestamp,
    this.isSnapshot = false,
  });

  bool get isMarketOpen => !isSnapshot;
}
