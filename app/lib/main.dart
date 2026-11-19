import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'local/session.dart';
import 'ui/home_screen.dart';
import 'ui/pair_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const ProviderScope(child: LoomiApp()));

class LoomiApp extends StatelessWidget {
  const LoomiApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Loomi',
        debugShowCheckedModeBanner: false,
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: loomiTheme(),
        themeMode: ThemeMode.dark,
        builder: (context, child) => AuroraBackground(child: child ?? const SizedBox()),
        home: const Root(),
      );
}

/// Shows pairing until this device is connected to a Loomi Server.
class Root extends ConsumerWidget {
  const Root({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: ref.watch(sessionProvider).when(
              data: (s) => s == null ? const PairScreen() : HomeScreen(key: ValueKey(s.url), session: s),
              loading: () => const Scaffold(body: Center(child: LoomiLogo(size: 96))),
              error: (e, _) => const PairScreen(),
            ),
      );
}
