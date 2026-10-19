import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'service.dart';
import 'theme.dart';

// Direct calls into Windows (only touched when the window is shown on Windows).
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');
final int Function() _getForegroundWindow =
    _user32.lookupFunction<IntPtr Function(), int Function()>(
        'GetForegroundWindow');
final int Function(int, Pointer<Int32>) _getWindowRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Int32>),
    int Function(int, Pointer<Int32>)>('GetWindowRect');
final int Function(int, int, int) _setWindowRgn = _user32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Int32),
    int Function(int, int, int)>('SetWindowRgn');
final int Function(int, int, int, int, int, int) _createRoundRectRgn =
    _gdi32.lookupFunction<
        IntPtr Function(Int32, Int32, Int32, Int32, Int32, Int32),
        int Function(int, int, int, int, int, int)>('CreateRoundRectRgn');

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
  bool _ctl = false;
  Size _box = const Size(1, 1);
  Offset _p0 = Offset.zero;
  Offset _p1 = Offset.zero;
  DateTime _t0 = DateTime.now();
  String _note = '';
  Timer? _noteTimer;
  double _aspect = 0;
  int _hwnd = 0;
  Rect? _prev;
  String _status = 'Waiting for the phone to start sharing…';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _ctl = widget.kind == 'screen';
    if (_ctl) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _send({'t': 'key', 'k': ''});
        _say('Control is on: click to tap, drag to swipe, scroll with the '
            'wheel, right-click for Back.');
      });
    }
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
      _hwnd = _getForegroundWindow();
      await Future.delayed(const Duration(milliseconds: 80));
      _round();
    } catch (_) {}
  }

  Future<void> _exit() async {
    try {
      if (_hwnd != 0) _setWindowRgn(_hwnd, 0, 1);
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
    final rect = calloc<Int32>(4);
    try {
      if (_getWindowRect(_hwnd, rect) == 0) return;
      final w = rect[2] - rect[0];
      final h = rect[3] - rect[1];
      final ell = (min(w, h) * 0.2).round();
      final rgn = _createRoundRectRgn(0, 0, w + 1, h + 1, ell, ell);
      _setWindowRgn(_hwnd, rgn, 1);
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


  void _say(String t) {
    setState(() => _note = t);
    _noteTimer?.cancel();
    _noteTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _note = '');
    });
  }

  Future<void> _send(Map<String, dynamic> m) async {
    final code = await widget.svc.sendControl(m);
    if (code == 409) {
      _say('On your phone: Settings, Accessibility, Link my Windows, turn on.');
    } else if (code != 200 && mounted) {
      _say('Could not reach the phone.');
    }
  }

  void _toggleCtl() {
    setState(() => _ctl = !_ctl);
    if (_ctl) {
      _say('Control is on: click, drag and type. Use the top bar to move '
          'this window.');
      _send({'t': 'key', 'k': ''});
    }
  }

  void _tapAt(Offset p) {
    _send({
      't': 'tap',
      'x': (p.dx / _box.width).clamp(0.0, 1.0),
      'y': (p.dy / _box.height).clamp(0.0, 1.0),
    });
  }

  void _swipeEnd() {
    final ms = DateTime.now().difference(_t0).inMilliseconds;
    _send({
      't': 'swipe',
      'x1': (_p0.dx / _box.width).clamp(0.0, 1.0),
      'y1': (_p0.dy / _box.height).clamp(0.0, 1.0),
      'x2': (_p1.dx / _box.width).clamp(0.0, 1.0),
      'y2': (_p1.dy / _box.height).clamp(0.0, 1.0),
      'ms': ms < 80 ? 80 : (ms > 700 ? 700 : ms),
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent ev) {
    if (!_ctl || ev is KeyUpEvent) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    if (k == LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && k == LogicalKeyboardKey.keyV) {
      Clipboard.getData('text/plain').then((d) {
        final t = d?.text ?? '';
        if (t.isNotEmpty) _send({'t': 'text', 's': t});
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _send({'t': 'bs'});
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter) {
      _send({'t': 'enter'});
      return KeyEventResult.handled;
    }
    final ch = ev.character;
    if (!ctrl && ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _send({'t': 'text', 's': ch});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);

  void _wheel(PointerSignalEvent e) {
    if (!_ctl || e is! PointerScrollEvent) return;
    final now = DateTime.now();
    if (now.difference(_lastWheel).inMilliseconds < 110) return;
    _lastWheel = now;
    final x = (e.localPosition.dx / _box.width).clamp(0.05, 0.95);
    final y = (e.localPosition.dy / _box.height).clamp(0.2, 0.8);
    final d = e.scrollDelta.dy > 0 ? 0.22 : -0.22;
    _send({
      't': 'swipe',
      'x1': x,
      'y1': y,
      'x2': x,
      'y2': (y - d).clamp(0.02, 0.98),
      'ms': 140,
    });
  }

  void _pointerDown(PointerDownEvent e) {
    if (!_ctl) return;
    if (e.buttons == kSecondaryMouseButton) {
      _send({'t': 'key', 'k': 'back'});
    } else if (e.buttons == kMiddleMouseButton) {
      _send({'t': 'key', 'k': 'home'});
    }
  }

  void _close() => Navigator.of(context).pop();

  @override
  void dispose() {
    _run = false;
    _noteTimer?.cancel();
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
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Stack(children: [
              Positioned.fill(
                child: LayoutBuilder(builder: (context, c) {
                  _box = Size(c.maxWidth < 1 ? 1 : c.maxWidth,
                      c.maxHeight < 1 ? 1 : c.maxHeight);
                  return Listener(
                    onPointerSignal: _wheel,
                    onPointerDown: _pointerDown,
                    child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _ctl ? (d) => _tapAt(d.localPosition) : null,
                  onPanDown: _ctl
                      ? (d) {
                          _p0 = d.localPosition;
                          _p1 = d.localPosition;
                          _t0 = DateTime.now();
                        }
                      : null,
                  onPanStart:
                      _ctl ? null : (_) => windowManager.startDragging(),
                  onPanUpdate: _ctl ? (d) => _p1 = d.localPosition : null,
                  onPanEnd: _ctl ? (_) => _swipeEnd() : null,
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
                  );
                }),
              ),
              // Grab bar to move the window while control is on
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 26,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: const EdgeInsets.only(top: 6),
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: wh(_ctl ? 0.55 : 0),
                        borderRadius: BorderRadius.circular(2),
                      ),
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
                          if (widget.kind == 'screen')
                            _tool(Icons.touch_app, 'Control the phone',
                                _toggleCtl,
                                active: _ctl),
                          if (widget.kind == 'screen' && _ctl) ...[
                            _tool(Icons.arrow_back, 'Back',
                                () => _send({'t': 'key', 'k': 'back'})),
                            _tool(Icons.circle_outlined, 'Home',
                                () => _send({'t': 'key', 'k': 'home'})),
                            _tool(Icons.crop_square, 'Recent apps',
                                () => _send({'t': 'key', 'k': 'recents'})),
                          ],
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
              if (_note.isNotEmpty)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 18,
                  child: IgnorePointer(
                    child: Glass(
                      radius: 18,
                      blur: 18,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Text(_note,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12.5, height: 1.3)),
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
