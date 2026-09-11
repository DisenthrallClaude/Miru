// v1.6.8（Round3 verify-2 🔴-1 / verify-1 缺失锁）：两把「接线方向」
// 回归锁。
//
// 背景：v1.6.7 两个声画 bug 都是「逻辑正确但接线断裂」型——
//  ① hasVideoParams 加了 @observable 但 .g.dart 未重新生成 →
//    首帧信号静默失效（谓词层单测全绿，UI 层失明）；
//  ② video_page 挂载三元分支写反（? Container() : PlayerItem()）→
//    正常播放挂空容器=有声黑屏 100% 必现。
// 纯逻辑单测对这两类「源到 UI 的接线断裂」全盲，故用源契约测试
// 直接锁住两处接线事实：
//  ① 生成文件必须含 hasVideoParams 的 Atom 响应式包装；
//  ② playerItemMounted 调用点的三元分支必须是「真→PlayerItem」。
// 若未来重构改变了这些接线（如改用别的挂载谓词名/响应式方案），
// 请同步更新本测试断言，而不是删除测试。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('播放器接线方向回归锁（源契约）', () {
    final projectRoot = Directory.current;

    test('codegen 契约：.g.dart 必须包含 hasVideoParams 响应式包装', () {
      final gFile = File.fromUri(projectRoot.uri.resolve(
        'lib/pages/player/controller/player_playback_controller.g.dart',
      ));
      expect(gFile.existsSync(), isTrue,
          reason: '生成文件缺失——build_runner 未运行？');
      final generated = gFile.readAsStringSync();

      // Atom 包装的特征：final $hasVideoParams = Atom(...)
      expect(
        generated.contains(r'$hasVideoParams'),
        isTrue,
        reason: 'hasVideoParams 的 Atom 响应式包装不在生成文件中——'
            'v1.6.7 的失效模式（源文件加 @observable 后未重跑 '
            'build_runner）复现。运行：dart run build_runner build '
            '--delete-conflicting-outputs',
      );
      expect(
        generated.contains(r'$hasAudioOnlyFallback'),
        isTrue,
        reason: 'hasAudioOnlyFallback（纯音频兜底信号）同样需要响应式包装，'
            '否则纯音频流的遮罩放行失明。',
      );
    });

    test('挂载方向契约：playerItemMounted 为真时必须挂 PlayerItem', () {
      final pageFile = File.fromUri(
        projectRoot.uri.resolve('lib/pages/video/video_page.dart'),
      );
      expect(pageFile.existsSync(), isTrue);
      final source = pageFile.readAsStringSync();

      // 提取调用点上下文（含三元分支落点）。
      final callIdx = source.indexOf('playerItemMounted(');
      expect(callIdx, greaterThan(0), reason: '挂载谓词调用点不存在于 video_page');
      final region = source.substring(
        callIdx,
        (callIdx + 1600).clamp(0, source.length),
      );

      // 谓词语义：true=应挂 PlayerItem（见 playback_mask_logic.dart 注释
      // 与 test/playback_mask_logic_test.dart）。
      // 三元必须写成  ? PlayerItem(...) : Container(...)
      expect(
        region.contains(RegExp(r'\?\s*PlayerItem\(')),
        isTrue,
        reason: '三元分支方向错误：真分支必须挂 PlayerItem。'
            'v1.6.8 Round3 曾抓到写反（? Container() : PlayerItem()）'
            '导致正常播放挂空容器=有声黑屏必现。',
      );
      expect(
        region.contains(RegExp(r':\s*Container\(\)')),
        isTrue,
        reason: '假分支（装配期/错误态）应为空 Container。',
      );
      // 反向断言：确保不是「? Container() : PlayerItem(」的旧病。
      expect(
        region.contains(RegExp(r'\?\s*Container\(\)\s*\n\s*:\s*PlayerItem\(')),
        isFalse,
        reason: '检测到 v1.6.8 Round3 修掉的反向接线又回来了。',
      );
    });
  });
}
