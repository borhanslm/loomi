import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:loomi/api/loomi_api.dart';
import 'package:loomi/local/session.dart';
import 'package:loomi/main.dart';

class MemoryStore implements SessionStore {
  Session? s;
  @override
  Future<Session?> read() async => s;
  @override
  Future<void> write(Session v) async => s = v;
  @override
  Future<void> clear() async => s = null;
}

void main() {
  group('normalizeServerUrl', () {
    test('adds https for public hosts and http for private ones', () {
      expect(normalizeServerUrl('loomi.example.com/'), 'https://loomi.example.com');
      expect(normalizeServerUrl('192.168.1.5:8787'), 'http://192.168.1.5:8787');
      expect(normalizeServerUrl('100.64.0.2:8787'), 'http://100.64.0.2:8787');
      expect(normalizeServerUrl(' https://x.io// '), 'https://x.io');
    });
  });

  group('PairInvite', () {
    test('reads the server QR', () {
      final i = PairInvite.parse('{"loomi":1,"url":"https://l.example","code":"1234 5678"}')!;
      expect(i.url, 'https://l.example');
      expect(i.code, '12345678');
    });
    test('rejects foreign QR codes', () {
      expect(PairInvite.parse('https://evil.example'), isNull);
      expect(PairInvite.parse('{"url":"x","code":"1"}'), isNull);
    });
  });

  testWidgets('shows the pairing screen when not connected, in RTL', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionStoreProvider.overrideWithValue(MemoryStore())],
      child: const LoomiApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('سلام، من لومی هستم'), findsOneWidget);
    expect(find.text('اتصال'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('اتصال'))), TextDirection.rtl);

    await tester.tap(find.text('اتصال'));
    await tester.pump();
    expect(find.text('آدرس سرور و کد ۸ رقمی را وارد کنید.'), findsOneWidget);
  });
}
