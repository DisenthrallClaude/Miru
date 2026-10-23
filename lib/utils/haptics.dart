import 'package:flutter/services.dart';

/// 全 App 统一的触感语汇（P2-3）。
///
/// 之前各处直接调 `HapticFeedback.xxx()`，同一类动作在不同页面强度不一
/// （选集用 selectionClick、重试用 mediumImpact、卡片又是 light…）。
/// 这里把「语义」固定下来，调用方只表达意图，强度由这里统一：
///
/// * [tap]      轻触：打开卡片、切换 tab、普通按钮。
/// * [select]   选择：选集、切线路、滑块跨过刻度、手势跨过阈值。
/// * [impact]   确认：重试、长按倍速生效、双击快进退。
/// * [heavy]    强调：退出/进入全屏这类「状态翻转」。
/// * [edge]     触底：音量/亮度拉到 0 或 100%、进度拉到头。
/// * [warning]  失败：解析失败、操作被拒。
///
/// 每类带 40ms 节流，连续手势（亮度/音量拖动、横滑快进）不会把马达打成
/// 嗡鸣；节流按「类」独立，确认类不会被选择类吞掉。
abstract final class MiruHaptics {
  static final Map<int, int> _last = {};
  static const int _throttleMs = 40;

  /// 测试或无障碍场景可整体关闭。
  static bool enabled = true;

  static bool _gate(int kind) {
    if (!enabled) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _last[kind] ?? 0;
    if (now - last < _throttleMs) return false;
    _last[kind] = now;
    return true;
  }

  static void tap() {
    if (_gate(0)) HapticFeedback.lightImpact();
  }

  static void select() {
    if (_gate(1)) HapticFeedback.selectionClick();
  }

  static void impact() {
    if (_gate(2)) HapticFeedback.mediumImpact();
  }

  static void heavy() {
    if (_gate(3)) HapticFeedback.heavyImpact();
  }

  static void edge() {
    if (_gate(4)) HapticFeedback.selectionClick();
  }

  static void warning() {
    if (_gate(5)) HapticFeedback.vibrate();
  }
}
