import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'models/sender_endpoint.dart';
import 'models/transfer_file.dart';
import 'services/pokemon_identity_service.dart';
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

class _AppHeader extends StatelessWidget {
  const _AppHeader({required this.identity});

  final PokemonIdentity? identity;

  @override
  Widget build(BuildContext context) {
    final spriteUrl = identity?.spriteUrl;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: colorScheme.primaryContainer,
          foregroundImage: spriteUrl == null ? null : NetworkImage(spriteUrl),
          child: spriteUrl == null
              ? Icon(
                  Icons.catching_pokemon,
                  size: 18,
                  color: colorScheme.onPrimaryContainer,
                )
              : null,
        ),
        const SizedBox(width: 10),
        const Text('OpenShare'),
      ],
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
  final _pokemonIdentityService = PokemonIdentityService();
  final _downloads = <String, DownloadProgress>{};
  final _senders = <DiscoveredSender>[];

  PokemonIdentity? _pokemonIdentity;
  SenderSession? _senderSession;
  TransferManifest? _receiverManifest;
  SenderEndpoint? _connectedEndpoint;
  StreamSubscription<DownloadProgress>? _downloadSubscription;
  Timer? _completionTimer;
  Timer? _completionHideTimer;
  Timer? _completionResetTimer;
  bool _loadingIdentity = true;
  bool _startingSender = false;
  bool _discovering = false;
  bool _loadingManifest = false;
  bool _showReceiverCompletion = false;
  bool _receiverCompletionVisible = false;
  String? _message;
  String? _receiverError;

  @override
  void initState() {
    super.initState();
    _loadPokemonIdentity();
  }

  @override
  void dispose() {
    _cancelCompletionTimers();
    _downloadSubscription?.cancel();
    _senderService.stop();
    _receiverService.stopDiscoveryScan();
    super.dispose();
  }

  Future<void> _loadPokemonIdentity() async {
    try {
      final identity = await _pokemonIdentityService.load();
      if (mounted) {
        setState(() => _pokemonIdentity = identity);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingIdentity = false);
      }
    }
  }

  Future<void> _pickAndSend() async {
    final identity = _pokemonIdentity;
    if (identity == null) {
      setState(() => _message = 'Still preparing your device identity.');
      return;
    }
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
      final session = await _senderService.start(
        result.files,
        deviceName: identity.displayName,
      );
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
    _cancelCompletionTimers();
    setState(() {
      _discovering = true;
      _senders.clear();
      _message = null;
      _receiverError = null;
      _showReceiverCompletion = false;
      _receiverCompletionVisible = false;
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
    _cancelCompletionTimers();
    setState(() {
      _message = null;
      _receiverError = null;
      _receiverManifest = null;
      _connectedEndpoint = endpoint;
      _loadingManifest = true;
      _showReceiverCompletion = false;
      _receiverCompletionVisible = false;
      _downloads.clear();
    });
    try {
      final manifest = await _receiverService.fetchManifest(endpoint);
      if (mounted) {
        setState(() => _receiverManifest = manifest);
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to fetch receiver manifest: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _message = error.toString();
          _receiverError = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loadingManifest = false);
      }
    }
  }

  void _startDownload() {
    final endpoint = _connectedEndpoint;
    final manifest = _receiverManifest;
    if (endpoint == null || manifest == null) {
      return;
    }
    _cancelCompletionTimers();
    _downloadSubscription?.cancel();
    setState(() {
      _showReceiverCompletion = false;
      _receiverCompletionVisible = false;
    });
    _downloadSubscription =
        _receiverService.downloadAll(endpoint, manifest).listen(
      (progress) {
        setState(() => _downloads[progress.file.id] = progress);
        _scheduleReceiverCompletionIfDone();
      },
      onError: (Object error) {
        setState(() => _message = error.toString());
      },
    );
  }

  void _scheduleReceiverCompletionIfDone() {
    final manifest = _receiverManifest;
    if (manifest == null || manifest.files.isEmpty || _showReceiverCompletion) {
      return;
    }
    final allDone = manifest.files.every(
      (file) => _downloads[file.id]?.status == DownloadStatus.complete,
    );
    if (!allDone || _completionTimer?.isActive == true) {
      return;
    }
    _completionTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showReceiverCompletion = true;
          _receiverCompletionVisible = true;
        });
        _completionHideTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) {
            return;
          }
          setState(() => _receiverCompletionVisible = false);
          _completionResetTimer = Timer(
            const Duration(milliseconds: 300),
            _resetReceiverScreen,
          );
        });
      }
    });
  }

  void _cancelCompletionTimers() {
    _completionTimer?.cancel();
    _completionHideTimer?.cancel();
    _completionResetTimer?.cancel();
  }

  void _resetReceiverScreen() {
    if (!mounted) {
      return;
    }
    setState(() {
      _senders.clear();
      _receiverManifest = null;
      _connectedEndpoint = null;
      _downloads.clear();
      _receiverError = null;
      _loadingManifest = false;
      _showReceiverCompletion = false;
      _receiverCompletionVisible = false;
    });
  }

  Future<void> _scanQr() async {
    try {
      final payload = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScanScreen()),
      );
      if (payload == null) {
        return;
      }
      await _connect(SenderEndpoint.fromQrPayload(payload));
    } catch (error, stackTrace) {
      debugPrint('QR scan navigation/connect failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _message = error.toString();
          _receiverError = error.toString();
          _loadingManifest = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: _AppHeader(identity: _pokemonIdentity),
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
                loadingIdentity: _loadingIdentity,
                onPickAndSend: _pickAndSend,
                onStop: _stopSending,
              ),
              _ReceiverPane(
                discovering: _discovering,
                loadingManifest: _loadingManifest,
                senders: _senders,
                manifest: _receiverManifest,
                error: _receiverError,
                downloads: _downloads,
                complete: _showReceiverCompletion,
                completionVisible: _receiverCompletionVisible,
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
    required this.loadingIdentity,
    required this.onPickAndSend,
    required this.onStop,
  });

  final SenderSession? session;
  final bool starting;
  final bool loadingIdentity;
  final VoidCallback onPickAndSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final activeSession = session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: starting || loadingIdentity ? null : onPickAndSend,
          icon: starting || loadingIdentity
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(
            loadingIdentity
                ? 'Preparing identity'
                : starting
                    ? 'Preparing hashes'
                    : 'Pick files',
          ),
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
    required this.loadingManifest,
    required this.senders,
    required this.manifest,
    required this.error,
    required this.downloads,
    required this.complete,
    required this.completionVisible,
    required this.onDiscover,
    required this.onScanQr,
    required this.onConnect,
    required this.onStartDownload,
  });

  final bool discovering;
  final bool loadingManifest;
  final List<DiscoveredSender> senders;
  final TransferManifest? manifest;
  final String? error;
  final Map<String, DownloadProgress> downloads;
  final bool complete;
  final bool completionVisible;
  final VoidCallback onDiscover;
  final VoidCallback onScanQr;
  final ValueChanged<SenderEndpoint> onConnect;
  final VoidCallback onStartDownload;

  @override
  Widget build(BuildContext context) {
    final activeManifest = manifest;
    final activeError = error;
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
        if (complete)
          _ReceiverCompleteStatus(visible: completionVisible)
        else ...[
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
          if (loadingManifest)
            const _ReceiverStatePanel(
              icon: Icons.sync,
              title: 'Loading sender details',
              message: 'Fetching the file list...',
              loading: true,
            )
          else if (activeError != null)
            _ReceiverStatePanel(
              icon: Icons.error_outline,
              title: 'Could not load sender',
              message: activeError,
            )
          else if (activeManifest == null && senders.isEmpty)
            const _ReceiverStatePanel(
              icon: Icons.devices_other,
              title: 'No sender connected',
              message: 'Discover a sender or scan a QR code.',
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
            if (activeManifest.files.isEmpty)
              const _ReceiverStatePanel(
                icon: Icons.folder_off_outlined,
                title: 'No files available',
                message: 'The sender did not share any files.',
              )
            else ...[
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
        ],
      ],
    );
  }
}

class _ReceiverCompleteStatus extends StatelessWidget {
  const _ReceiverCompleteStatus({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle,
              size: 48,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Received! Check your gallery.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiverStatePanel extends StatelessWidget {
  const _ReceiverStatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox.square(
              dimension: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          else
            Icon(icon, size: 40, color: colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
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

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handledScan = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan sender QR')),
      body: MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            debugPrint('QR raw value: ${barcode.rawValue}');
            if (_handledScan) {
              return;
            }
            final value = barcode.rawValue;
            if (value == null || value.isEmpty) {
              continue;
            }
            _handledScan = true;
            Navigator.of(context).pop(value);
            return;
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
