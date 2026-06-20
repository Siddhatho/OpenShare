import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'models/sender_endpoint.dart';
import 'models/transfer_file.dart';
import 'services/receiver_service.dart';
import 'services/sender_service.dart';

void main() {
  runApp(const OpenShareApp());
}

class OpenShareApp extends StatelessWidget {
  const OpenShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OpenShare',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2563eb),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _senderService = SenderService();
  final _receiverService = ReceiverService();
  final _downloads = <String, DownloadProgress>{};
  final _senders = <DiscoveredSender>[];

  SenderSession? _senderSession;
  TransferManifest? _receiverManifest;
  SenderEndpoint? _connectedEndpoint;
  StreamSubscription<DownloadProgress>? _downloadSubscription;
  bool _startingSender = false;
  bool _discovering = false;
  String? _message;

  @override
  void dispose() {
    _downloadSubscription?.cancel();
    _senderService.stop();
    _receiverService.stopDiscoveryScan();
    super.dispose();
  }

  Future<void> _pickAndSend() async {
    setState(() {
      _startingSender = true;
      _message = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final session = await _senderService.start(result.files);
      setState(() => _senderSession = session);
    } catch (error) {
      setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _startingSender = false);
      }
    }
  }

  Future<void> _stopSending() async {
    await _senderService.stop();
    setState(() => _senderSession = null);
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _senders.clear();
      _message = null;
    });
    try {
      final found = await _receiverService.discover();
      setState(() => _senders.addAll(found));
    } catch (error) {
      setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _discovering = false);
      }
    }
  }

  Future<void> _connect(SenderEndpoint endpoint) async {
    setState(() {
      _message = null;
      _receiverManifest = null;
      _connectedEndpoint = endpoint;
      _downloads.clear();
    });
    try {
      final manifest = await _receiverService.fetchManifest(endpoint);
      setState(() => _receiverManifest = manifest);
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  void _startDownload() {
    final endpoint = _connectedEndpoint;
    final manifest = _receiverManifest;
    if (endpoint == null || manifest == null) {
      return;
    }
    _downloadSubscription?.cancel();
    _downloadSubscription =
        _receiverService.downloadAll(endpoint, manifest).listen(
      (progress) {
        setState(() => _downloads[progress.file.id] = progress);
      },
      onError: (Object error) {
        setState(() => _message = error.toString());
      },
    );
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (payload == null) {
      return;
    }
    try {
      await _connect(SenderEndpoint.fromQrPayload(payload));
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('OpenShare'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.upload_file), text: 'Send'),
              Tab(icon: Icon(Icons.download), text: 'Receive'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _SenderPane(
                session: _senderSession,
                starting: _startingSender,
                onPickAndSend: _pickAndSend,
                onStop: _stopSending,
              ),
              _ReceiverPane(
                discovering: _discovering,
                senders: _senders,
                manifest: _receiverManifest,
                downloads: _downloads,
                onDiscover: _discover,
                onScanQr: _scanQr,
                onConnect: _connect,
                onStartDownload: _startDownload,
              ),
            ],
          ),
        ),
        bottomNavigationBar: _message == null
            ? null
            : Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _SenderPane extends StatelessWidget {
  const _SenderPane({
    required this.session,
    required this.starting,
    required this.onPickAndSend,
    required this.onStop,
  });

  final SenderSession? session;
  final bool starting;
  final VoidCallback onPickAndSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final activeSession = session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: starting ? null : onPickAndSend,
          icon: starting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(starting ? 'Preparing hashes' : 'Pick files'),
        ),
        if (activeSession != null) ...[
          const SizedBox(height: 18),
          Text(
            activeSession.endpoint.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${activeSession.manifest.files.length} files, '
            '${_formatBytes(activeSession.manifest.totalBytes)}',
          ),
          const SizedBox(height: 14),
          Center(
            child: QrImageView(
              data: activeSession.endpoint.encodeQrPayload(),
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          SelectableText(
            '${activeSession.endpoint.host}:${activeSession.endpoint.port}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop sending'),
          ),
          const SizedBox(height: 18),
          ...activeSession.manifest.files.map(_FileRow.new),
        ],
      ],
    );
  }
}

class _ReceiverPane extends StatelessWidget {
  const _ReceiverPane({
    required this.discovering,
    required this.senders,
    required this.manifest,
    required this.downloads,
    required this.onDiscover,
    required this.onScanQr,
    required this.onConnect,
    required this.onStartDownload,
  });

  final bool discovering;
  final List<DiscoveredSender> senders;
  final TransferManifest? manifest;
  final Map<String, DownloadProgress> downloads;
  final VoidCallback onDiscover;
  final VoidCallback onScanQr;
  final ValueChanged<SenderEndpoint> onConnect;
  final VoidCallback onStartDownload;

  @override
  Widget build(BuildContext context) {
    final activeManifest = manifest;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: discovering ? null : onDiscover,
                icon: discovering
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(discovering ? 'Searching' : 'Discover'),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filledTonal(
              tooltip: 'Scan QR',
              onPressed: onScanQr,
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ...senders.map(
          (sender) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.phone_iphone),
            title: Text(sender.endpoint.name),
            subtitle: Text('${sender.endpoint.host}:${sender.endpoint.port}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onConnect(sender.endpoint),
          ),
        ),
        if (activeManifest != null) ...[
          const Divider(height: 30),
          Text(
            activeManifest.deviceName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${activeManifest.files.length} files, '
            '${_formatBytes(activeManifest.totalBytes)}',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onStartDownload,
            icon: const Icon(Icons.download),
            label: const Text('Download all'),
          ),
          const SizedBox(height: 14),
          ...activeManifest.files.map(
            (file) => _DownloadRow(
              file: file,
              progress: downloads[file.id],
            ),
          ),
        ],
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow(this.file);

  final TransferFile file;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_formatBytes(file.size)),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.file,
    required this.progress,
  });

  final TransferFile file;
  final DownloadProgress? progress;

  @override
  Widget build(BuildContext context) {
    final current = progress;
    final status = current?.status ?? DownloadStatus.queued;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(_statusLabel(status)),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: current?.fraction ?? 0),
          const SizedBox(height: 4),
          Text(
            '${_formatBytes(current?.received ?? 0)} / ${_formatBytes(file.size)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class QrScanScreen extends StatelessWidget {
  const QrScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan sender QR')),
      body: MobileScanner(
        onDetect: (capture) {
          final value =
              capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
          if (value != null) {
            Navigator.of(context).pop(value);
          }
        },
      ),
    );
  }
}

String _statusLabel(DownloadStatus status) {
  return switch (status) {
    DownloadStatus.queued => 'Queued',
    DownloadStatus.downloading => 'Downloading',
    DownloadStatus.verifying => 'Verifying',
    DownloadStatus.retrying => 'Retrying',
    DownloadStatus.complete => 'Done',
    DownloadStatus.failed => 'Failed',
  };
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(size >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
