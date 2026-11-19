import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'local/session.dart';
import 'ui/home_screen.dart';
import 'ui/pair_screen.dart';

void main() => runApp(const ProviderScope(child: LoomiApp()));

const loomiSeed = Color(0xFF6D5BD0); // Loomi violet

ThemeData loomiTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: loomiSeed, brightness: b),
      visualDensity: VisualDensity.standard,
    );

class LoomiApp extends StatelessWidget {
  const LoomiApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'لومی',
        debugShowCheckedModeBanner: false,
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: loomiTheme(Brightness.light),
        darkTheme: loomiTheme(Brightness.dark),
        home: const Root(),
      );
}

/// Shows pairing until this device is connected to a Loomi Server.
class Root extends ConsumerWidget {
  const Root({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref.watch(sessionProvider).when(
        data: (s) => s == null ? const PairScreen() : HomeScreen(session: s),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => const PairScreen(),
      );
}
