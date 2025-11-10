class Credentials {
  final String consumerKey;
  final String mobileNumber;
  final String mpin;
  final String ucc;
  final String totpSecret;
  final String? neoFinKey;

  Credentials({
    required this.consumerKey,
    required this.mobileNumber,
    required this.mpin,
    required this.ucc,
    required this.totpSecret,
    this.neoFinKey,
  });

  bool get isValid {
    return consumerKey.isNotEmpty &&
        mobileNumber.isNotEmpty &&
        mpin.isNotEmpty &&
        ucc.isNotEmpty &&
        totpSecret.isNotEmpty;
  }

  Map<String, dynamic> toJson() {
    return {
      'consumerKey': consumerKey,
      'mobileNumber': mobileNumber,
      'mpin': mpin,
      'ucc': ucc,
      'totpSecret': totpSecret,
      'neoFinKey': neoFinKey ?? 'neotradeapi',
    };
  }

  factory Credentials.fromJson(Map<String, dynamic> json) {
    return Credentials(
      consumerKey: json['consumerKey'] ?? '',
      mobileNumber: json['mobileNumber'] ?? '',
      mpin: json['mpin'] ?? '',
      ucc: json['ucc'] ?? '',
      totpSecret: json['totpSecret'] ?? '',
      neoFinKey: json['neoFinKey'] ?? 'neotradeapi',
    );
  }
}

