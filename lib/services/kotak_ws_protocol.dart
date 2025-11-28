import 'dart:convert';
import 'dart:typed_data';

typedef VoidCallback = void Function();

class FieldTypes {
  static const int float32 = 1;
  static const int long = 2;
  static const int date = 3;
  static const int string = 4;
}

class RespTypeValues {
  static const String conn = 'cn';
  static const String subs = 'sub';
  static const String unsub = 'unsub';
  static const String snap = 'snap';
  static const String channelR = 'cr';
  static const String channelP = 'cp';
  static const String opc = 'opc';
}

class BinRespTypes {
  static const int connection = 1;
  static const int throttling = 2;
  static const int ack = 3;
  static const int subscribe = 4;
  static const int unsubscribe = 5;
  static const int data = 6;
  static const int chPause = 7;
  static const int chResume = 8;
  static const int snapshot = 9;
  static const int opcSubscribe = 10;
}

class ResponseTypes {
  static const int snap = 83;
  static const int update = 85;
}

class BinRespStat {
  static const String ok = 'K';
  static const String notOk = 'N';
}

class RespCodes {
  static const int success = 200;
  static const int connectionFailed = 11001;
  static const int connectionInvalid = 11002;
  static const int subscriptionFailed = 11011;
  static const int unsubscriptionFailed = 11012;
  static const int snapshotFailed = 11013;
  static const int channelPauseFailed = 11031;
  static const int channelResumeFailed = 11032;
}

class TopicTypes {
  static const String scrip = 'sf';
  static const String index = 'if';
  static const String depth = 'dp';
}

const Map<String, int> stringIndex = {
  'NAME': 51,
  'SYMBOL': 52,
  'EXCHG': 53,
  'TSYMBOL': 54,
};

const Map<String, int> indexIndex = {
  'LTP': 2,
  'CLOSE': 3,
  'CHANGE': 10,
  'PERCHANGE': 11,
  'MULTIPLIER': 8,
  'PRECISION': 9,
};

class DataType {
  DataType(this.name, this.type);
  final String name;
  final int? type;
}

List<DataType?> _buildIndexMapping() {
  final mapping = List<DataType?>.filled(55, null);
  mapping[0] = DataType('ftm0', FieldTypes.date);
  mapping[1] = DataType('dtm1', FieldTypes.date);
  mapping[indexIndex['LTP']!] = DataType('iv', FieldTypes.float32);
  mapping[indexIndex['CLOSE']!] = DataType('ic', FieldTypes.float32);
  mapping[4] = DataType('tvalue', FieldTypes.date);
  mapping[5] = DataType('highPrice', FieldTypes.float32);
  mapping[6] = DataType('lowPrice', FieldTypes.float32);
  mapping[7] = DataType('openingPrice', FieldTypes.float32);
  mapping.add(DataType('mul', FieldTypes.long));
  mapping[indexIndex['PRECISION']!] = DataType('prec', FieldTypes.long);
  mapping[indexIndex['CHANGE']!] = DataType('cng', FieldTypes.float32);
  mapping[indexIndex['PERCHANGE']!] = DataType('nc', FieldTypes.string);
  mapping[stringIndex['NAME']!] = DataType('name', FieldTypes.string);
  mapping[stringIndex['SYMBOL']!] = DataType('tk', FieldTypes.string);
  mapping[stringIndex['EXCHG']!] = DataType('e', FieldTypes.string);
  mapping[stringIndex['TSYMBOL']!] = DataType('ts', FieldTypes.string);
  return mapping;
}

final List<DataType?> indexMapping = _buildIndexMapping();

class BinaryMessageBuilder {
  BinaryMessageBuilder(int length)
    : _buffer = Uint8List(length),
      _byteData = ByteData(length);

  final Uint8List _buffer;
  final ByteData _byteData;
  int _pos = 0;
  int? _msgStart;

  void markStart() {
    _msgStart = _pos;
    _pos += 2;
  }

  void markEnd() {
    final start = _msgStart;
    if (start == null) return;
    final len = _pos - start - 2;
    _byteData.setUint8(start, (len >> 8) & 0xFF);
    _byteData.setUint8(start + 1, len & 0xFF);
  }

  void appendByte(int value) {
    _byteData.setUint8(_pos, value & 0xFF);
    _pos += 1;
  }

  void appendShort(int value) {
    _byteData.setUint8(_pos, (value >> 8) & 0xFF);
    _byteData.setUint8(_pos + 1, value & 0xFF);
    _pos += 2;
  }

  void appendInt(int value) {
    _byteData.setUint32(_pos, value, Endian.big);
    _pos += 4;
  }

  void appendString(String value) {
    final bytes = utf8.encode(value);
    for (final byte in bytes) {
      appendByte(byte);
    }
  }

  void appendBytes(List<int> bytes) {
    for (final byte in bytes) {
      appendByte(byte);
    }
  }

  Uint8List toBytes() => _buffer.sublist(0, _pos);
}

Uint8List prepareConnectionRequest(String token, String sid) {
  final source = 'JS_API';
  final buffer = BinaryMessageBuilder(
    source.length + token.length + sid.length + 13,
  );
  buffer.markStart();
  buffer.appendByte(BinRespTypes.connection);
  buffer.appendByte(3);
  buffer.appendByte(1);
  buffer.appendShort(token.length);
  buffer.appendString(token);
  buffer.appendByte(2);
  buffer.appendShort(sid.length);
  buffer.appendString(sid);
  buffer.appendByte(3);
  buffer.appendShort(source.length);
  buffer.appendString(source);
  buffer.markEnd();
  return buffer.toBytes();
}

List<int> _getScripByteArray(String scrip, String prefix) {
  final entries = scrip.split('&').where((s) => s.isNotEmpty).toList();
  final StringBuffer sb = StringBuffer();
  for (var i = 0; i < entries.length; i++) {
    entries[i] = '$prefix|${entries[i]}';
    sb.write(entries[i]);
    if (i != entries.length - 1) {
      sb.write('\u0001');
    }
  }

  int totalLength = 2;
  for (final entry in entries) {
    totalLength += 1 + entry.length;
  }

  final bytes = List<int>.filled(totalLength, 0);
  var pos = 0;
  bytes[pos++] = (entries.length >> 8) & 0xFF;
  bytes[pos++] = entries.length & 0xFF;
  for (final entry in entries) {
    bytes[pos++] = entry.length & 0xFF;
    for (final rune in entry.codeUnits) {
      bytes[pos++] = rune;
    }
  }
  return bytes;
}

Uint8List prepareSubscribeRequest(
  String scrip,
  int subscribeType,
  String prefix,
  int channel,
) {
  final data = _getScripByteArray(scrip, prefix);
  final buffer = BinaryMessageBuilder(data.length + 11);
  buffer.markStart();
  buffer.appendByte(subscribeType);
  buffer.appendByte(2);
  buffer.appendByte(1);
  buffer.appendShort(data.length);
  buffer.appendBytes(data);
  buffer.appendByte(2);
  buffer.appendShort(1);
  buffer.appendByte(channel);
  buffer.markEnd();
  return buffer.toBytes();
}

Uint8List buildAckRequest(int messageNumber) {
  final buffer = BinaryMessageBuilder(11);
  buffer.markStart();
  buffer.appendByte(BinRespTypes.ack);
  buffer.appendByte(1);
  buffer.appendByte(1);
  buffer.appendShort(4);
  buffer.appendInt(messageNumber);
  buffer.markEnd();
  return buffer.toBytes();
}

class TopicData {
  TopicData(this.feedType)
    : fieldData = List<dynamic>.filled(100, null),
      updatedFields = List<bool?>.filled(100, null) {
    fieldData[stringIndex['NAME']!] = feedType;
  }

  final String feedType;
  final List<dynamic> fieldData;
  final List<bool?> updatedFields;

  void setLongValue(int index, int value) {
    if (fieldData[index] != value) {
      fieldData[index] = value;
      updatedFields[index] = true;
    }
  }

  void setStringValue(int index, String value) {
    fieldData[index] = value;
    updatedFields[index] = true;
  }

  Map<String, dynamic> prepareCommonJson() {
    final Map<String, dynamic> json = {};
    final name = fieldData[stringIndex['NAME']!];
    final symbol = fieldData[stringIndex['SYMBOL']!];
    final exch = fieldData[stringIndex['EXCHG']!];
    if (name != null) json['name'] = name;
    if (symbol != null) json['tk'] = symbol;
    if (exch != null) json['e'] = exch;
    return json;
  }
}

class IndexTopicData extends TopicData {
  IndexTopicData()
    : precision = 0,
      precisionValue = 1,
      multiplier = 1,
      super(TopicTypes.index);

  int precision;
  int precisionValue;
  int multiplier;

  void setMultiplierAndPrecision() {
    if (updatedFields[indexIndex['PRECISION']!] == true) {
      precision = (fieldData[indexIndex['PRECISION']!] ?? 0) as int;
      precisionValue = pow10(precision);
    }
    if (updatedFields[indexIndex['MULTIPLIER']!] == true) {
      multiplier = (fieldData[indexIndex['MULTIPLIER']!] ?? 1) as int;
    }
  }

  Map<String, dynamic> prepareJson(String type) {
    if (updatedFields[indexIndex['LTP']!] == true ||
        updatedFields[indexIndex['CLOSE']!] == true) {
      final ltp = fieldData[indexIndex['LTP']!];
      final close = fieldData[indexIndex['CLOSE']!];
      if (ltp != null && close != null) {
        final change = (ltp as num) - (close as num);
        fieldData[indexIndex['CHANGE']!] = change;
        updatedFields[indexIndex['CHANGE']!] = true;
        final percent = (change / close) * 100.0;
        fieldData[indexIndex['PERCHANGE']!] = percent;
        updatedFields[indexIndex['PERCHANGE']!] = true;
      }
    }
    final json = prepareCommonJson();
    for (var i = 0; i < indexMapping.length; i++) {
      final dataType = indexMapping[i];
      if (dataType == null || updatedFields[i] != true) continue;
      var value = fieldData[i];
      if (value == null) continue;
      if (dataType.type == FieldTypes.float32) {
        value = (value as num) / (multiplier * precisionValue);
        value = double.parse(value.toStringAsFixed(precision));
      } else if (dataType.type == FieldTypes.date) {
        value = _formatTimestamp(value as int);
      }
      json[dataType.name] = value;
    }
    updatedFields.fillRange(0, updatedFields.length, null);
    json['request_type'] = type;
    return json;
  }
}

String _formatTimestamp(int seconds) {
  final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  return dt.toIso8601String();
}

int pow10(int power) {
  var value = 1;
  for (var i = 0; i < power; i++) {
    value *= 10;
  }
  return value;
}

class HSWrapper {
  HSWrapper({
    void Function(Uint8List bytes)? onAck,
    VoidCallback? onConnectionAck,
  }) : _onAck = onAck,
       _onConnectionAck = onConnectionAck;

  final Map<int, TopicData> topicList = {};
  final void Function(Uint8List bytes)? _onAck;
  final VoidCallback? _onConnectionAck;
  int ackNum = 0;
  int counter = 0;

  List<Map<String, dynamic>> parse(Uint8List message) {
    final List<Map<String, dynamic>> results = [];
    var pos = 0;
    if (message.length < 3) {
      return results;
    }

    final packetsCount = _bufToInt(message, pos, 2);
    pos += 2;
    if (packetsCount <= 0) {
      return results;
    }

    final type = message[pos];
    pos += 1;

    if (type == BinRespTypes.connection) {
      _handleConnectionAck(message, pos);
      return results;
    } else if (type == BinRespTypes.data) {
      if (ackNum > 0 && message.length >= pos + 4) {
        counter++;
        final msgNum = _bufToInt(message, pos, 4);
        pos += 4;
        if (counter == ackNum) {
          counter = 0;
          final ackBytes = buildAckRequest(msgNum);
          _onAck?.call(ackBytes);
        }
      }

      if (message.length < pos + 2) return results;
      final g = _bufToInt(message, pos, 2);
      pos += 2;
      for (var idx = 0; idx < g; idx++) {
        if (message.length < pos + 3) break;
        pos += 2;
        final responseType = message[pos];
        pos += 1;
        if (responseType == ResponseTypes.snap) {
          final topicId = _bufToInt(message, pos, 4);
          pos += 4;
          final nameLen = message[pos];
          pos += 1 + nameLen;
          final topic = IndexTopicData();
          topicList[topicId] = topic;
          final intFieldCount = message[pos];
          pos += 1;
          for (var i = 0; i < intFieldCount; i++) {
            final value = _bufToInt(message, pos, 4);
            topic.setLongValue(i, value);
            pos += 4;
          }
          topic.setMultiplierAndPrecision();
          final strFieldCount = message[pos];
          pos += 1;
          for (var i = 0; i < strFieldCount; i++) {
            final fid = message[pos];
            pos += 1;
            final len = message[pos];
            pos += 1;
            final strValue = utf8.decode(
              message.sublist(pos, pos + len),
              allowMalformed: true,
            );
            pos += len;
            topic.setStringValue(fid, strValue);
          }
          results.add(topic.prepareJson('SNAP'));
        } else if (responseType == ResponseTypes.update) {
          final topicId = _bufToInt(message, pos, 4);
          pos += 4;
          final topic = topicList[topicId];
          if (topic == null) {
            continue;
          }
          final intFieldCount = message[pos];
          pos += 1;
          for (var i = 0; i < intFieldCount; i++) {
            final value = _bufToInt(message, pos, 4);
            topic.setLongValue(i, value);
            pos += 4;
          }
          if (topic is IndexTopicData) {
            topic.setMultiplierAndPrecision();
            results.add(topic.prepareJson('SUB'));
          }
        }
      }
    }
    return results;
  }

  void _handleConnectionAck(Uint8List message, int pos) {
    if (message.length < pos + 1) return;
    final fieldCount = message[pos];
    pos += 1;

    String? status;

    if (fieldCount >= 1) {
      if (message.length < pos + 1) return;
      pos += 1; // field id
      if (message.length < pos + 2) return;
      final len = _bufToInt(message, pos, 2);
      pos += 2;
      if (message.length < pos + len) return;
      status = utf8.decode(message.sublist(pos, pos + len));
      pos += len;
    }

    if (fieldCount >= 2) {
      if (message.length < pos + 1) return;
      pos += 1; // ack field id
      if (message.length < pos + 2) return;
      final len2 = _bufToInt(message, pos, 2);
      pos += 2;
      if (message.length < pos + len2) return;
      ackNum = _bufToInt(message, pos, len2);
    }

    if (status == null ||
        status == BinRespStat.ok ||
        status.toUpperCase() == 'OK') {
      _onConnectionAck?.call();
    }
  }
}

int _bufToInt(Uint8List buffer, int start, int length) {
  var value = 0;
  for (var i = 0; i < length; i++) {
    value = (value << 8) + buffer[start + i];
  }
  return value;
}
