// Windows: Loomi draws its own title bar (instead of the system one, which takes the user's
// accent colour) — logo, name, drag to move, double-click to maximise, and the window buttons.
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';

bool get isDesktopWindow {
  try {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false; // widget tests have no real window
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  } catch (_) {
    return false; // web
  }
}

Future<void> initWindow() async {
  if (!isDesktopWindow) return;
  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    title: 'Loomi',
    size: Size(1240, 800),
    minimumSize: Size(420, 560),
    center: true,
    backgroundColor: Loomi.ink,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key, this.trailing});
  final Widget? trailing;
  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) { if (mounted) setState(() => _max = v); });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  @override
  Widget build(BuildContext context) {
    // Window buttons stay where Windows users expect them (top right), whatever the text direction.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        height: 40,
        child: Row(children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(
                padding: const EdgeInsets.only(left: 14),
                alignment: Alignment.centerLeft,
                child: Row(children: [
                  Image.asset('assets/brand/mark.png', width: 22, semanticLabel: 'Loomi'),
                  const SizedBox(width: 8),
                  const Text('Loomi', style: TextStyle(color: Loomi.text, fontWeight: FontWeight.w700, fontSize: 13.5, letterSpacing: .2)),
                  if (widget.trailing != null) ...[const SizedBox(width: 12), widget.trailing!],
                ]),
              ),
            ),
          ),
          _CaptionButton(icon: Icons.remove_rounded, tooltip: 'کوچک کردن', onTap: windowManager.minimize),
          _CaptionButton(
            icon: _max ? Icons.filter_none_rounded : Icons.crop_square_rounded,
            iconSize: _max ? 14 : 16,
            tooltip: _max ? 'برگرداندن' : 'بزرگ کردن',
            onTap: () => _max ? windowManager.unmaximize() : windowManager.maximize(),
          ),
          _CaptionButton(icon: Icons.close_rounded, tooltip: 'بستن', onTap: windowManager.close, danger: true),
        ]),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.icon, required this.tooltip, required this.onTap, this.danger = false, this.iconSize = 18});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
  final double iconSize;
  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 46,
              height: 40,
              color: _hover ? (widget.danger ? const Color(0xFFC42B1C) : const Color(0x1AFFFFFF)) : Colors.transparent,
              child: Icon(widget.icon, size: widget.iconSize, color: _hover && widget.danger ? Colors.white : Loomi.muted),
            ),
          ),
        ),
      );
}
