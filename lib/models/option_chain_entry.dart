class OptionChainEntry {
  final double strike;
  final String expiry;
  final OptionData? ce;
  final OptionData? pe;

  OptionChainEntry({
    required this.strike,
    required this.expiry,
    this.ce,
    this.pe,
  });
}

class OptionData {
  final String token;
  final String symbol;
  final String scripRefKey;
  final String? trdSymbol; // pTrdSymbol from CSV (correct format for order placement)
  final String optionType; // 'CE' or 'PE'
  
  // Live market data (from WebSocket)
  double? lastPrice;
  double? bid;
  double? ask;
  int? bidQty;
  int? askQty;
  double? openInterest;
  double? volume;
  double? change;
  double? changePercent;
  DateTime? lastUpdate;

  OptionData({
    required this.token,
    required this.symbol,
    required this.scripRefKey,
    this.trdSymbol,
    required this.optionType,
    this.lastPrice,
    this.bid,
    this.ask,
    this.bidQty,
    this.askQty,
    this.openInterest,
    this.volume,
    this.change,
    this.changePercent,
    this.lastUpdate,
  });

  OptionData copyWith({
    double? lastPrice,
    double? bid,
    double? ask,
    int? bidQty,
    int? askQty,
    double? openInterest,
    double? volume,
    double? change,
    double? changePercent,
    DateTime? lastUpdate,
  }) {
    return OptionData(
      token: token,
      symbol: symbol,
      scripRefKey: scripRefKey,
      trdSymbol: trdSymbol,
      optionType: optionType,
      lastPrice: lastPrice ?? this.lastPrice,
      bid: bid ?? this.bid,
      ask: ask ?? this.ask,
      bidQty: bidQty ?? this.bidQty,
      askQty: askQty ?? this.askQty,
      openInterest: openInterest ?? this.openInterest,
      volume: volume ?? this.volume,
      change: change ?? this.change,
      changePercent: changePercent ?? this.changePercent,
      lastUpdate: lastUpdate ?? this.lastUpdate,
    );
  }
}

