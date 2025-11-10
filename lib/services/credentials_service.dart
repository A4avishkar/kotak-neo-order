import 'package:shared_preferences/shared_preferences.dart';
import '../models/credentials.dart';

class CredentialsService {
  static const String _keyCredentials = 'kotak_credentials';
  static const String _keyConsumerKey = 'consumer_key';
  static const String _keyMobileNumber = 'mobile_number';
  static const String _keyMpin = 'mpin';
  static const String _keyUcc = 'ucc';
  static const String _keyTotpSecret = 'totp_secret';
  static const String _keyNeoFinKey = 'neo_fin_key';

  Future<void> saveCredentials(Credentials credentials) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyConsumerKey, credentials.consumerKey);
    await prefs.setString(_keyMobileNumber, credentials.mobileNumber);
    await prefs.setString(_keyMpin, credentials.mpin);
    await prefs.setString(_keyUcc, credentials.ucc);
    await prefs.setString(_keyTotpSecret, credentials.totpSecret);
    if (credentials.neoFinKey != null) {
      await prefs.setString(_keyNeoFinKey, credentials.neoFinKey!);
    }
  }

  Future<Credentials?> getCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final consumerKey = prefs.getString(_keyConsumerKey);
    final mobileNumber = prefs.getString(_keyMobileNumber);
    final mpin = prefs.getString(_keyMpin);
    final ucc = prefs.getString(_keyUcc);
    final totpSecret = prefs.getString(_keyTotpSecret);
    final neoFinKey = prefs.getString(_keyNeoFinKey);

    if (consumerKey == null ||
        mobileNumber == null ||
        mpin == null ||
        ucc == null ||
        totpSecret == null) {
      return null;
    }

    return Credentials(
      consumerKey: consumerKey,
      mobileNumber: mobileNumber,
      mpin: mpin,
      ucc: ucc,
      totpSecret: totpSecret,
      neoFinKey: neoFinKey,
    );
  }

  Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyConsumerKey);
    await prefs.remove(_keyMobileNumber);
    await prefs.remove(_keyMpin);
    await prefs.remove(_keyUcc);
    await prefs.remove(_keyTotpSecret);
    await prefs.remove(_keyNeoFinKey);
  }

  Future<bool> hasCredentials() async {
    final creds = await getCredentials();
    return creds != null && creds.isValid;
  }
}

