library;

/// 液态玻璃欢迎屏主题 —— 复刻 Appllama/liquid-glass-screens 的两个 cookbook。
///
/// * Sky（白天）：循环云海视频背景、旅行贴纸、灰色调玻璃；
///   送回时贴纸先坠落、再上浮淡出（fall）。
/// * Astro（夜晚）：星空两层背景（星星 + 地平光晕）、应用构建贴纸、
///   蓝白夜色玻璃；送回时贴纸被卷入底部中心的星尘漩涡（vortex）。
///
/// 视觉参数（贴纸 40 槽序列、颜色、释放阈值、透镜色散）与原项目
/// cookbooks/sky.ts、astro.ts 保持一致；文案替换为 Miru 追番语境。

import 'package:flutter/material.dart';

/// 贴纸离开羽流的方式。
enum LiquidGlassReturnMode { fall, vortex }

/// 欢迎屏文案（gate 提示、open 标题、旋转第三行、CTA）。
class LiquidGlassCopy {
  const LiquidGlassCopy({
    required this.hint,
    required this.headline,
    required this.struck,
    required this.kept,
    required this.phrases,
    required this.cta,
  });

  /// gate 状态下方的上滑提示。
  final String hint;

  /// open 状态主标题第一行。
  final String headline;

  /// 被划线删除的词（第二行前半）。
  final String struck;

  /// 划线后保留的词（第二行后半）。
  final String kept;

  /// 旋转展示的第三行短语。
  final List<String> phrases;

  /// 主按钮文案。
  final String cta;
}

class LiquidGlassTheme {
  const LiquidGlassTheme({
    required this.id,
    required this.night,
    required this.pageColor,
    required this.ink,
    required this.hint,
    required this.plus,
    required this.pillFrom,
    required this.pillTo,
    required this.pillText,
    required this.returnMode,
    required this.releaseAt,
    required this.buttonDispersion,
    required this.domeDispersion,
    required this.domeAt,
    required this.videoAsset,
    required this.refractionAsset,
    required this.glowAsset,
    required this.stickers,
    required this.copy,
  });

  final String id;

  /// 0 = 白天玻璃调色，1 = 夜晚玻璃调色（传给 shader）。
  final bool night;

  final Color pageColor;
  final Color ink;
  final Color hint;
  final Color plus;
  final Color pillFrom;
  final Color pillTo;
  final Color pillText;

  final LiquidGlassReturnMode returnMode;

  /// p 降到该值以下时贴纸开始离开。
  final double releaseAt;

  /// 透镜色散：按钮态 / 穹顶态的 per-channel 偏移量。
  final double buttonDispersion;
  final double domeDispersion;

  /// 穹顶色散在多大半径比例处达到。
  final double domeAt;

  /// Sky 视频背景；Astro 为 null。
  final String? videoAsset;

  /// 折射与兜底显示用的静态背景（Sky 为海报帧，Astro 为星星层）。
  final String refractionAsset;

  /// Astro 的地平光晕层；Sky 为 null。
  final String? glowAsset;

  /// 40 个贴纸槽（羽流出生顺序，大贴纸在前），asset 路径。
  final List<String> stickers;

  final LiquidGlassCopy copy;

  bool get isVortex => returnMode == LiquidGlassReturnMode.vortex;
}

const List<String> _skyStickerNames = [
  'pizza', 'dog', 'boots', 'polaroid', 'camcorder',
  'disco', 'star', 'sushi', 'coffee', 'martini',
  'bubble-reel', 'cake', 'bag', 'croissant', 'tennis',
  'bubble-hype', 'reel', 'suitcase', 'mascot', 'frame',
  'bubble-trap', 'pin', 'polaroid', 'martini',
  'dog', 'coffee', 'boots', 'star',
  'camcorder', 'sushi', 'croissant', 'pizza',
  'cake', 'disco', 'frame', 'bag',
  'bubble-reel', 'tennis', 'mascot', 'suitcase',
];

const List<String> _astroStickerNames = [
  'mac', 'bubble-build', 'keyboard', 'phone', 'robot',
  'cursor', 'star', 'code', 'rocket', 'planet',
  'bubble-reel', 'bolt', 'sparkle', 'wand', 'puzzle',
  'bubble-ship', 'floppy', 'astronaut', 'mascot', 'paper-plane',
  'bubble-dark-mode', 'bulb', 'controller', 'cursor',
  'robot', 'code', 'floppy', 'star',
  'phone', 'rocket', 'sparkle', 'mac',
  'bolt', 'planet', 'paper-plane', 'wand',
  'bubble-vibe', 'puzzle', 'mascot', 'astronaut',
];

/// Sky 主题（白天）。
final LiquidGlassTheme skyLiquidGlassTheme = LiquidGlassTheme(
  id: 'sky',
  night: false,
  pageColor: const Color(0xFFDCE8F2),
  ink: const Color(0xFF1D1D1F),
  hint: const Color(0xFF38383C),
  plus: const Color(0xFF1D1D1F),
  pillFrom: const Color(0xFFB9B9B9),
  pillTo: const Color(0xFF161616),
  pillText: const Color(0xFFFFFFFF),
  returnMode: LiquidGlassReturnMode.fall,
  releaseAt: 0.35,
  buttonDispersion: 0.12,
  domeDispersion: 0.05,
  domeAt: 1,
  videoAsset: 'assets/liquid_glass/sky/sky.mp4',
  refractionAsset: 'assets/liquid_glass/sky/sky-poster.png',
  glowAsset: null,
  stickers: [
    for (final name in _skyStickerNames)
      'assets/liquid_glass/sky/stickers/$name.png',
  ],
  copy: const LiquidGlassCopy(
    hint: '上滑开启',
    headline: '看番这件事',
    struck: '卡顿',
    kept: '纯粹',
    phrases: [
      '一打开就能接着看',
      '聚合多站，一搜即得',
      '更新日历尽在掌握',
      '收藏番剧，随时续看',
    ],
    cta: '直接进入',
  ),
);

/// Astro 主题（夜晚）。
final LiquidGlassTheme astroLiquidGlassTheme = LiquidGlassTheme(
  id: 'astro',
  night: true,
  pageColor: const Color(0xFF04060C),
  ink: const Color(0xFFF4F6FC),
  hint: const Color(0xE2E8F2C4),
  plus: const Color(0xFFF4F6FC),
  pillFrom: const Color(0xFF3A3F4D),
  pillTo: const Color(0xFFF4F6FC),
  pillText: const Color(0xFF0A0C14),
  returnMode: LiquidGlassReturnMode.vortex,
  releaseAt: 0.78,
  buttonDispersion: 0.12,
  domeDispersion: 0,
  domeAt: 0.6,
  videoAsset: null,
  refractionAsset: 'assets/liquid_glass/astro/stars.png',
  glowAsset: 'assets/liquid_glass/astro/glow.png',
  stickers: [
    for (final name in _astroStickerNames)
      'assets/liquid_glass/astro/stickers/$name.png',
  ],
  copy: const LiquidGlassCopy(
    hint: '上滑开启',
    headline: '深夜追番',
    struck: '打扰',
    kept: '沉浸',
    phrases: [
      '熄灯后的第一选择',
      '播放进度云端同步',
      '弹幕开关随心掌控',
      '番剧收藏，随时续看',
    ],
    cta: '直接进入',
  ),
);

/// 按应用亮度选择主题：白天用 Sky，夜晚用 Astro。
LiquidGlassTheme liquidGlassThemeFor(Brightness brightness) {
  return brightness == Brightness.dark
      ? astroLiquidGlassTheme
      : skyLiquidGlassTheme;
}
