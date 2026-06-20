import 'dart:convert';

class SenderEndpoint {
  const SenderEndpoint({
    required this.name,
    required this.host,
    required this.port,
    required this.token,
  });

  final String name;
  final String host;
  final int port;
  final String token;

  Uri get manifestUri => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: '/manifest',
        queryParameters: {'token': token},
      );

  Uri fileUri(String fileId) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: '/files/$fileId',
        queryParameters: {'token': token},
      );

  String encodeQrPayload() => jsonEncode({
        'v': 1,
        'name': name,
        'host': host,
        'port': port,
        'token': token,
      });

  factory SenderEndpoint.fromQrPayload(String payload) {
    final json = jsonDecode(payload) as Map<String, Object?>;
    if (json['v'] != 1) {
      throw const FormatException('Unsupported QR payload version.');
    }
    return SenderEndpoint(
      name: json['name']! as String,
      host: json['host']! as String,
      port: json['port']! as int,
      token: json['token']! as String,
    );
  }
}
