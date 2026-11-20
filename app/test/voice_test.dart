import 'package:flutter_test/flutter_test.dart';
import 'package:loomi/local/voice.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('EndOfSpeech', () {
    test('stops after a quiet moment that follows speech', () {
      final e = EndOfSpeech();
      expect(e.add(-60, ms(0)), isFalse); // room noise before talking
      expect(e.add(-20, ms(500)), isFalse); // talking
      expect(e.add(-25, ms(900)), isFalse);
      expect(e.add(-55, ms(1000)), isFalse); // a pause starts
      expect(e.add(-55, ms(2000)), isFalse);
      expect(e.add(-55, ms(2600)), isTrue); // 1.6 s of quiet
      expect(e.heardSpeech, isTrue);
    });

    test('a short breath does not stop it', () {
      final e = EndOfSpeech();
      e.add(-20, ms(0));
      e.add(-55, ms(200));
      expect(e.add(-55, ms(1000)), isFalse);
      expect(e.add(-20, ms(1200)), isFalse); // talking again resets the pause
      expect(e.add(-55, ms(1300)), isFalse);
      expect(e.add(-55, ms(2800)), isFalse);
      expect(e.add(-55, ms(2950)), isTrue);
    });

    test('in-between loudness neither speaks nor counts as quiet', () {
      final e = EndOfSpeech();
      e.add(-20, ms(0));
      expect(e.add(-42, ms(5000)), isFalse);
    });

    test('gives up when nobody talks, and caps the length', () {
      final silent = EndOfSpeech();
      expect(silent.add(-70, ms(7900)), isFalse);
      expect(silent.add(-70, ms(8000)), isTrue);
      expect(silent.heardSpeech, isFalse);

      final long = EndOfSpeech();
      long.add(-20, ms(0));
      expect(long.add(-20, const Duration(seconds: 60)), isTrue);
    });
  });
}
