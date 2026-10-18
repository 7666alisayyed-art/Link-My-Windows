import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const int kPort = 48080;
const Color kBg = Color(0xFF0B1220);
const Color kCard = Color(0xFF111A2E);
const Color kBorder = Color(0xFF1E2A44);
const Color kBlue = Color(0xFF2563EB);

void main() => runApp(const LinkApp());

/// Runs a tiny web server on this device and talks to the other device's server.
/// The same code runs on Android and Windows.
class LinkService extends ChangeNotifier {
  final String code = (100000 + Random.secure().nextInt(900000)).toString();
  final String deviceName = Platform.localHostname;
  final Set<String> _tokens = {};
  final List<String> log = [];
  List<String> ips = [];
  HttpServer? _server;
  String? peerHost;
  String? peerName;
  String? token;

  bool get linked => peerHost != null && token != null;

  void _log(String line) {
    log.insert(0, line);
    if (log.length > 50) log.removeLast();
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

  Future<void> sendText(String text) async {
    if (!linked || text.isEmpty) return;
    try {
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

  @override
  void dispose() {
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

  List<Widget> pairView() => [
        const Text('Link your devices',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text(
            'Open this app on your phone and your PC, on the same Wi-Fi. '
            'Type the other device\'s IP address and pairing code below.',
            style: TextStyle(color: Color(0xFF94A3B8), height: 1.4)),
        const SizedBox(height: 20),
        card([
          const Text('This device',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (svc.ips.isEmpty)
            const Text('No Wi-Fi address found')
          else
            for (final ip in svc.ips) SelectableText('IP address: $ip'),
          const SizedBox(height: 10),
          const Text('Pairing code',
              style: TextStyle(color: Color(0xFF94A3B8))),
          SelectableText(svc.code,
              style: const TextStyle(
                  fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: 6)),
        ]),
        card([
          const Text('Link to the other device',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
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
                      final e = await svc.pair(
                          hostC.text.trim(), codeC.text.trim());
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
              child: Text(l, style: const TextStyle(color: Color(0xFF94A3B8)))),
      ];

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
        SizedBox(
          height: 52,
          child: FilledButton.icon(
              onPressed: svc.sendClipboard,
              icon: const Icon(Icons.content_paste),
              label: const Text('Send my clipboard')),
        ),
        const SizedBox(height: 12),
        card([
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
        SizedBox(
          height: 52,
          child: FilledButton.tonalIcon(
              onPressed: svc.sendFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Send a file')),
        ),
        const SizedBox(height: 8),
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
