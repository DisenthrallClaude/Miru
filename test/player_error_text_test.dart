import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/player/controller/player_error_text.dart';

void main() {
  test('CI 实际出现的 tcp 超时被翻译成可行动中文，不外泄主机名', () {
    final t = PlayerErrorText.humanize(
        'tcp: Connection to tcp://g.xlzyd.com:9999 failed: Connection timed out');
    expect(t, contains('超时'));
    expect(t, isNot(contains('xlzyd')));
  });
  test('常见类别', () {
    expect(PlayerErrorText.humanize('HTTP error 403 Forbidden'), contains('403'));
    expect(PlayerErrorText.humanize('HTTP error 404 Not Found'), contains('404'));
    expect(PlayerErrorText.humanize('Server returned 502 Bad Gateway'), contains('502'));
    expect(PlayerErrorText.humanize('crypto: Unable to open resource'), contains('加密'));
    expect(PlayerErrorText.humanize('Failed to open https://x/index.m3u8.'), contains('切换线路'));
    expect(PlayerErrorText.humanize('Could not open codec'), contains('解码'));
    expect(PlayerErrorText.humanize('something odd'), '播放遇到问题，可尝试切换线路');
  });
}
