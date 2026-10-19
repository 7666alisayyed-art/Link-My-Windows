import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int kPort = 48080;

/// Keeps the newest picture from the phone so it can be sent to the PC.
class FrameBus {
  Uint8List? latest;
  int seq = 0;
  final StreamController<void> _c = StreamController<void>.broadcast();
  Stream<void> get stream => _c.stream;

  void add(Uint8List b) {
    latest = b;
    seq++;
    _c.add(null);
  }

  void clear() {
    latest = null;
  }
}

/// Runs a tiny web server on this device and talks to the other device's server.
/// The same code runs on Android and Windows.
class LinkService extends ChangeNotifier {
  static const MethodChannel _native = MethodChannel('lmw/native');
  static const EventChannel _screenEvents = EventChannel('lmw/screen_frames');
  static const EventChannel _camEvents = EventChannel('lmw/cam_frames');

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
  bool controlReady = false;
  int camRotation = 90;
  final FrameBus screenBus = FrameBus();
  final FrameBus camBus = FrameBus();
  StreamSubscription<dynamic>? _screenSub;
  StreamSubscription<dynamic>? _camSub;
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
    _clipTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) => _clipTick());
    await refreshControl();
    notifyListeners();
  }

  Future<void> onResume() async {
    await refreshControl();
    await _clipTick();
    await handleShared();
  }

  /// Android: is the "control from PC" accessibility service switched on?
  Future<void> refreshControl() async {
    if (!Platform.isAndroid) return;
    try {
      final on = await _native.invokeMethod<bool>('controlEnabled');
      if (on != controlReady) {
        controlReady = on == true;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod('openAccessibility');
    } catch (_) {}
  }

  /// Windows: sends a tap, swipe, key or text to the phone.
  /// Returns the HTTP status (200 ok, 409 phone has not enabled control).
  Future<int> sendControl(Map<String, dynamic> m) async {
    if (!linked) return 0;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final r = await c.postUrl(Uri.parse('http://$peerHost:$kPort/ctl'));
      r.headers.set('x-token', token!);
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(m));
      final resp = await r.close();
      await resp.drain();
      return resp.statusCode;
    } catch (_) {
      return 0;
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _reply(HttpRequest req, int status, [String body = '']) async {
    req.response.statusCode = status;
    if (body.isNotEmpty) req.response.write(body);
    await req.response.close();
  }

  Future<Directory> saveDir() async {
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

  Future<void> openReceivedFolder() async {
    try {
      final dir = await saveDir();
      await Process.run('explorer.exe', [dir.path]);
    } catch (e) {
      _log('Could not open the folder: $e');
    }
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
      if (req.uri.path == '/ws/screen' || req.uri.path == '/ws/cam') {
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          await _reply(req, 400);
          return;
        }
        final ws = await WebSocketTransformer.upgrade(req,
            compression: CompressionOptions.compressionOff);
        final cam = req.uri.path == '/ws/cam';
        _serveFrames(ws, cam ? camBus : screenBus, cam ? camRotation : 0);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/ctl') {
        final m = jsonDecode(await utf8.decoder.bind(req).join());
        if (!Platform.isAndroid) {
          await _reply(req, 404);
          return;
        }
        final ok = await _native.invokeMethod<bool>('control', m);
        await _reply(req, ok == true ? 200 : 409);
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
        final dir = await saveDir();
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        final sink = file.openWrite();
        await sink.addStream(req);
        await sink.close();
        await _reply(req, 200);
        _log('Received $name (saved in ${dir.path})');
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

  /// Sends pictures to the viewer one at a time. The viewer answers after it
  /// has shown each picture, so a slow viewer never builds up a delay.
  void _serveFrames(WebSocket ws, FrameBus bus, int rotation) {
    ws.add(jsonEncode({'rot': rotation}));
    var lastSeq = 0;
    var ready = true;
    void trySend() {
      final f = bus.latest;
      if (ready && f != null && bus.seq > lastSeq) {
        lastSeq = bus.seq;
        ready = false;
        try {
          ws.add(f);
        } catch (_) {}
      }
    }

    final sub = bus.stream.listen((_) => trySend());
    ws.listen((_) {
      ready = true;
      trySend();
    }, onDone: sub.cancel, onError: (_) => sub.cancel(), cancelOnError: true);
    trySend();
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

  /// Copies new clipboard text to the other device. On Android the system
  /// only allows reading the clipboard while this app is open on screen.
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
    await sendFilePath(path, res.files.single.name);
  }

  Future<void> sendFilePath(String path, String name) async {
    if (!linked) return;
    final f = File(path);
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

  /// Android: sends text or a file that was shared to this app from another
  /// app (Share, then Link my Windows).
  Future<void> handleShared() async {
    if (!Platform.isAndroid) return;
    for (final ms in [0, 800, 2500]) {
      if (ms > 0) await Future.delayed(Duration(milliseconds: ms));
      try {
        final m = await _native.invokeMethod<Map>('takeShare');
        if (m == null) continue;
        if (!linked) {
          _log('Link a PC first, then share again');
          return;
        }
        if (m['type'] == 'text') {
          await sendText(m['text'] as String);
        } else if (m['type'] == 'file') {
          await sendFilePath(m['path'] as String, m['name'] as String);
        }
        return;
      } catch (_) {}
    }
  }

  /// Android only: start or stop sharing this phone's screen.
  Future<void> toggleScreen() async {
    if (!Platform.isAndroid) return;
    try {
      if (sharingScreen) {
        await _native.invokeMethod('stopScreen');
        await _screenSub?.cancel();
        _screenSub = null;
        screenBus.clear();
        sharingScreen = false;
        _log('Screen sharing stopped');
      } else {
        _screenSub = _screenEvents.receiveBroadcastStream().listen((e) {
          if (e is Uint8List) screenBus.add(e);
        });
        final ok = await _native.invokeMethod<bool>('startScreen');
        sharingScreen = ok == true;
        if (!sharingScreen) {
          await _screenSub?.cancel();
          _screenSub = null;
        }
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
    try {
      if (sharingCam) {
        await _native.invokeMethod('stopCamera');
        await _camSub?.cancel();
        _camSub = null;
        camBus.clear();
        sharingCam = false;
        await WakelockPlus.disable();
        _log('Camera stopped');
      } else {
        _camSub = _camEvents.receiveBroadcastStream().listen((e) {
          if (e is Uint8List) camBus.add(e);
        });
        final rot = await _native.invokeMethod<int>('startCamera');
        if (rot == null || rot < 0) {
          await _camSub?.cancel();
          _camSub = null;
          _log('Camera could not start (permission denied?)');
        } else {
          camRotation = rot;
          sharingCam = true;
          await WakelockPlus.enable();
          _log('Camera is on. Keep this app open on your phone.');
        }
      }
    } catch (e) {
      _log('Camera failed: $e');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _clipTimer?.cancel();
    _server?.close(force: true);
    super.dispose();
  }
}

