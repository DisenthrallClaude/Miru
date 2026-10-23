// v1.7.0（P0-5）：http_seekable=0 撤销的源契约锁。
//
// 工单验收（原文）：「契约测试（参考 player_wiring_contract_test.dart
// 的源码断言风格）断言非 HLS 分支不包含 http_seekable=0」。
//
// 病灶：demuxer-lavf-o 作为 avformat 打开选项传给主输入的 http 协议，
// http_seekable=0 明确禁止 Range seek——对 HLS 影响不大（按分片请求），
// 但对 MP4/FLV/MKV 直链：拖动进度与 start 续播只能从头顺序读；
// moov box 在尾部的 MP4 甚至无法开播。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = File.fromUri(Directory.current.uri
      .resolve('lib/pages/player/controller/player_playback_controller.dart'));

  test('P0-5: 全源码不再下发 http_seekable=0', () {
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();
    // 只匹配字符串字面量（注释里对撤销的说明不算下发）。
    expect(source.contains("'http_seekable"), isFalse,
        reason: 'http_seekable=0 禁止 Range seek——MP4 直链无法拖动、'
            '历史续播失效、moov 尾置文件打不开。两个分支（HLS/非HLS）'
            '都不得包含该参数。');
  });

  test('v2: 绝不覆写 demuxer-lavf-o（保住 media_kit 的 hls_ad_filter 等默认）',
      () {
    final source = file.readAsStringSync();
    expect(source.contains("'demuxer-lavf-o'"), isFalse,
        reason: 'mpv 的 demuxer-lavf-o 是整表替换：覆写会抹掉 media_kit '
            'PlayerConfiguration 设置的 hls_ad_filter / allowed_extensions=ALL '
            '/ protocol_whitelist / seg_max_retry=5');
  });

  test('v2: 不再使用激进探测参数（probe-info/analyzeduration/probesize）', () {
    final source = file.readAsStringSync();
    for (final prop in [
      'demuxer-lavf-probe-info',
      'demuxer-lavf-analyzeduration',
      'demuxer-lavf-probesize',
    ]) {
      expect(source.contains("'$prop'"), isFalse,
          reason: '$prop 偏离上游 Kazumi，可能漏探音轨/首片较慢的流');
    }
  });

  test('P1-4: 与格式无关的属性只在 ensurePlayer 设置一次', () {
    final source = file.readAsStringSync();
    // openMedia 内不再出现这些属性（迁移到 ensurePlayer 的装配批）。
    final openMediaBody = _extractMethod(source, 'Future<Player?> openMedia');
    expect(openMediaBody, isNotNull);
    for (final prop in [
      'stream-lavf-o',
      'demuxer-lavf-analyzeduration',
      'demuxer-lavf-probesize',
      'network-timeout',
      'cache-pause-initial',
      'cache-pause-wait',
      'video-sync',
    ]) {
      // 带引号匹配（字符串字面量）——注释里的说明性提及不算下发。
      expect(openMediaBody!.contains("'$prop'"), isFalse,
          reason: '$prop 与格式无关，应只在 ensurePlayer 设置一次，'
              '不得出现在每集的 openMedia 路径');
    }
    final ensureBody = _extractMethod(source, 'Future<Player?> ensurePlayer');
    expect(ensureBody, isNotNull);
    for (final prop in [
      'stream-lavf-o',
      'network-timeout',
      'cache-pause-wait',
      'video-sync',
    ]) {
      expect(ensureBody!.contains("'$prop'"), isTrue,
          reason: '$prop 必须在 ensurePlayer 的一次性装配批中');
    }
  });

  test('P1-9: position 流订阅在场（250ms 节流直订）', () {
    final source = file.readAsStringSync();
    expect(source.contains('player.stream.position.listen'), isTrue,
        reason: '进度条/弹幕的 250ms 直订必须在 ensurePlayer 订阅批中');
    expect(source.contains('milliseconds: 250'), isTrue);
  });

  test('P1-4: setShader 模式未变零下发（_lastAppliedShaderMode 守卫）', () {
    final source = file.readAsStringSync();
    expect(source.contains('_lastAppliedShaderMode'), isTrue);
    expect(source.contains('if (superResolutionMode != _lastAppliedShaderMode)'),
        isTrue,
        reason: 'openMedia 只在模式变化时（open 之后）触发 setShader');
  });
}

/// 粗提取方法体（大括号配平；先跳过参数列表，避免命名参数的 {}
/// 提前终止配平）。找不到返回 null。
String? _extractMethod(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return null;
  // 跳过参数列表：找到签名后的第一个 '('，配平到对应的 ')'。
  final parenStart = source.indexOf('(', start);
  if (parenStart < 0) return null;
  var parenDepth = 0;
  var parenEnd = -1;
  for (var i = parenStart; i < source.length; i++) {
    final ch = source[i];
    if (ch == '(') {
      parenDepth++;
    } else if (ch == ')') {
      parenDepth--;
      if (parenDepth == 0) {
        parenEnd = i;
        break;
      }
    }
  }
  if (parenEnd < 0) return null;
  // 参数列表之后的方法体大括号。
  final bodyStart = source.indexOf('{', parenEnd);
  if (bodyStart < 0) return null;
  var depth = 0;
  for (var i = bodyStart; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(bodyStart, i + 1);
      }
    }
  }
  return null;
}
