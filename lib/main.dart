import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int kPort = 48080;
const Color kBg = Color(0xFF0B1220);
const Color kCard = Color(0xFF111A2E);
const Color kBorder = Color(0xFF1E2A44);
const Color kBlue = Color(0xFF2563EB);
const Color kMuted = Color(0xFF94A3B8);

void main() => runApp(const LinkApp());

/// Runs a tiny web server on this device and talks to the other device's server.
/// The same code runs on Android and Windows.
class LinkService extends ChangeNotifier {
  static const MethodChannel _native = MethodChannel('lmw/native');

  final String code = (100000 + Random.secure().nextInt(900000)).toString();
  final String deviceName = Platform.localHostname;
  final Set<String> _tokens = {};
  final List<String> log = [];
  List<String> ips = [];
  HttpServer? _server;
  String? peerHost;
  String? peerName;
  String? token;

  bool autoClip = true;
  bool sharingScreen = false;
  bool sharingCam = false;
  Uint8List? _camFrame;
  String _lastClip = '';
  bool _ticking = false;
  Timer? _clipTimer;

  bool get linked => peerHost != null && token != null;

  void _log(String line) {
    log.insert(0, line);
    if (log.length > 50) log.removeLast();
    notifyListeners();
  }

  void setAutoClip(bool v) {
    autoClip = v;
    notifyListeners();
  }

  String _newToken() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<void> start() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      ips = [for (final i in ifaces) for (final a in i.addresses) a.address];
    } catch (_) {}
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
      _server!.listen(_handle);
    } catch (e) {
      _log('Could not start on port $kPort: $e');
    }
    _clipTimer = Timer.periodic(const Duration(seconds: 1), (_) => _clipTick());
    notifyListeners();
  }

  Future<void> _reply(HttpRequest req, int status, [String body = '']) async {
    req.response.statusCode = status;
    if (body.isNotEmpty) req.response.write(body);
    await req.response.close();
  }

  Future<Directory> _saveDir() async {
    Directory base;
    if (Platform.isAndroid) {
      base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } else {
      base = (await getDownloadsDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}Link my Windows');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method == 'POST' && req.uri.path == '/pair') {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        if (body['code'] != code) {
          await _reply(req, 403);
          return;
        }
        final t = _newToken();
        _tokens.add(t);
        token = t;
        peerHost = req.connectionInfo!.remoteAddress.address;
        peerName = body['name']?.toString() ?? 'Other device';
        await _reply(req, 200, jsonEncode({'token': t, 'name': deviceName}));
        _log('Linked with $peerName');
        return;
      }
      final auth = req.headers.value('x-token');
      if (auth == null || !_tokens.contains(auth)) {
        await _reply(req, 401);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/clip') {
        final text = await utf8.decoder.bind(req).join();
        _lastClip = text;
        await Clipboard.setData(ClipboardData(text: text));
        await _reply(req, 200);
        _log('Clipboard received and copied');
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/file') {
        final raw = req.uri.queryParameters['name'] ?? 'file';
        final name = raw.split(RegExp(r'[\\/]')).last;
        final dir = await _saveDir();
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        final sink = file.openWrite();
        await sink.addStream(req);
        await sink.close();
        await _reply(req, 200);
        _log('Received $name (saved in ${dir.path})');
        return;
      }
      if (req.method == 'GET' &&
          (req.uri.path == '/screen.jpg' || req.uri.path == '/cam.jpg')) {
        Uint8List? bytes;
        if (req.uri.path == '/screen.jpg') {
          if (Platform.isAndroid && sharingScreen) {
            bytes = await _native.invokeMethod<Uint8List>('getScreenFrame');
          }
        } else {
          bytes = _camFrame;
        }
        if (bytes == null) {
          await _reply(req, 204);
          return;
        }
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.contentLength = bytes.length;
        req.response.add(bytes);
        await req.response.close();
        return;
      }
      await _reply(req, 404);
    } catch (e) {
      _log('Error handling request: $e');
      try {
        await _reply(req, 500);
      } catch (_) {}
    }
  }

  /// Returns null on success, or an error message.
  Future<String?> pair(String host, String enteredCode) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final r = await c.postUrl(Uri.parse('http://$host:$kPort/pair'));
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode({'code': enteredCode, 'name': deviceName}));
      final resp = await r.close();
      final text = await utf8.decoder.bind(resp).join();
      if (resp.statusCode == 403) return 'Wrong pairing code.';
      if (resp.statusCode != 200) return 'Failed (HTTP ${resp.statusCode}).';
      final j = jsonDecode(text);
      token = j['token'] as String;
      _tokens.add(token!);
      peerHost = host;
      peerName = j['name']?.toString() ?? 'Other device';
      _log('Linked with $peerName');
      return null;
    } catch (_) {
      return 'Could not reach $host. Same Wi-Fi? App open on both devices?';
    } finally {
      c.close();
    }
  }

  /// What the QR code on this device contains: the pairing code and every
  /// IP address this device has.
  String get qrData => 'LMW|$code|${ips.join(",")}';

  /// Links using the text read from the other device's QR code.
  Future<String?> pairFromQr(String data) async {
    final parts = data.split('|');
    if (parts.length != 3 || parts[0] != 'LMW') {
      return 'That is not a Link my Windows code.';
    }
    for (final ip in parts[2].split(',')) {
      if (ip.isEmpty) continue;
      final e = await pair(ip, parts[1]);
      if (e == null) return null;
      if (e == 'Wrong pairing code.') return e;
    }
    return 'Could not reach the other device. Same Wi-Fi? App open on both devices?';
  }

  void unlink() {
    peerHost = null;
    peerName = null;
    token = null;
    _tokens.clear();
    _log('Unlinked');
  }

  Future<void> _postText(String path, String body) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final r = await c.postUrl(Uri.parse('http://$peerHost:$kPort$path'));
      r.headers.set('x-token', token!);
      r.write(body);
      final resp = await r.close();
      await resp.drain();
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
    } finally {
      c.close();
    }
  }

  /// Copies new clipboard text to the other device (checked once a second).
  /// On Android the system only allows reading the clipboard while the app
  /// is open on screen.
  Future<void> _clipTick() async {
    if (!linked || !autoClip || _ticking) return;
    _ticking = true;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      if (text.isNotEmpty && text != _lastClip) {
        _lastClip = text;
        await _postText('/clip', text);
        _log('Clipboard synced to $peerName');
      }
    } catch (_) {
    } finally {
      _ticking = false;
    }
  }

  Future<void> sendText(String text) async {
    if (!linked || text.isEmpty) return;
    try {
      _lastClip = text;
      await _postText('/clip', text);
      _log('Sent text to $peerName');
    } catch (e) {
      _log('Send failed: $e');
    }
  }

  Future<void> sendClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (text.isEmpty) {
      _log('Your clipboard is empty');
      return;
    }
    await sendText(text);
  }

  Future<void> sendFile() async {
    if (!linked) return;
    final res = await FilePicker.platform.pickFiles();
    final path = res?.files.single.path;
    if (res == null || path == null) return;
    final f = File(path);
    final name = res.files.single.name;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      _log('Sending $name…');
      final r = await c.postUrl(Uri.parse(
          'http://$peerHost:$kPort/file?name=${Uri.encodeComponent(name)}'));
      r.headers.set('x-token', token!);
      r.contentLength = await f.length();
      await r.addStream(f.openRead());
      final resp = await r.close();
      await resp.drain();
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      _log('Sent $name to $peerName');
    } catch (e) {
      _log('Send failed: $e');
    } finally {
      c.close();
    }
  }

  /// Android only: start or stop sharing this phone's screen.
  Future<void> toggleScreen() async {
    if (!Platform.isAndroid) return;
    try {
      if (sharingScreen) {
        await _native.invokeMethod('stopScreen');
        sharingScreen = false;
        _log('Screen sharing stopped');
      } else {
        final ok = await _native.invokeMethod<bool>('startScreen');
        sharingScreen = ok == true;
        _log(sharingScreen
            ? 'Screen sharing started'
            : 'Screen sharing was cancelled');
      }
    } catch (e) {
      _log('Screen sharing failed: $e');
    }
    notifyListeners();
  }

  /// Android only: turn the phone camera on or off as a webcam.
  Future<void> toggleCamera() async {
    if (!Platform.isAndroid) return;
    if (sharingCam) {
      sharingCam = false;
      notifyListeners();
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _log('No camera found');
        return;
      }
      final desc = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final ctrl =
          CameraController(desc, ResolutionPreset.medium, enableAudio: false);
      await ctrl.initialize();
      await ctrl.setFlashMode(FlashMode.off);
      sharingCam = true;
      await WakelockPlus.enable();
      _log('Camera is on. Keep this app open on your phone.');
      notifyListeners();
      while (sharingCam) {
        try {
          final f = await ctrl.takePicture();
          _camFrame = await f.readAsBytes();
          try {
            await File(f.path).delete();
          } catch (_) {}
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
        await Future.delayed(const Duration(milliseconds: 30));
      }
      await ctrl.dispose();
      _camFrame = null;
      await WakelockPlus.disable();
      _log('Camera stopped');
    } catch (e) {
      sharingCam = false;
      _log('Camera failed: $e');
    }
  }

  @override
  void dispose() {
    sharingCam = false;
    _clipTimer?.cancel();
    _server?.close(force: true);
    super.dispose();
  }
}

class LinkApp extends StatelessWidget {
  const LinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Link my Windows',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kBlue, surface: kCard),
        appBarTheme: const AppBarTheme(backgroundColor: kBg),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final svc = LinkService();
  final hostC = TextEditingController();
  final codeC = TextEditingController();
  final textC = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    svc.start();
  }

  @override
  void dispose() {
    svc.dispose();
    hostC.dispose();
    codeC.dispose();
    textC.dispose();
    super.dispose();
  }

  Future<void> scan() async {
    final value = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (value == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    final e = await svc.pairFromQr(value);
    if (mounted) {
      setState(() {
        busy = false;
        error = e;
      });
    }
  }

  Widget card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kBorder),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget heading(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)));

  List<Widget> pairView() => [
        const Text('Link your devices',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text(
            'Open this app on your phone and your PC, on the same Wi-Fi. '
            'Type the other device\'s IP address and pairing code below.',
            style: TextStyle(color: kMuted, height: 1.4)),
        const SizedBox(height: 20),
        if (Platform.isAndroid)
          card([
            heading('Instant link'),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: busy ? null : scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(busy ? 'Connecting…' : 'Scan QR code'),
              ),
            ),
            const SizedBox(height: 10),
            const Text('Open the app on your PC and scan the code it shows.',
                style: TextStyle(color: kMuted)),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!,
                      style: const TextStyle(color: Color(0xFFF87171)))),
          ]),
        card([
          heading('This device'),
          if (svc.ips.isNotEmpty)
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.white,
                child: QrImageView(
                    data: svc.qrData, size: 180, backgroundColor: Colors.white),
              ),
            ),
          if (svc.ips.isNotEmpty) const SizedBox(height: 12),
          if (svc.ips.isEmpty)
            const Text('No Wi-Fi address found')
          else
            for (final ip in svc.ips) SelectableText('IP address: $ip'),
          const SizedBox(height: 10),
          const Text('Pairing code', style: TextStyle(color: kMuted)),
          SelectableText(svc.code,
              style: const TextStyle(
                  fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: 6)),
        ]),
        card([
          heading('Link to the other device'),
          TextField(
              controller: hostC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Its IP address (e.g. 192.168.1.20)',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: codeC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Its pairing code',
                  border: OutlineInputBorder())),
          if (error != null)
            Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!,
                    style: const TextStyle(color: Color(0xFFF87171)))),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      final e =
                          await svc.pair(hostC.text.trim(), codeC.text.trim());
                      if (mounted) {
                        setState(() {
                          busy = false;
                          error = e;
                        });
                      }
                    },
              child: Text(busy ? 'Connecting…' : 'Connect'),
            ),
          ),
        ]),
        if (svc.log.isNotEmpty) ...activityView(),
      ];

  List<Widget> activityView() => [
        const Padding(
            padding: EdgeInsets.fromLTRB(2, 8, 0, 8),
            child: Text('Activity',
                style: TextStyle(fontWeight: FontWeight.w700))),
        for (final l in svc.log)
          Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(l, style: const TextStyle(color: kMuted))),
      ];

  void openViewer(String path, String title) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ViewerPage(svc: svc, path: path, title: title)));
  }

  List<Widget> mediaCard() {
    if (Platform.isAndroid) {
      return [
        card([
          heading('Share from this phone'),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: svc.toggleScreen,
              icon: Icon(svc.sharingScreen
                  ? Icons.stop_screen_share
                  : Icons.screen_share),
              label: Text(
                  svc.sharingScreen ? 'Stop sharing screen' : 'Share my screen'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.tonalIcon(
              onPressed: svc.toggleCamera,
              icon: Icon(svc.sharingCam ? Icons.videocam_off : Icons.videocam),
              label:
                  Text(svc.sharingCam ? 'Turn camera off' : 'Use as webcam'),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
              'After you start one, open "View phone screen" or "View phone '
              'camera" on your PC. Keep this app open while the camera is on.',
              style: TextStyle(color: kMuted, height: 1.4)),
        ]),
      ];
    }
    return [
      card([
        heading('Your phone on this PC'),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: () => openViewer('/screen.jpg', 'Phone screen'),
            icon: const Icon(Icons.smartphone),
            label: const Text('View phone screen'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.tonalIcon(
            onPressed: () => openViewer('/cam.jpg', 'Phone camera'),
            icon: const Icon(Icons.videocam),
            label: const Text('View phone camera'),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
            'Start sharing on the phone first. To use the camera in Zoom, '
            'Meet or Teams: open OBS Studio, add this window with "Window '
            'Capture", then click "Start Virtual Camera".',
            style: TextStyle(color: kMuted, height: 1.4)),
      ]),
    ];
  }

  List<Widget> hubView() => [
        card([
          Row(children: [
            const Icon(Icons.devices, color: kBlue, size: 32),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(svc.peerName ?? 'Device',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800)),
                  Text('Connected · ${svc.peerHost}',
                      style: const TextStyle(color: Color(0xFF4ADE80))),
                ])),
            OutlinedButton(onPressed: svc.unlink, child: const Text('Unlink')),
          ]),
        ]),
        ...mediaCard(),
        card([
          heading('Clipboard'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync clipboard automatically'),
            subtitle: Text(
                Platform.isAndroid
                    ? 'On the phone this works while the app is open.'
                    : 'Copy on one device, paste on the other.',
                style: const TextStyle(color: kMuted)),
            value: svc.autoClip,
            onChanged: svc.setAutoClip,
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.tonalIcon(
                onPressed: svc.sendClipboard,
                icon: const Icon(Icons.content_paste),
                label: const Text('Send my clipboard now')),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: textC,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                  labelText: 'Type text to send',
                  border: OutlineInputBorder())),
          const SizedBox(height: 10),
          FilledButton.tonal(
              onPressed: () {
                svc.sendText(textC.text);
                textC.clear();
              },
              child: const Text('Send text')),
        ]),
        card([
          heading('Files'),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.tonalIcon(
                onPressed: svc.sendFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('Send a file')),
          ),
        ]),
        ...activityView(),
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
            title: const Text('Link my Windows',
                style: TextStyle(fontWeight: FontWeight.w800))),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: svc.linked ? hubView() : pairView(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Android only: scans the QR code shown on the other device.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the QR code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (done || capture.barcodes.isEmpty) return;
          final v = capture.barcodes.first.rawValue;
          if (v == null) return;
          done = true;
          Navigator.of(context).pop(v);
        },
      ),
    );
  }
}

/// Shows a live picture from the other device by asking for a new frame
/// again and again.
class ViewerPage extends StatefulWidget {
  const ViewerPage(
      {super.key, required this.svc, required this.path, required this.title});

  final LinkService svc;
  final String path;
  final String title;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  Uint8List? frame;
  bool run = true;
  String status = 'Waiting for the phone to start sharing…';

  @override
  void initState() {
    super.initState();
    _loop();
  }

  @override
  void dispose() {
    run = false;
    super.dispose();
  }

  Future<void> _loop() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    while (run) {
      try {
        final r = await c.getUrl(Uri.parse(
            'http://${widget.svc.peerHost}:$kPort${widget.path}'));
        r.headers.set('x-token', widget.svc.token ?? '');
        final resp = await r.close();
        if (resp.statusCode == 200) {
          final b = await resp.fold<BytesBuilder>(BytesBuilder(), (b, d) {
            b.add(d);
            return b;
          });
          if (mounted && run) setState(() => frame = b.takeBytes());
        } else {
          await resp.drain();
          if (mounted && run) {
            setState(() {
              frame = null;
              status = 'Waiting for the phone to start sharing…';
            });
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (_) {
        if (mounted && run) {
          setState(() => status = 'Cannot reach the phone. Is the app open?');
        }
        await Future.delayed(const Duration(milliseconds: 800));
      }
      await Future.delayed(const Duration(milliseconds: 60));
    }
    c.close(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: Center(
        child: frame == null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kMuted)))
            : Image.memory(frame!, gaplessPlayback: true, fit: BoxFit.contain),
      ),
    );
  }
}
