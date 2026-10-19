import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'scanner.dart';
import 'service.dart';
import 'theme.dart';
import 'viewer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1120, 740),
      minimumSize: Size(900, 620),
      center: true,
      title: 'Link my Windows',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const LinkApp());
}

class LinkApp extends StatelessWidget {
  const LinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c, width: w),
        );
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: const ColorScheme.dark(primary: kBlue, surface: Colors.black),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: wh(0.08),
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: b(wh(0.18)),
        enabledBorder: b(wh(0.18)),
        focusedBorder: b(kTeal, 1.5),
        labelStyle: const TextStyle(color: kMuted),
      ),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: kTeal),
    );
    return MaterialApp(
      title: 'Link my Windows',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final svc = LinkService();
  final hostC = TextEditingController();
  final codeC = TextEditingController();
  final textC = TextEditingController();
  String? error;
  bool busy = false;
  int page = 0;

  bool get win => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    svc.start().then((_) => svc.handleShared());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) svc.onResume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    svc.dispose();
    hostC.dispose();
    codeC.dispose();
    textC.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    final e = await svc.pair(hostC.text.trim(), codeC.text.trim());
    if (mounted) {
      setState(() {
        busy = false;
        error = e;
      });
    }
  }

  Future<void> scan() async {
    final value = await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) => const ScannerPage(),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: kSmooth),
          child: child,
        ),
      ),
    );
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

  void openFloat(String kind) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => FloatViewer(svc: svc, kind: kind),
    ));
  }

  // ------------------------------------------------------------- pieces

  Widget card(String title, List<Widget> children, {IconData? icon}) {
    return Glass(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: kTeal),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2)),
            ),
          ]),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget body(String t) => Text(t,
      style: const TextStyle(color: kMuted, height: 1.45, fontSize: 14.5));

  Widget gap([double h = 12]) => SizedBox(height: h);

  Widget errorText() => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: const TextStyle(color: kRed)),
        );

  Widget qrTile(double size) => Center(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(color: kBlue.withAlpha(90), blurRadius: 36),
            ],
          ),
          child: QrImageView(
            data: svc.qrData,
            size: size,
            backgroundColor: Colors.white,
          ),
        ),
      );

  Widget codeBlock() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final ip in svc.ips)
            SelectableText('IP address  $ip',
                style: const TextStyle(color: kMuted)),
          gap(10),
          const Text('Pairing code', style: TextStyle(color: kMuted)),
          SelectableText(svc.code,
              style: const TextStyle(
                  fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: 8)),
        ],
      );

  Widget manualCard() => card('Link manually', [
        body('If scanning does not work, type the other device\'s IP address '
            'and pairing code.'),
        gap(),
        TextField(
          controller: hostC,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'IP address'),
        ),
        gap(),
        TextField(
          controller: codeC,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Pairing code'),
        ),
        errorText(),
        gap(16),
        GlassButton(
          label: busy ? 'Connecting…' : 'Connect',
          primary: true,
          onTap: busy ? null : connect,
        ),
      ], icon: Icons.keyboard_outlined);

  Widget needLinkCard() => card('Not linked yet', [
        body('Link your devices first.'),
        gap(14),
        GlassButton(
          label: 'Go to Link',
          primary: true,
          onTap: () => setState(() => page = 0),
        ),
      ], icon: Icons.link_off);

  // -------------------------------------------------------------- pages

  List<Widget> linkPage() {
    if (svc.linked) {
      return [
        card('Connected', [
          Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kGreen.withAlpha(50),
                border: Border.all(color: kGreen.withAlpha(150)),
              ),
              child: Icon(win ? Icons.smartphone : Icons.desktop_windows,
                  color: kGreen),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(svc.peerName ?? 'Device',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  Text(svc.peerHost ?? '',
                      style: const TextStyle(color: kMuted)),
                ],
              ),
            ),
          ]),
          gap(18),
          GlassButton(
            label: 'Unlink',
            icon: Icons.link_off,
            danger: true,
            onTap: svc.unlink,
          ),
        ], icon: Icons.check_circle_outline),
      ];
    }
    if (win) {
      return [
        card('Scan with your phone', [
          body('Open Link my Windows on your phone, tap Scan QR code and point '
              'it at this code.'),
          gap(16),
          if (svc.ips.isNotEmpty) qrTile(210),
          gap(16),
          codeBlock(),
        ], icon: Icons.qr_code_2),
        manualCard(),
      ];
    }
    return [
      card('Instant link', [
        body('Open Link my Windows on your PC, then scan the QR code it '
            'shows. Both devices must be on the same Wi-Fi.'),
        gap(16),
        GlassButton(
          label: busy ? 'Connecting…' : 'Scan QR code',
          icon: Icons.qr_code_scanner,
          primary: true,
          height: 58,
          onTap: busy ? null : scan,
        ),
        errorText(),
      ], icon: Icons.bolt),
      card('This device', [
        if (svc.ips.isNotEmpty) qrTile(170),
        if (svc.ips.isNotEmpty) gap(16),
        if (svc.ips.isEmpty) body('No Wi-Fi address found.') else codeBlock(),
      ], icon: Icons.smartphone),
      manualCard(),
    ];
  }

  List<Widget> sharePage() {
    if (!svc.linked) return [needLinkCard()];
    if (win) {
      return [
        card('Phone screen', [
          body('Your phone screen in a floating, rounded window that stays on '
              'top of other apps, even when this app is minimised. Drag it '
              'anywhere, resize it from the corner, press Esc to close.'),
          gap(8),
          body('Tap "Share my screen" on the phone first.'),
          gap(16),
          GlassButton(
            label: 'Open phone screen',
            icon: Icons.smartphone,
            primary: true,
            onTap: () => openFloat('screen'),
          ),
        ], icon: Icons.screen_share_outlined),
        card('Phone camera', [
          body('Use your phone camera as a webcam in the same kind of '
              'floating window. Tap "Use as webcam" on the phone first and '
              'keep the app open there.'),
          gap(8),
          body('For Zoom, Meet or Teams: in OBS Studio add this window with '
              'Window Capture, then Start Virtual Camera.'),
          gap(16),
          GlassButton(
            label: 'Open phone camera',
            icon: Icons.videocam,
            onTap: () => openFloat('cam'),
          ),
        ], icon: Icons.videocam_outlined),
      ];
    }
    return [
      card('Share from this phone', [
        GlassButton(
          label: svc.sharingScreen ? 'Stop sharing screen' : 'Share my screen',
          icon:
              svc.sharingScreen ? Icons.stop_screen_share : Icons.screen_share,
          primary: !svc.sharingScreen,
          danger: svc.sharingScreen,
          height: 58,
          onTap: svc.toggleScreen,
        ),
        gap(),
        GlassButton(
          label: svc.sharingCam ? 'Turn camera off' : 'Use as webcam',
          icon: svc.sharingCam ? Icons.videocam_off : Icons.videocam,
          danger: svc.sharingCam,
          height: 58,
          onTap: svc.toggleCamera,
        ),
        gap(16),
        body('After you start one, open it from the Share page on your PC. '
            'Keep this app open while the camera is on.'),
      ], icon: Icons.ios_share),
    ];
  }

  List<Widget> clipboardPage() {
    if (!svc.linked) return [needLinkCard()];
    return [
      card('Clipboard sync', [
        Row(children: [
          Expanded(
            child: Text('Sync automatically',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          GlassSwitch(value: svc.autoClip, onChanged: svc.setAutoClip),
        ]),
        gap(8),
        body(win
            ? 'Copy on your PC and it appears on your phone within a second.'
            : 'Android only lets an app read the clipboard while it is open. '
                'Open this app after copying, or use Share, then Link my '
                'Windows, from any app.'),
        gap(16),
        GlassButton(
          label: 'Send my clipboard now',
          icon: Icons.content_paste,
          onTap: svc.sendClipboard,
        ),
      ], icon: Icons.content_paste_go),
      card('Send text', [
        TextField(
          controller: textC,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'Text to send'),
        ),
        gap(14),
        GlassButton(
          label: 'Send text',
          icon: Icons.send,
          primary: true,
          onTap: () {
            svc.sendText(textC.text);
            textC.clear();
          },
        ),
      ], icon: Icons.text_fields),
    ];
  }

  List<Widget> filesPage() {
    if (!svc.linked) return [needLinkCard()];
    return [
      card(win ? 'Send a file to your phone' : 'Send a file to your PC', [
        body('Pick any file and it is sent over your Wi-Fi.'),
        gap(16),
        GlassButton(
          label: 'Choose a file',
          icon: Icons.upload_file,
          primary: true,
          onTap: svc.sendFile,
        ),
      ], icon: Icons.upload_file),
      card('Received files', [
        body(win
            ? 'Files from your phone are saved in Downloads, in a folder '
                'called Link my Windows.'
            : 'Files from your PC are saved in this app\'s folder: Android, '
                'data, com.linkmywindows.link_my_windows, files, Link my '
                'Windows.'),
        if (win) ...[
          gap(16),
          GlassButton(
            label: 'Open the folder',
            icon: Icons.folder_open,
            onTap: svc.openReceivedFolder,
          ),
        ],
      ], icon: Icons.folder_open),
    ];
  }

  List<Widget> activityPage() => [
        card('Activity', [
          if (svc.log.isEmpty) body('Nothing yet.'),
          for (final l in svc.log)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(l, style: const TextStyle(color: kMuted)),
            ),
        ], icon: Icons.history),
      ];

  static const _titles = ['Link', 'Share', 'Clipboard', 'Files', 'Activity'];
  static const _icons = [
    Icons.link,
    Icons.screen_share_outlined,
    Icons.content_paste,
    Icons.folder_open,
    Icons.history,
  ];

  List<Widget> cardsFor(int p) {
    switch (p) {
      case 1:
        return sharePage();
      case 2:
        return clipboardPage();
      case 3:
        return filesPage();
      case 4:
        return activityPage();
      default:
        return linkPage();
    }
  }

  // ------------------------------------------------------------- layouts

  Widget statusPill() {
    final on = svc.linked;
    return Glass(
      radius: 20,
      blur: 16,
      shadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? kGreen : kMuted,
          ),
        ),
        const SizedBox(width: 8),
        Text(on ? (svc.peerName ?? 'Linked') : 'Not linked',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget phoneLayout() {
    final linked = svc.linked;
    final shown = linked ? page : 0;
    final cards = cardsFor(shown);
    return Stack(children: [
      SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
            child: Row(children: [
              const LmwLogo(size: 44),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Link my Windows',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5)),
              ),
              statusPill(),
            ]),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              switchInCurve: kSmooth,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.03), end: Offset.zero)
                      .animate(a),
                  child: child,
                ),
              ),
              child: Center(
                key: ValueKey('$shown-$linked'),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                        20, 10, 20, linked ? 120 : 30),
                    children: [
                      if (linked)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 6, 0, 14),
                          child: Text(_titles[shown],
                              style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1)),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 6, 0, 14),
                          child: Text('Link your\ndevices',
                              style: TextStyle(
                                  fontSize: 38,
                                  height: 1.05,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.2)),
                        ),
                      for (var i = 0; i < cards.length; i++)
                        Reveal(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: cards[i],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
      if (linked)
        Positioned(
          left: 18,
          right: 18,
          bottom: 0,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 14),
            child: GlassTabBar(
              icons: _icons,
              labels: _titles,
              index: page,
              onChanged: (i) => setState(() => page = i),
            ),
          ),
        ),
    ]);
  }

  Widget desktopLayout() {
    final cards = cardsFor(page);
    return Row(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 250,
          child: Glass(
            radius: 30,
            padding: const EdgeInsets.fromLTRB(14, 22, 14, 16),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 6),
                const LmwLogo(size: 40),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Link my\nWindows',
                      style: TextStyle(
                          fontSize: 17,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4)),
                ),
              ]),
              const SizedBox(height: 26),
              SizedBox(
                height: 52.0 * _titles.length,
                child: Stack(children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutBack,
                    top: 52.0 * page,
                    left: 0,
                    right: 0,
                    height: 48,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: wh(0.20),
                        border: Border.all(color: wh(0.28)),
                      ),
                    ),
                  ),
                  Column(children: [
                    for (var i = 0; i < _titles.length; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => page = i),
                        child: SizedBox(
                          height: 52,
                          child: Row(children: [
                            const SizedBox(width: 14),
                            Icon(_icons[i],
                                size: 20,
                                color: i == page ? Colors.white : kMuted),
                            const SizedBox(width: 14),
                            Text(_titles[i],
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: i == page ? Colors.white : kMuted)),
                          ]),
                        ),
                      ),
                  ]),
                ]),
              ),
              const Spacer(),
              statusPill(),
            ]),
          ),
        ),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: kSmooth,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 0.02), end: Offset.zero)
                  .animate(a),
              child: child,
            ),
          ),
          child: Align(
            key: ValueKey('$page-${svc.linked}'),
            alignment: Alignment.topLeft,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 34, 28, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 22),
                    child: Text(_titles[page],
                        style: const TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2)),
                  ),
                  Wrap(
                    spacing: 20,
                    runSpacing: 20,
                    children: [
                      for (var i = 0; i < cards.length; i++)
                        Reveal(
                          index: i,
                          child: SizedBox(width: 420, child: cards[i]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassBackground(child: win ? desktopLayout() : phoneLayout()),
      ),
    );
  }
}
