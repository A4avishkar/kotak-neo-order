import '../services/scrip_search_service.dart';

class WatchlistEntry {
  const WatchlistEntry({
    required this.id,
    required this.segmentCode,
    required this.segmentName,
    required this.primaryField,
    required this.primaryValue,
    this.secondaryValue,
    required this.metadata,
  });

  factory WatchlistEntry.fromHit(ScripSearchHit hit) {
    final id = '${hit.segmentCode}|${hit.primaryValue}'.toLowerCase();
    return WatchlistEntry(
      id: id,
      segmentCode: hit.segmentCode,
      segmentName: hit.segmentName,
      primaryField: hit.primaryField,
      primaryValue: hit.primaryValue,
      secondaryValue: hit.secondaryValue,
      metadata: Map<String, String>.from(hit.metadata),
    );
  }

  factory WatchlistEntry.fromJson(Map<String, dynamic> json) {
    final metadata = <String, String>{};
    final rawMetadata = json['metadata'] as Map<String, dynamic>? ?? {};
    for (final entry in rawMetadata.entries) {
      metadata[entry.key] = entry.value?.toString() ?? '';
    }
    return WatchlistEntry(
      id: json['id'] as String,
      segmentCode: json['segmentCode'] as String,
      segmentName: json['segmentName'] as String,
      primaryField: json['primaryField'] as String,
      primaryValue: json['primaryValue'] as String,
      secondaryValue: json['secondaryValue'] as String?,
      metadata: metadata,
    );
  }

  final String id;
  final String segmentCode;
  final String segmentName;
  final String primaryField;
  final String primaryValue;
  final String? secondaryValue;
  final Map<String, String> metadata;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'segmentCode': segmentCode,
      'segmentName': segmentName,
      'primaryField': primaryField,
      'primaryValue': primaryValue,
      'secondaryValue': secondaryValue,
      'metadata': metadata,
    };
  }

  ScripSearchHit toHit() {
    return ScripSearchHit(
      segmentCode: segmentCode,
      segmentName: segmentName,
      primaryField: primaryField,
      primaryValue: primaryValue,
      metadata: metadata,
    );
  }
}

