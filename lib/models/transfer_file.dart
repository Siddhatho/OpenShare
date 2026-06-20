import 'dart:convert';

class TransferFile {
  const TransferFile({
    required this.id,
    required this.name,
    required this.size,
    required this.sha256,
    required this.path,
    this.mimeType,
  });

  final String id;
  final String name;
  final int size;
  final String sha256;
  final String path;
  final String? mimeType;

  Map<String, Object?> toJson({bool includePath = false}) => {
        'id': id,
        'name': name,
        'size': size,
        'sha256': sha256,
        'mimeType': mimeType,
        if (includePath) 'path': path,
      };

  factory TransferFile.fromJson(Map<String, Object?> json) => TransferFile(
        id: json['id']! as String,
        name: json['name']! as String,
        size: json['size']! as int,
        sha256: json['sha256']! as String,
        path: json['path'] as String? ?? '',
        mimeType: json['mimeType'] as String?,
      );
}

class TransferManifest {
  const TransferManifest({
    required this.deviceName,
    required this.sessionId,
    required this.files,
  });

  final String deviceName;
  final String sessionId;
  final List<TransferFile> files;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);

  Map<String, Object?> toJson() => {
        'deviceName': deviceName,
        'sessionId': sessionId,
        'totalBytes': totalBytes,
        'files': files.map((file) => file.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory TransferManifest.fromJson(Map<String, Object?> json) {
    final filesJson = json['files']! as List<Object?>;
    return TransferManifest(
      deviceName: json['deviceName']! as String,
      sessionId: json['sessionId']! as String,
      files: filesJson
          .cast<Map<String, Object?>>()
          .map(TransferFile.fromJson)
          .toList(),
    );
  }
}
