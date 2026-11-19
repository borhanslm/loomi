import 'package:flutter_test/flutter_test.dart';
import 'package:loomi/local/updater.dart';

void main() {
  test('compares versions numerically', () {
    expect(compareVersions('0.5.0', '0.4.0'), 1);
    expect(compareVersions('v0.10.0', '0.9.9'), 1);
    expect(compareVersions('0.4.0', '0.4.0+4'), 0);
    expect(compareVersions('0.4.0', '0.4.1'), -1);
    expect(compareVersions('1.0', '0.99.99'), 1);
  });

  test('reads a GitHub release', () {
    final i = parseRelease({
      'tag_name': 'v0.5.0', 'html_url': 'https://github.com/borhanslm/loomi/releases/tag/v0.5.0', 'draft': false, 'prerelease': false,
      'assets': [
        {'name': 'Loomi.apk', 'browser_download_url': 'https://github.com/x/Loomi.apk'},
        {'name': 'Loomi-Setup.exe', 'browser_download_url': 'https://github.com/x/Loomi-Setup.exe'},
      ],
    })!;
    expect(i.version, '0.5.0');
    expect(i.apkUrl, 'https://github.com/x/Loomi.apk');
    expect(i.exeUrl, 'https://github.com/x/Loomi-Setup.exe');
    expect(parseRelease({'tag_name': 'v0.6.0', 'prerelease': true}), isNull);
  });
}
