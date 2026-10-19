import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// Colours (system-style blues, indigo and teal on a deep night background)
const Color kBlue = Color(0xFF0A84FF);
const Color kIndigo = Color(0xFF5E5CE6);
const Color kTeal = Color(0xFF64D2FF);
const Color kGreen = Color(0xFF30D158);
const Color kRed = Color(0xFFFF453A);
const Color kMuted = Color(0x99EBEBF5);

Color wh(double o) => Color.fromRGBO(255, 255, 255, o);
Color bk(double o) => Color.fromRGBO(0, 0, 0, o);

const Curve kSmooth = Curves.easeOutCubic;

/// Slowly drifting colour glow behind everything, so the glass has
/// something to refract.
class GlassBackground extends StatefulWidget {
  const GlassBackground({super.key, required this.child});
  final Widget child;

  @override
  State<GlassBackground> createState() => _GlassBackgroundState();
}

class _GlassBackgroundState extends State<GlassBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 26))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _blob(Offset o, double r, Color c, int a) {
    return Positioned(
      left: o.dx - r,
      top: o.dy - r,
      child: IgnorePointer(
        child: Container(
          width: r * 2,
          height: r * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c.withAlpha(a), c.withAlpha(0)]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050A1C), Color(0xFF0A0F2E), Color(0xFF050814)],
          ),
        ),
      ),
      AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value * 2 * pi;
          return LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            final m = max(w, h);
            return Stack(children: [
              _blob(Offset(w * (0.2 + 0.12 * sin(t)), h * (0.16 + 0.08 * cos(t))),
                  m * 0.42, kBlue, 150),
              _blob(
                  Offset(w * (0.85 + 0.08 * cos(t + 1)),
                      h * (0.42 + 0.12 * sin(t + 2))),
                  m * 0.40,
                  kIndigo,
                  140),
              _blob(
                  Offset(w * (0.4 + 0.15 * sin(t + 3)),
                      h * (0.95 + 0.05 * cos(t))),
                  m * 0.38,
                  kTeal,
                  90),
            ]);
          });
        },
      ),
      widget.child,
    ]);
  }
}

/// A frosted, translucent surface with a bright edge and a soft highlight on
/// top, in the style of Apple's "liquid glass".
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 26,
    this.padding = EdgeInsets.zero,
    this.blur = 26,
    this.tint,
    this.shadow = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double blur;
  final Color? tint;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final top = tint ?? wh(0.20);
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow
            ? [
                BoxShadow(
                    color: bk(0.30),
                    blurRadius: 32,
                    offset: const Offset(0, 14)),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [top, wh(0.05)],
              ),
              border: Border.all(color: wh(0.24), width: 1),
            ),
            child: Stack(children: [
              Padding(padding: padding, child: child),
              Positioned(
                top: 0,
                left: radius,
                right: radius,
                height: 1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [wh(0), wh(0.7), wh(0)]),
                    ),
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

/// Springy press feedback.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: on ? (_) => setState(() => _down = true) : null,
      onTapUp: on ? (_) => setState(() => _down = false) : null,
      onTapCancel: on ? () => setState(() => _down = false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.95 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0.45,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Glass pill button. [primary] gives the blue glowing version.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
    this.expand = true,
    this.height = 52,
    this.danger = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool expand;
  final bool danger;
  final double height;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: danger ? kRed : Colors.white),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: danger ? kRed : Colors.white)),
        ),
      ],
    );
    final r = height / 2;
    Widget body;
    if (primary) {
      body = Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3AA0FF), kBlue, kIndigo],
          ),
          border: Border.all(color: wh(0.45), width: 1),
          boxShadow: [
            BoxShadow(
                color: kBlue.withAlpha(110),
                blurRadius: 24,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Center(child: content),
      );
    } else {
      body = Glass(
        radius: r,
        blur: 18,
        shadow: false,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: SizedBox(height: height - 2, child: Center(child: content)),
      );
    }
    return Pressable(
      onTap: onTap,
      child: expand ? SizedBox(width: double.infinity, child: body) : body,
    );
  }
}

/// iOS-style switch with a smooth slide.
class GlassSwitch extends StatelessWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: kSmooth,
        width: 54,
        height: 32,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? kGreen : wh(0.22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: wh(0.2)),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 280),
          curve: kSmooth,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: bk(0.3), blurRadius: 6, offset: const Offset(0, 2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades and slides a widget in when it first appears.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 520 + index * 80),
      curve: kSmooth,
      child: child,
      builder: (context, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 26 * (1 - v)), child: c),
      ),
    );
  }
}

/// The app logo: a phone and a monitor linked together, on glass.
class LmwLogo extends StatelessWidget {
  const LmwLogo({super.key, this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: size, height: size, child: CustomPaint(painter: _LogoPainter()));
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Rect.fromLTWH(0, 0, s, s);
    final bg = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.225));
    canvas.drawRRect(
      bg,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF64D2FF), kBlue, kIndigo],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipRRect(bg);
    final c = Offset(s * 0.2, s * 0.05);
    canvas.drawCircle(
      c,
      s * 0.7,
      Paint()
        ..shader = RadialGradient(colors: [wh(0.45), wh(0)])
            .createShader(Rect.fromCircle(center: c, radius: s * 0.7)),
    );
    canvas.restore();

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.03
      ..strokeCap = StrokeCap.round
      ..color = wh(0.95);

    final ph = RRect.fromLTRBR(
        s * 0.15, s * 0.40, s * 0.40, s * 0.82, Radius.circular(s * 0.075));

    // monitor (cut out where the phone sits in front of it)
    canvas.save();
    canvas.clipPath(Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      Path()..addRRect(ph),
    ));
    final mon = RRect.fromLTRBR(
        s * 0.26, s * 0.24, s * 0.84, s * 0.60, Radius.circular(s * 0.07));
    canvas.drawRRect(mon, Paint()..color = wh(0.20));
    canvas.drawRRect(mon, stroke);
    canvas.drawLine(Offset(s * 0.55, s * 0.60), Offset(s * 0.55, s * 0.70), stroke);
    canvas.drawLine(Offset(s * 0.45, s * 0.71), Offset(s * 0.65, s * 0.71), stroke);
    canvas.restore();

    // phone (in front, glassy)
    canvas.drawRRect(
      ph,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [wh(0.55), wh(0.22)],
        ).createShader(ph.outerRect),
    );
    canvas.drawRRect(ph, stroke);
    canvas.drawLine(
        Offset(s * 0.245, s * 0.46), Offset(s * 0.305, s * 0.46), stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Floating glass tab bar with a sliding highlight.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({
    super.key,
    required this.icons,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<IconData> icons;
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final n = icons.length;
    return Glass(
      radius: 34,
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        height: 60,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth / n;
          return Stack(children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutBack,
              left: w * index,
              top: 0,
              bottom: 0,
              width: w,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  color: wh(0.22),
                  border: Border.all(color: wh(0.3)),
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedScale(
                          scale: i == index ? 1.12 : 1,
                          duration: const Duration(milliseconds: 300),
                          curve: kSmooth,
                          child: Icon(icons[i],
                              size: 22,
                              color: i == index ? Colors.white : kMuted),
                        ),
                        const SizedBox(height: 3),
                        Text(labels[i],
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: i == index ? Colors.white : kMuted)),
                      ],
                    ),
                  ),
                ),
            ]),
          ]);
        }),
      ),
    );
  }
}
