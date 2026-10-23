import 'dart:io';

/// v1.8.1：液态玻璃性能分档（低端机降级）。
///
/// 实时模糊（BackdropFilter / 折射 shader）每帧都要采样背后像素，
/// 4 核及以下的老 Android 机上滚动会掉帧、发热。降级档：
/// * 所有 FrostedSurface 改为「无模糊」的静态玻璃（更不透明的乳白/墨色底 +
///   上缘镜面高光 + 发丝描边），观感保持玻璃语言；
/// * 底部 Dock 的折射 shader 与回退模糊都关闭，同样走静态玻璃。
///
/// 触发：设置「界面 → 降低玻璃模糊」手动开启，或自动判定为低端机
/// （Android 且 CPU ≤ 4 核）。系统「减弱动态效果」只影响动效，不影响此项。
abstract final class GlassPerformance {
  /// 用户手动开关（启动时从设置读取、设置页切换时写入）。
  static bool userReduce = false;
  static bool? _autoLow;

  /// 测试可注入。
  static bool? debugOverrideLowEnd;

  static bool get autoLowEnd {
    if (debugOverrideLowEnd != null) return debugOverrideLowEnd!;
    return _autoLow ??= _detect();
  }

  /// 构建期覆盖：`--dart-define=MIRU_GLASS=high|low`（CI 截图用 high，
  /// 2 核模拟器不该被判为低端而截到降级观感）。
  static const String _forced = String.fromEnvironment('MIRU_GLASS');

  static bool _detect() {
    if (_forced == 'high') return false;
    if (_forced == 'low') return true;
    try {
      return Platform.isAndroid && Platform.numberOfProcessors <= 4;
    } catch (_) {
      return false;
    }
  }

  /// 当前是否走降级（无实时模糊）。
  static bool get reduced => userReduce || autoLowEnd;
}
