import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:nsd/nsd.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/sender_endpoint.dart';
import '../models/transfer_file.dart';
import 'hash_service.dart';
import 'local_ip_service.dart';

class SenderSession {
  const SenderSession({
    required this.endpoint,
    required this.manifest,
  });

  final SenderEndpoint endpoint;
  final TransferManifest manifest;
}

class SenderService {
  SenderService({
    HashService hashService = const HashService(),
    LocalIpService localIpService = const LocalIpService(),
  })  : _hashService = hashService,
        _localIpService = localIpService;

  static const serviceType = '_http._tcp';

  final HashService _hashService;
  final LocalIpService _localIpService;

  HttpServer? _server;
  Registration? _registration;
  SenderSession? _session;

  SenderSession? get session => _session;

  Future<SenderSession> start(List<PlatformFile> pickedFiles) async {
    await stop();
    final files = await _prepareFiles(pickedFiles);
    if (files.isEmpty) {
      throw StateError('Pick at least one readable file.');
    }

    final token = _hashService.token();
    final sessionId = _hashService.token();
    final deviceName = 'OpenShare ${DateTime.now().millisecondsSinceEpoch}';
    final manifest = TransferManifest(
      deviceName: deviceName,
      sessionId: sessionId,
      files: files,
    );

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler((request) => _handleRequest(request, token, manifest));

    _server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      0,
      shared: true,
    );

    final host = await _localIpService.bestAddress();
    final endpoint = SenderEndpoint(
      name: deviceName,
      host: host,
      port: _server!.port,
      token: token,
    );

    _registration = await register(Service(
      name: deviceName,
      type: serviceType,
      host: host,
      port: _server!.port,
      txt: {'token': token},
    ));

    _session = SenderSession(endpoint: endpoint, manifest: manifest);
    return _session!;
  }

  Future<void> stop() async {
    final registration = _registration;
    _registration = null;
    if (registration != null) {
      await unregister(registration);
    }
    await _server?.close(force: true);
    _server = null;
    _session = null;
  }

  Future<List<TransferFile>> _prepareFiles(List<PlatformFile> picked) async {
    final files = <TransferFile>[];
    for (var index = 0; index < picked.length; index++) {
      final pickedFile = picked[index];
      final path = pickedFile.path;
      if (path == null) {
        continue;
      }
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }
      final stat = await file.stat();
      files.add(TransferFile(
        id: 'f$index-${stat.modified.microsecondsSinceEpoch}',
        name: pickedFile.name,
        size: stat.size,
        sha256: await _hashService.sha256File(file),
        path: path,
      ));
    }
    return files;
  }

  Future<Response> _handleRequest(
    Request request,
    String token,
    TransferManifest manifest,
  ) async {
    final requestToken = request.url.queryParameters['token'] ??
        request.headers[HttpHeaders.authorizationHeader]
            ?.replaceFirst('Bearer ', '');
    if (requestToken != token) {
      return Response.forbidden('Invalid transfer token.');
    }

    if (request.method == 'GET' && request.url.path == 'manifest') {
      return Response.ok(
        manifest.encode(),
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
      );
    }

    if (request.method == 'GET' && request.url.pathSegments.length == 2) {
      final isFileRequest = request.url.pathSegments.first == 'files';
      if (!isFileRequest) {
        return Response.notFound('Not found.');
      }
      final fileId = request.url.pathSegments[1];
      TransferFile? transferFile;
      for (final file in manifest.files) {
        if (file.id == fileId) {
          transferFile = file;
          break;
        }
      }
      if (transferFile == null) {
        return Response.notFound('Unknown file.');
      }
      return _serveFile(request, transferFile);
    }

    return Response.notFound('Not found.');
  }

  Future<Response> _serveFile(Request request, TransferFile transferFile) async {
    final file = File(transferFile.path);
    if (!await file.exists()) {
      return Response.notFound('File missing on sender.');
    }

    final length = await file.length();
    final rangeHeader = request.headers[HttpHeaders.rangeHeader];
    if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
      return Response.ok(
        file.openRead(),
        headers: {
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentLengthHeader: '$length',
          'content-disposition':
              'attachment; filename="${_escapeHeaderValue(transferFile.name)}"',
        },
      );
    }

    final range = rangeHeader.substring('bytes='.length).split('-');
    final start = int.tryParse(range.first) ?? 0;
    final requestedEnd = range.length > 1 ? int.tryParse(range[1]) : null;
    if (start >= length) {
      return Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {HttpHeaders.contentRangeHeader: 'bytes */$length'},
      );
    }
    final end = requestedEnd == null || requestedEnd >= length
        ? length - 1
        : requestedEnd;
    final contentLength = end - start + 1;

    return Response(
      HttpStatus.partialContent,
      body: file.openRead(start, end + 1),
      headers: {
        HttpHeaders.acceptRangesHeader: 'bytes',
        HttpHeaders.contentLengthHeader: '$contentLength',
        HttpHeaders.contentRangeHeader: 'bytes $start-$end/$length',
        'content-disposition':
            'attachment; filename="${_escapeHeaderValue(transferFile.name)}"',
      },
    );
  }

  String _escapeHeaderValue(String value) => value.replaceAll('"', r'\"');
}
