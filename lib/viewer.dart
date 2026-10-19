import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' as w32;
import 'package:window_manager/window_manager.dart';

import 'service.dart';
import 'theme.dart';

/// Windows only. Turns the app window into a floating, rounded, always-on-top
/// window that shows the phone screen or camera, like a phone on your desk.
/// Drag it to move it, use the corner or the + and - buttons to resize it,
/// press Esc to close it and get the normal window back.
class FloatViewer extends StatefulWidget {
  const FloatViewer({super.key, required this.svc, required this.kind});

  final LinkService svc;
  final String kind; // 'screen' or 'cam'

  @override
  State<FloatViewer> createState() => _FloatViewerState();
}

class _FloatViewerState extends State<FloatViewer> with WindowListener {
  WebSocket? _ws;
  ui.Image? _img;
  int _turns = 0;
  bool _run = true;
  bool _hover = false;
  bool _pinned = true;
  double _aspect = 0;
  int _hwnd = 0;
  Rect? _prev;
  String _status = 'Waiting for the phone to start sharing…';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _enter();
    _connect();
  }

  Future<void> _enter() async {
    try {
      _prev = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(160, 160));
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(360, 780));
      _hwnd = w32.GetForegroundWindow();
      await Future.delayed(const Duration(milliseconds: 80));
      _round();
    } catch (_) {}
  }

  Future<void> _exit() async {
    try {
      if (_hwnd != 0) w32.SetWindowRgn(_hwnd, 0, 1);
      await windowManager.setAspectRatio(0);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(const Size(900, 600));
      final p = _prev;
      if (p != null) await windowManager.setBounds(p);
    } catch (_) {}
  }

  /// Gives the window rounded corners.
  void _round() {
    if (_hwnd == 0) return;
    final rect = calloc<w32.RECT>();
    try {
      if (w32.GetWindowRect(_hwnd, rect) == 0) return;
      final w = rect.ref.right - rect.ref.left;
      final h = rect.ref.bottom - rect.ref.top;
      final ell = (min(w, h) * 0.2).round();
      final rgn = w32.CreateRoundRectRgn(0, 0, w + 1, h + 1, ell, ell);
      w32.SetWindowRgn(_hwnd, rgn, 1);
    } catch (_) {
    } finally {
      calloc.free(rect);
    }
  }

  @override
  void onWindowResize() => _round();

  @override
  void onWindowResized() => _round();

  Future<void> _connect() async {
    while (_run) {
      try {
        final svc = widget.svc;
        final ws = await WebSocket.connect(
          'ws://${svc.peerHost}:$kPort/ws/${widget.kind}',
          headers: {'x-token': svc.token ?? ''},
          compression: CompressionOptions.compressionOff,
        ).timeout(const Duration(seconds: 4));
        _ws = ws;
        final done = Completer<void>();
        ws.listen(_onData, onDone: () {
          if (!done.isCompleted) done.complete();
        }, onError: (_) {
          if (!done.isCompleted) done.complete();
        }, cancelOnError: true);
        await done.future;
      } catch (_) {}
      if (_run && mounted) {
        setState(() => _status = 'Waiting for the phone…');
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  void _onData(dynamic data) {
    if (data is String) {
      try {
        final j = jsonDecode(data);
        _turns = (((j['rot'] ?? 0) as int) ~/ 90) % 4;
      } catch (_) {}
      return;
    }
    if (data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      ui.decodeImageFromList(bytes, (img) {
        if (!mounted || !_run) {
          img.dispose();
          return;
        }
        final old = _img;
        setState(() => _img = img);
        if (old != null) {
          Future.delayed(const Duration(milliseconds: 300), old.dispose);
        }
        _checkAspect(img);
        try {
          _ws?.add('r');
        } catch (_) {}
      });
    }
  }

  void _checkAspect(ui.Image img) {
    var w = img.width.toDouble();
    var h = img.height.toDouble();
    if (_turns.isOdd) {
      final t = w;
      w = h;
      h = t;
    }
    final a = w / h;
    if ((a - _aspect).abs() > 0.01) {
      _aspect = a;
      _fit(a);
    }
  }

  /// Makes the window the same shape as the phone screen.
  Future<void> _fit(double a) async {
    try {
      var h = 780.0;
      var w = h * a;
      if (w > 900) {
        w = 900;
        h = w / a;
      }
      await windowManager.setAspectRatio(a);
      await windowManager.setSize(Size(w, h));
      await Future.delayed(const Duration(milliseconds: 80));
      _round();
    } catch (_) {}
  }

  Future<void> _scale(double f) async {
    try {
      final s = await windowManager.getSize();
      await windowManager.setSize(Size(s.width * f, s.height * f));
      await Future.delayed(const Duration(milliseconds: 80));
      _round();
    } catch (_) {}
  }

  void _rotate() {
    setState(() => _turns = (_turns + 1) % 4);
    final img = _img;
    if (img != null) {
      _aspect = 0;
      _checkAspect(img);
    }
  }

  Future<void> _togglePin() async {
    _pinned = !_pinned;
    await windowManager.setAlwaysOnTop(_pinned);
    if (mounted) setState(() {});
  }

  void _close() => Navigator.of(context).pop();

  @override
  void dispose() {
    _run = false;
    try {
      _ws?.close();
    } catch (_) {}
    windowManager.removeListener(this);
    _img?.dispose();
    _exit();
    super.dispose();
  }

  Widget _tool(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon,
              size: 18, color: active ? kTeal : Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: img == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(_status,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: kMuted)),
                          ),
                        )
                      : RotatedBox(
                          quarterTurns: _turns,
                          child: RawImage(
                            image: img,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                ),
              ),
              Positioned(
                top: 14,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Center(
                      child: Glass(
                        radius: 22,
                        blur: 18,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          _tool(Icons.remove, 'Smaller', () => _scale(0.9)),
                          _tool(Icons.add, 'Bigger', () => _scale(1.1)),
                          _tool(Icons.rotate_right, 'Rotate', _rotate),
                          _tool(Icons.push_pin, 'Always on top', _togglePin,
                              active: _pinned),
                          _tool(Icons.close, 'Close (Esc)', _close),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanStart: (_) =>
                      windowManager.startResizing(ResizeEdge.bottomRight),
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: SizedBox(width: 30, height: 30),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
