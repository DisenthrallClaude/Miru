// v1.6.8（R-4）回归锁：HTMLMediaElement.src setter 劫持的元素类型判定。
//
// 病灶（reviews/v168-agent-P2.md R-4）：劫持挂在
// HTMLMediaElement.prototype 上、<audio> 同样继承，上报回调里没有
// 元素类型判定——站点 BGM（bgm = document.createElement('audio');
// bgm.src = '…/bgm.mp3'）早于播放器给 <video> 赋 src 时，BGM 直链
// 被当成视频源冻结上报 → mpv 播纯音频 →「有声黑屏」假解析结果。
// MutationObserver 路径（P-4）已排除 AUDIO，本测试锁定 setter 通道
// 不再漏（从 _buildAllUserScripts 的真实注入产物断言，非副本）。
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/webview/video/impl/video_webview_android_impl.dart';

void main() {
  test('R-4: src setter 劫持上报前必须有元素类型判定（只放行 VIDEO）', () {
    final script = VideoWebviewAndroidImplProbe.videoTagParserScript();

    // 定位 HTMLMediaElement.prototype.src 的劫持块
    final defineIdx = script.indexOf(
        "Object.defineProperty(HTMLMediaElement.prototype, 'src'");
    expect(defineIdx, greaterThanOrEqualTo(0),
        reason: 'src setter 劫持脚本必须存在');

    // 块边界：劫持块到 getter 恢复（get()）为止，期间是 set(v) 函数体
    final getterIdx = script.indexOf('get()', defineIdx);
    expect(getterIdx, greaterThan(defineIdx),
        reason: 'src 劫持必须保留原 getter（不破坏页面语义）');
    final setterBlock = script.substring(defineIdx, getterIdx);

    final reportIdx = setterBlock.indexOf("callHandler('VideoBridgeDebug'");
    expect(reportIdx, greaterThanOrEqualTo(0),
        reason: '劫持必须保留 VideoBridgeDebug 上报通道（video 元素）');
    final guardIdx = setterBlock.indexOf("this.tagName === 'VIDEO'");
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: '上报条件必须包含元素类型判定（R-4 病灶：'
            'audio.src=BGM 会被误报为视频源 → 有声黑屏）');
    expect(guardIdx, lessThan(reportIdx),
        reason: 'tagName 判定必须位于上报调用之前（条件内）');
  });

  test('R-4 关联: MutationObserver 路径的 AUDIO 排除保持（P-4 不回退）', () {
    final script = VideoWebviewAndroidImplProbe.videoTagParserScript();
    final fnIdx = script.indexOf('function processVideoElement');
    expect(fnIdx, greaterThanOrEqualTo(0));
    // processVideoElement 对 AUDIO 元素 return false（只静音起播触发
    // 网络请求，不参与上报）。
    final audioGuardIdx =
        script.indexOf("video.nodeName === 'AUDIO'", fnIdx);
    expect(audioGuardIdx, greaterThanOrEqualTo(0),
        reason: '观察路径对 AUDIO 的排除（P-4）不得回退');
  });
}
