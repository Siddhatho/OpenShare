import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:nsd/nsd.dart';
import 'package:path_provider/path_provider.dart';

import '../models/sender_endpoint.dart';
import '../models/transfer_file.dart';
import 'hash_service.dart';
import 'sender_service.dart';

class DiscoveredSender {
  const DiscoveredSender({
    required this.endpoint,
    required this.serviceName,
  });

  final SenderEndpoint endpoint;
  final String serviceName;
}

class DownloadProgress {
  const DownloadProgress({
    required this.file,
    required this.received,
    required this.total,
    required this.status,
    this.savedPath,
  });

  final TransferFile file;
  final int received;
  final int total;
  final DownloadStatus status;
  final String? savedPath;

  double get fraction => total == 0 ? 0 : (received / total).clamp(0, 1);
}

enum DownloadStatus {
  queued,
  downloading,
  verifying,
  retrying,
  complete,
  failed,
}

class ReceiverService {
  ReceiverService({
    Dio? dio,
    HashService hashService = const HashService(),
  })  : _dio = dio ?? Dio(),
        _hashService = hashService;

  final Dio _dio;
  final HashService _hashService;
  Discovery? _discovery;

  Future<List<DiscoveredSender>> discover({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final senders = <String, DiscoveredSender>{};
    _discovery = await startDiscovery(SenderService.serviceType);
    _discovery!.addServiceListener((service, status) {
      if (status != ServiceStatus.found) {
        return;
      }
      final host = _serviceHost(service);
      final token = service.txt?['token'];
      if (host == null || token == null || service.port == null) {
        return;
      }
      final endpoint = SenderEndpoint(
        name: service.name ?? 'OpenShare sender',
        host: host,
        port: service.port!,
        token: token,
      );
      senders['$host:${service.port}'] = DiscoveredSender(
        endpoint: endpoint,
        serviceName: service.name ?? endpoint.name,
      );
    });

    await Future<void>.delayed(timeout);
    await stopDiscoveryScan();
    return senders.values.toList();
  }

  Future<void> stopDiscoveryScan() async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      await stopDiscovery(discovery);
    }
  }

  Future<TransferManifest> fetchManifest(SenderEndpoint endpoint) async {
    final response = await _dio.getUri<String>(endpoint.manifestUri);
    final data = response.data;
    if (data == null) {
      throw StateError('Sender returned an empty manifest.');
    }
    return TransferManifest.fromJson(
      jsonDecode(data) as Map<String, Object?>,
    );
  }

  Stream<DownloadProgress> downloadAll(
    SenderEndpoint endpoint,
    TransferManifest manifest,
  ) async* {
    final baseDir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}OpenShare'
      '${Platform.pathSeparator}${_sanitize(manifest.sessionId)}',
    );
    await sessionDir.create(recursive: true);

    for (final file in manifest.files) {
      yield* _downloadWithRetry(endpoint, sessionDir, file);
    }
  }

  Stream<DownloadProgress> _downloadWithRetry(
    SenderEndpoint endpoint,
    Directory sessionDir,
    TransferFile file,
  ) async* {
    final target = File(
      '${sessionDir.path}${Platform.pathSeparator}${_sanitize(file.name)}',
    );
    Object? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        yield DownloadProgress(
          file: file,
          received: target.existsSync() ? target.lengthSync() : 0,
          total: file.size,
          status: DownloadStatus.retrying,
        );
      }

      try {
        yield* _downloadOne(endpoint, file, target);
        yield DownloadProgress(
          file: file,
          received: file.size,
          total: file.size,
          status: DownloadStatus.verifying,
          savedPath: target.path,
        );

        final actualHash = await _hashService.sha256File(target);
        if (actualHash == file.sha256) {
          yield DownloadProgress(
            file: file,
            received: file.size,
            total: file.size,
            status: DownloadStatus.complete,
            savedPath: target.path,
          );
          return;
        }

        lastError = StateError('Hash mismatch for ${file.name}.');
        if (await target.exists()) {
          await target.delete();
        }
      } catch (error) {
        lastError = error;
      }
    }

    yield DownloadProgress(
      file: file,
      received: target.existsSync() ? target.lengthSync() : 0,
      total: file.size,
      status: DownloadStatus.failed,
      savedPath: lastError?.toString(),
    );
  }

  Stream<DownloadProgress> _downloadOne(
    SenderEndpoint endpoint,
    TransferFile file,
    File target,
  ) async* {
    final partialBytes = await target.exists() ? await target.length() : 0;
    if (partialBytes >= file.size) {
      yield DownloadProgress(
        file: file,
        received: file.size,
        total: file.size,
        status: DownloadStatus.downloading,
        savedPath: target.path,
      );
      return;
    }

    final sink = target.openWrite(mode: FileMode.append);
    try {
      final response = await _dio.getUri<ResponseBody>(
        endpoint.fileUri(file.id),
        options: Options(
          responseType: ResponseType.stream,
          headers: partialBytes > 0
              ? {HttpHeaders.rangeHeader: 'bytes=$partialBytes-'}
              : null,
        ),
      );
      final stream = response.data?.stream;
      if (stream == null) {
        throw StateError('Sender returned an empty file response.');
      }
      var downloaded = partialBytes;
      await for (final chunk in stream) {
        sink.add(chunk);
        downloaded += chunk.length;
        yield DownloadProgress(
          file: file,
          received: downloaded,
          total: file.size,
          status: DownloadStatus.downloading,
          savedPath: target.path,
        );
      }
    } finally {
      await sink.close();
    }
  }

  String? _serviceHost(Service service) {
    final host = service.host;
    if (host != null && host.isNotEmpty) {
      return host;
    }
    return null;
  }

  String _sanitize(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}
