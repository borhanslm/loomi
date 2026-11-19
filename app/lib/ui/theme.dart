// Loomi design system: dark-first "aurora" look — deep ink, violet → cyan light,
// a warm amber spark, glass cards, and the Vazirmatn font (Persian + Latin).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

class Loomi {
  static const ink = Color(0xFF0B0A1C);
  static const ink2 = Color(0xFF151036);
  static const violet = Color(0xFF7C5CFF);
  static const violetSoft = Color(0xFFC4B5FD);
  static const cyan = Color(0xFF22D3EE);
  static const amber = Color(0xFFFFB547);
  static const text = Color(0xFFF4F2FF);
  static const muted = Color(0xFFA9A3C9);
  static const danger = Color(0xFFFF7B7B);
  static const ok = Color(0xFF4ADE80);
  static const glass = Color(0x14FFFFFF);
  static const glassBorder = Color(0x22FFFFFF);
  static const gradient = LinearGradient(colors: [violet, Color(0xFF5B8CFF), cyan], begin: AlignmentDirectional.centerStart, end: AlignmentDirectional.centerEnd);
  static const radius = 20.0;
}

ThemeData loomiTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Vazirmatn',
    colorScheme: ColorScheme.fromSeed(seedColor: Loomi.violet, brightness: Brightness.dark).copyWith(
      primary: Loomi.violet, secondary: Loomi.cyan, tertiary: Loomi.amber, surface: Loomi.ink2, error: Loomi.danger,
      onSurface: Loomi.text,
    ),
    scaffoldBackgroundColor: Colors.transparent,
  );
  final t = base.textTheme.apply(bodyColor: Loomi.text, displayColor: Loomi.text, fontFamily: 'Vazirmatn');
  return base.copyWith(
    textTheme: t.copyWith(
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.3),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.7),
      bodySmall: t.bodySmall?.copyWith(color: Loomi.muted, height: 1.6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x0FFFFFFF),
      labelStyle: const TextStyle(color: Loomi.muted),
      floatingLabelStyle: const TextStyle(color: Loomi.violetSoft),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Loomi.glassBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Loomi.glassBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Loomi.violet, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Loomi.ink2,
      contentTextStyle: const TextStyle(fontFamily: 'Vazirmatn', color: Loomi.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Loomi.glassBorder)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Loomi.ink2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Loomi.glassBorder)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Loomi.violetSoft, minimumSize: const Size(48, 48))),
    dividerTheme: const DividerThemeData(color: Loomi.glassBorder),
  );
}

/// Slowly drifting aurora light behind every screen. Still when the OS asks for reduced motion.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;
  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        const Positioned.fill(child: ColoredBox(color: Loomi.ink)),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) {
              final t = _c.value * 2 * math.pi;
              return CustomPaint(painter: _AuroraPainter(t));
            },
          ),
        ),
        Positioned.fill(child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60), child: const SizedBox())),
        widget.child,
      ]);
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size s) {
    void blob(Offset c, double r, Color color) {
      canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: r)));
    }

    final m = math.max(s.width, s.height);
    blob(Offset(s.width * (.15 + .06 * math.sin(t)), s.height * (.08 + .04 * math.cos(t))), m * .55, Loomi.violet.withValues(alpha: .42));
    blob(Offset(s.width * (.95 + .05 * math.cos(t * .8)), s.height * (.55 + .06 * math.sin(t * .7))), m * .5, Loomi.cyan.withValues(alpha: .20));
    blob(Offset(s.width * (.5 + .1 * math.sin(t * .6)), s.height * (1.02 + .03 * math.cos(t))), m * .45, const Color(0xFF5B3DF5).withValues(alpha: .28));
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

/// Frosted glass panel.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.highlight = false});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlight;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(Loomi.radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: highlight ? Loomi.violet.withValues(alpha: .14) : Loomi.glass,
              borderRadius: BorderRadius.circular(Loomi.radius),
              border: Border.all(color: highlight ? Loomi.violet.withValues(alpha: .45) : Loomi.glassBorder),
            ),
            child: child,
          ),
        ),
      );
}

/// Main call to action: violet → cyan gradient pill.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled ? 1 : .6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: Loomi.gradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Loomi.violet.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: 54,
                child: Center(
                  child: busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          if (icon != null) ...[Icon(icon, color: Colors.white, size: 22), const SizedBox(width: 10)],
                          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                        ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Loomi mark, with an optional soft glow that "breathes".
class LoomiLogo extends StatefulWidget {
  const LoomiLogo({super.key, this.size = 72, this.glow = true});
  final double size;
  final bool glow;
  @override
  State<LoomiLogo> createState() => _LoomiLogoState();
}

class _LoomiLogoState extends State<LoomiLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.glow && !still) {
      _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = Image.asset('assets/brand/mark.png', width: widget.size, height: widget.size * 284 / 336, semanticLabel: 'Loomi');
    if (!widget.glow) return img;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
          BoxShadow(color: Loomi.violet.withValues(alpha: .25 + .2 * _c.value), blurRadius: widget.size * .6, spreadRadius: widget.size * .05),
        ]),
        child: child,
      ),
      child: img,
    );
  }
}

/// "Connected / connecting" chip with a pulsing dot.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.online});
  final bool online;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: (online ? Loomi.ok : Loomi.amber).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: (online ? Loomi.ok : Loomi.amber).withValues(alpha: .35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: online ? Loomi.ok : Loomi.amber, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(online ? 'وصل' : 'در حال اتصال…', style: TextStyle(color: online ? Loomi.ok : Loomi.amber, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Section title used on the home screen.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?trailing,
        ]),
      );
}
