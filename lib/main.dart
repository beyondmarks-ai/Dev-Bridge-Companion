import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'models/devbridge_models.dart';
import 'services/credential_store.dart';
import 'services/apk_installer.dart';
import 'services/devbridge_api.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DevBridgeApp());
}

class DevBridgeApp extends StatelessWidget {
  const DevBridgeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DevBridge',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF5DF2AD),
        brightness: Brightness.dark,
        surface: const Color(0xFF101B18),
      ),
      scaffoldBackgroundColor: const Color(0xFF07100E),
      cardTheme: const CardThemeData(
        color: Color(0xFF101B18),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: Color(0xFF263A34)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF091411),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = DevBridgeApi();
  final _store = CredentialStore();
  final _installer = ApkInstaller();
  final Map<String, File> _verifiedApks = {};
  ConnectionCredentials? _credentials;
  SessionSnapshot? _snapshot;
  Timer? _poller;
  bool _loading = true;
  String? _error;
  String? _downloadingBuildId;
  double? _downloadProgress;
  String? _downloadMessage;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      _credentials = await _store.read();
      if (_credentials != null) await _refresh();
    } catch (_) {
      _error = 'Could not restore the previous connection.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (_credentials != null) _startPolling();
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<PairingPayload>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (payload == null || !mounted) return;

    final android = await DeviceInfoPlugin().androidInfo;
    if (!mounted) return;
    final controller = TextEditingController(
      text: '${android.manufacturer} ${android.model}',
    );
    final approved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Connect to DevBridge',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              payload.baseUri.toString(),
              style: const TextStyle(color: Color(0xFF91A79F)),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow connection'),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final credentials = await _api.pair(
        payload: payload,
        deviceName: controller.text.trim().isEmpty
            ? 'Android phone'
            : controller.text.trim(),
        platformVersion: android.version.release,
      );
      await _store.save(credentials);
      _credentials = credentials;
      await _refresh();
      _startPolling();
    } on TimeoutException {
      _error =
          'DevBridge could not be reached. Check internet access and confirm the session is still online.';
    } on DevBridgeException catch (error) {
      _error = error.message;
    } catch (_) {
      _error =
          'Connection failed. Check the QR address and confirm the DevBridge service is online.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final credentials = _credentials;
    if (credentials == null) return;
    try {
      final snapshot = await _api.getSession(credentials);
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _error = null;
        });
      }
    } on DevBridgeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'PC temporarily unreachable. Retrying…');
      }
    }
  }

  Future<void> _downloadAndInstall(DevBridgeBuild build) async {
    if (_downloadingBuildId != null) return;
    setState(() {
      _downloadingBuildId = build.id;
      _downloadProgress = null;
      _downloadMessage = 'Requesting secure download…';
    });

    try {
      var apk = _verifiedApks[build.id];
      if (apk == null || !await apk.exists()) {
        apk = await _api.downloadBuild(
          credentials: _credentials!,
          build: build,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _downloadProgress = total == null || total == 0
                  ? null
                  : received / total;
              _downloadMessage = total == null
                  ? 'Downloading ${_formatBytes(received)}…'
                  : 'Downloading ${(_downloadProgress! * 100).round()}% · '
                        '${_formatBytes(received)} of ${_formatBytes(total)}';
            });
          },
        );
        _verifiedApks[build.id] = apk;
      }

      if (mounted) {
        setState(() {
          _downloadProgress = 1;
          _downloadMessage = 'SHA-256 verified. Opening Android installer…';
        });
      }
      final result = await _installer.install(apk);
      if (mounted) {
        setState(() {
          _downloadMessage = result == InstallLaunchResult.permissionRequired
              ? 'Enable “Allow from this source”, return here, then tap Install again.'
              : 'Android Package Installer opened.';
        });
      }
    } on DevBridgeException catch (error) {
      if (mounted) setState(() => _downloadMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _downloadMessage =
              'Download or installer launch failed. Please retry.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingBuildId = null;
          _downloadProgress = null;
        });
      }
    }
  }

  static String _formatBytes(int bytes) => bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';

  Future<void> _disconnect() async {
    _poller?.cancel();
    await _store.clear();
    if (mounted) {
      setState(() {
        _credentials = null;
        _snapshot = null;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          Icon(Icons.hub_outlined),
          SizedBox(width: 10),
          Text('DevBridge'),
        ],
      ),
      actions: [
        if (_credentials != null)
          IconButton(
            onPressed: _disconnect,
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
          ),
      ],
    ),
    body: SafeArea(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _credentials == null
            ? _UnpairedView(onScan: _scan, error: _error)
            : _ConnectedView(
                credentials: _credentials!,
                snapshot: _snapshot,
                error: _error,
                onRefresh: _refresh,
                onInstall: _downloadAndInstall,
                downloadingBuildId: _downloadingBuildId,
                downloadProgress: _downloadProgress,
                downloadMessage: _downloadMessage,
              ),
      ),
    ),
  );
}

class _UnpairedView extends StatelessWidget {
  const _UnpairedView({required this.onScan, this.error});
  final VoidCallback onScan;
  final String? error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: const Color(0xFF5DF2AD).withValues(alpha: .1),
            borderRadius: BorderRadius.circular(28),
          ),
          child: const Icon(
            Icons.qr_code_scanner,
            size: 52,
            color: Color(0xFF5DF2AD),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Pair with your PC',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const Text(
          'Create a session in DevBridge on your computer, then scan its secure QR code from any internet-connected network.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF91A79F), height: 1.5),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFF6B75)),
            ),
          ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Padding(
              padding: EdgeInsets.all(4),
              child: Text('Scan DevBridge QR'),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.credentials,
    required this.snapshot,
    required this.error,
    required this.onRefresh,
    required this.onInstall,
    required this.downloadingBuildId,
    required this.downloadProgress,
    required this.downloadMessage,
  });
  final ConnectionCredentials credentials;
  final SessionSnapshot? snapshot;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<void> Function(DevBridgeBuild) onInstall;
  final String? downloadingBuildId;
  final double? downloadProgress;
  final String? downloadMessage;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const _OnlineDot(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CONNECTED',
                        style: TextStyle(
                          color: Color(0xFF5DF2AD),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        snapshot?.appName ?? 'Loading app…',
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        snapshot == null
                            ? credentials.baseUri.host
                            : '${snapshot!.projectName}${snapshot!.packageName == null ? '' : ' · ${snapshot!.packageName}'}',
                        style: const TextStyle(color: Color(0xFF91A79F)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xFFFFC857)),
            ),
          ),
        if (downloadMessage != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(downloadMessage!),
                  if (downloadingBuildId != null) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: downloadProgress),
                  ],
                ],
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 22, 4, 10),
          child: Text(
            'AVAILABLE BUILDS',
            style: TextStyle(
              color: Color(0xFF91A79F),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ),
        if (snapshot == null || snapshot!.builds.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                children: [
                  Icon(Icons.hourglass_empty, color: Color(0xFF91A79F)),
                  SizedBox(height: 10),
                  Text(
                    'Waiting for the developer to publish a build.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF91A79F)),
                  ),
                ],
              ),
            ),
          )
        else
          ...snapshot!.builds.map(
            (build) => Card(
              child: ListTile(
                leading: const Icon(Icons.android, color: Color(0xFF5DF2AD)),
                title: Text(
                  build.versionName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  'Build ${build.versionCode} · ${_size(build.sizeBytes)}',
                ),
                trailing: downloadingBuildId == build.id
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton.icon(
                        onPressed: downloadingBuildId == null
                            ? () => onInstall(build)
                            : null,
                        icon: const Icon(Icons.download_for_offline_outlined),
                        label: const Text('Install'),
                      ),
              ),
            ),
          ),
      ],
    ),
  );

  static String _size(int bytes) => bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';
}

class _OnlineDot extends StatelessWidget {
  const _OnlineDot();
  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: const BoxDecoration(
      color: Color(0xFF5DF2AD),
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: Color(0x995DF2AD), blurRadius: 12)],
    ),
  );
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  void _detected(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final payload = PairingPayload.tryParse(barcode.rawValue ?? '');
      if (payload == null) continue;
      _handled = true;
      _controller.stop();
      Navigator.pop(context, payload);
      return;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scan QR'),
      actions: [
        IconButton(
          onPressed: _controller.toggleTorch,
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _detected,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Camera unavailable: ${error.errorDetails?.message ?? error.errorCode.name}',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF5DF2AD), width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            'Point the camera at the QR shown by DevBridge on your PC.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 8)],
            ),
          ),
        ),
      ],
    ),
  );
}
