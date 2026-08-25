import 'package:flutter/material.dart';
import 'package:miru/utils/constants.dart';

/// Miru 视觉层设计系统。
///
/// 这里只描述"长什么样"，不含任何业务逻辑。所有页面通过 `Theme.of(context)`
/// 消费这里的令牌，因此调整本文件即可整体改变观感，而无需触碰任何后端代码。
///
/// 设计取向：Apple 设计语言 —— 中性化表面、克制的强调色、克制的层次
/// （用细描边与表面色阶代替投影）、宽裕留白、连续感圆角、平滑的缓动曲线。

// ---------------------------------------------------------------------------
// 基础令牌
// ---------------------------------------------------------------------------

/// 默认主题种子色。用户可在「设置 - 主题」中覆盖，
/// 存储值为 `'default'` 时回落到这里。
const Color kDefaultSeedColor = Color(0xFF3A5A8C);

/// 4pt 基准间距栅格。
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;
}

/// 圆角梯度。数值向 Apple 的连续曲率观感靠拢：
/// 控件小、卡片中、浮层大。
abstract final class Radii {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 22;
  static const double xxl = 28;
  static const double pill = 999;

  static const BorderRadius brXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius brXxl = BorderRadius.all(Radius.circular(xxl));

  /// 浮层顶部圆角（BottomSheet）。
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

/// 动效时长与曲线。曲线选取贴近 iOS 的减速手感。
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 380);

  /// 通用进出场：起步快、收尾柔。
  static const Curve standard = Curves.easeOutCubic;

  /// 双向运动（位移/尺寸同时变化）。
  static const Curve emphasized = Curves.fastOutSlowIn;

  /// 元素退场。
  static const Curve exit = Curves.easeInCubic;

  /// 弹簧物理参数（配合 flutter/physics 的 SpringSimulation）。
  ///
  /// * [bouncy]：欠阻尼，明显过冲回弹——玻璃滑块、按压回弹。
  /// * [snappy]：轻微过冲，快速收敛——面板进出、列表重排。
  /// * [gentle]：几乎无过冲——背景色温、透明度这类不宜晃动的属性。
  static SpringDescription get bouncy =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.62);
  static SpringDescription get snappy =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 520, ratio: 0.82);
  static SpringDescription get gentle =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 320, ratio: 1.0);

  /// 隐式动画可用的类弹簧曲线（无法用 Simulation 时）：
  /// easeOutBack 带一次柔和过冲，观感接近 snappy 弹簧。
  static const Curve springy = Curves.easeOutBack;
}

/// 液态玻璃材质参数。
abstract final class Frost {
  /// 模糊半径。加大到 36 让背后内容化开成色块，
  /// 这是「玻璃」而非「半透明板」的关键。
  static const double blur = 36;

  /// 底色不透明度。
  ///
  /// 之前取 0.72 几乎等于不透明，完全没有通透感。
  /// 压到 0.3 左右才能透出背后的内容与颜色；
  /// 可读性由模糊 + 边缘高光而非遮盖来保证。
  static double tintOpacity(Brightness brightness) =>
      brightness == Brightness.light ? 0.30 : 0.26;

  /// 弹窗出现时，背后页面的模糊强度（iOS 那种整屏化开的观感）。
  static const double scrimBlur = 18;

  /// 边缘高光：玻璃边缘的那道亮边。
  static Color edgeLight(Brightness brightness) =>
      brightness == Brightness.light
          ? Colors.white.withValues(alpha: 0.85)
          : Colors.white.withValues(alpha: 0.30);

  /// 边缘暗部，配合高光做出厚度感。
  static Color edgeShadow(Brightness brightness) =>
      brightness == Brightness.light
          ? Colors.black.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.45);

  /// 镜面渐变：从左上到右下的一道柔和反光。
  static Gradient specular(Brightness brightness) {
    final strong = brightness == Brightness.light ? 0.55 : 0.22;
    final weak = brightness == Brightness.light ? 0.06 : 0.03;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: strong),
        Colors.white.withValues(alpha: weak),
        Colors.transparent,
      ],
      stops: const [0.0, 0.45, 1.0],
    );
  }
}

// ---------------------------------------------------------------------------
// 中性化表面色板
// ---------------------------------------------------------------------------

/// M3 的 `fromSeed` 会把种子色的色相重染到所有表面上，观感偏"彩色"。
/// 这里把表面层替换为**极低饱和的主题色调表面**：
/// 只保留约 4% 的种子色饱和度，明度沿用 iOS systemBackground 体系的灰阶，
/// 强调角色仍由 primary / secondary / tertiary 承担。
///
/// 为什么不再用纯灰阶：液态玻璃的通透感来自「模糊采样到下方真实内容」，
/// 纯灰背景下模糊结果依然是灰，玻璃退化为半透明面板。
/// 注入一丝色温后，不同主题色下的背景有了可感知的色彩呼吸，
/// 玻璃的模糊、高光、镜面渐变才真正"活"起来。
///
/// 注意：动态取色（Monet）与用户自定义主题色依然生效——它们决定强调色，
/// 同时以极轻的力度染在背景层上。
ColorScheme _neutralizeSurfaces(ColorScheme scheme) {
  Color tinted(double lightness) {
    final hsl = HSLColor.fromColor(scheme.primary);
    // 饱和度压到 0.04~0.06：肉眼近似中性灰，但保留了主题色的温度。
    return hsl
        .withSaturation(
            scheme.brightness == Brightness.light ? 0.04 : 0.06)
        .withLightness(lightness)
        .toColor();
  }

  if (scheme.brightness == Brightness.light) {
    return scheme.copyWith(
      surface: const Color(0xFFFFFFFF),
      surfaceDim: tinted(0.90),
      surfaceBright: const Color(0xFFFFFFFF),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: tinted(0.975),
      surfaceContainer: tinted(0.955),
      surfaceContainerHigh: tinted(0.93),
      surfaceContainerHighest: tinted(0.90),
      onSurface: const Color(0xFF1C1C1E),
      onSurfaceVariant: const Color(0xFF6E6E73),
      outline: const Color(0xFFC6C6C8),
      outlineVariant: const Color(0xFFE3E3E8),
      inverseSurface: tinted(0.18),
      onInverseSurface: const Color(0xFFF2F2F7),
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
    );
  }
  return scheme.copyWith(
    surface: tinted(0.075),
    surfaceDim: tinted(0.055),
    surfaceBright: tinted(0.17),
    surfaceContainerLowest: tinted(0.05),
    surfaceContainerLow: tinted(0.10),
    surfaceContainer: tinted(0.125),
    surfaceContainerHigh: tinted(0.155),
    surfaceContainerHighest: tinted(0.19),
    onSurface: const Color(0xFFF2F2F7),
    onSurfaceVariant: const Color(0xFF98989F),
    outline: const Color(0xFF3A3A3C),
    outlineVariant: const Color(0xFF2A2A2C),
    inverseSurface: tinted(0.91),
    onInverseSurface: const Color(0xFF1C1C1E),
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
  );
}

// ---------------------------------------------------------------------------
// 字体排印
// ---------------------------------------------------------------------------

/// 衬线排印层级。字号沿用 iOS 的字阶（34/28/22/20/17/15/13/11），
/// 行高放宽以适配中文衬线体的字面，字距在大字号上收紧。
///
/// [fontFamily] 为 null 时表示用户开启了「使用系统字体」，
/// 此时不指定 family，仅保留字阶与字重，交由系统字体渲染。
TextTheme buildMiruTextTheme(Brightness brightness, String? fontFamily) {
  // 刻意不指定 color：ThemeData 会把本 TextTheme 合并到 Typography 之上，
  // 由配色方案决定前景色。若在此写死颜色，FilledButton / AppBar 之类
  // 依赖 foregroundColor 的控件会出现对比度错误。
  TextStyle style(
    double size,
    FontWeight weight, {
    double height = 1.45,
    double spacing = 0,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: spacing,
      // 衬线体在中文下需要更稳的基线对齐
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  return TextTheme(
    // 大标题
    displayLarge: style(34, FontWeight.w600, height: 1.25, spacing: -0.5),
    displayMedium: style(28, FontWeight.w600, height: 1.28, spacing: -0.4),
    displaySmall: style(24, FontWeight.w600, height: 1.3, spacing: -0.3),

    headlineLarge: style(28, FontWeight.w600, height: 1.3, spacing: -0.3),
    headlineMedium: style(22, FontWeight.w600, height: 1.34, spacing: -0.2),
    headlineSmall: style(20, FontWeight.w600, height: 1.36, spacing: -0.1),

    // 区块标题
    titleLarge: style(20, FontWeight.w600, height: 1.36, spacing: -0.1),
    titleMedium: style(17, FontWeight.w600, height: 1.4),
    titleSmall: style(15, FontWeight.w600, height: 1.42),

    // 正文
    bodyLarge: style(17, FontWeight.w400, height: 1.5),
    bodyMedium: style(15, FontWeight.w400, height: 1.5),
    bodySmall: style(13, FontWeight.w400, height: 1.46),

    // 控件文字
    // 控件标签用紧凑行高：1.4 这类段落行高会在固定高度的按钮/菜单里被裁切
    labelLarge: style(15, FontWeight.w600, height: 1.2),
    labelMedium: style(13, FontWeight.w600, height: 1.2),
    labelSmall: style(11, FontWeight.w600, height: 1.2, spacing: 0.1),
  );
}

// ---------------------------------------------------------------------------
// 主题构造
// ---------------------------------------------------------------------------

/// 构造 Miru 的完整主题。
///
/// [colorScheme] 优先（动态取色场景），否则用 [seedColor] 生成。
/// 二者都为空时回落到 [kDefaultSeedColor]。
ThemeData buildMiruTheme({
  required Brightness brightness,
  required String? fontFamily,
  Color? seedColor,
  ColorScheme? colorScheme,
}) {
  final ColorScheme base = colorScheme ??
      ColorScheme.fromSeed(
        seedColor: seedColor ?? kDefaultSeedColor,
        brightness: brightness,
      );

  final ColorScheme scheme = _neutralizeSurfaces(
    base.brightness == brightness
        ? base
        : base.copyWith(brightness: brightness),
  );

  final TextTheme textTheme = buildMiruTextTheme(brightness, fontFamily);
  final bool isLight = brightness == Brightness.light;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    // 全局去投影：层次改由玻璃材质与表面色阶表达
    shadowColor: Colors.transparent,

    // 极简：只压低高亮反馈的重色，不替换 splashFactory。
    // （InkSparkle 依赖片元着色器，在 Impeller 上属于额外风险，
    //   而且本设计并不需要它。）
    highlightColor: scheme.onSurface.withValues(alpha: 0.04),

    // 沿用原有的现代化进度条 / 滑块外观
    progressIndicatorTheme: progressIndicatorTheme2024,
    sliderTheme: sliderTheme2024.copyWith(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
      thumbColor: scheme.primary,
    ),
    pageTransitionsTheme: pageTransitionsTheme2024,

    // --- 顶栏：透明、无阴影、无滚动染色 ---
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      toolbarTextStyle: textTheme.bodyMedium,
      iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      actionsIconTheme: IconThemeData(color: scheme.onSurface, size: 22),
    ),

    // --- 卡片：零投影，用极细描边界定边界 ---
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.brMd,
        side: BorderSide(color: scheme.outlineVariant, width: 0.5),
      ),
    ),

    // --- 底部导航：透明交给毛玻璃容器处理 ---
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // 与 menu.dart 的 _navBarHeight 保持一致
      height: 70,
      indicatorColor: Colors.transparent,
      indicatorShape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
      // 点击时不要那层灰色水波纹/高亮——选中态已由玻璃滑块表达
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return textTheme.labelSmall!.copyWith(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
    ),

    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: 0.10),
      indicatorShape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
      selectedIconTheme: IconThemeData(color: scheme.primary, size: 24),
      unselectedIconTheme:
          IconThemeData(color: scheme.onSurfaceVariant, size: 24),
      selectedLabelTextStyle:
          textTheme.labelSmall!.copyWith(color: scheme.primary),
      unselectedLabelTextStyle:
          textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant),
    ),

    // --- 浮层 ---
    dialogTheme: DialogThemeData(
      backgroundColor: isLight ? Colors.white : scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: Radii.brXl),
      titleTextStyle: textTheme.titleLarge!.copyWith(color: scheme.onSurface),
      contentTextStyle: textTheme.bodyMedium!.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.5,
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: Space.xxl,
        vertical: Space.xxl,
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isLight ? Colors.white : scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      // 不全局强制拖拽把手：本应用多数 BottomSheet 自带 header，
      // 强开会出现双重把手。是否显示交给各调用点决定。
      dragHandleColor: scheme.outline,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      clipBehavior: Clip.antiAlias,
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: isLight ? Colors.white : scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.brMd,
        side: BorderSide(color: scheme.outlineVariant, width: 0.5),
      ),
      textStyle: textTheme.bodyMedium!.copyWith(color: scheme.onSurface),
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          isLight ? Colors.white : scheme.surfaceContainerHigh,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: Radii.brMd,
            side: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
      ),
    ),

    // --- 列表 ---
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall!.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.xl,
        vertical: Space.xs,
      ),
      minVerticalPadding: Space.md,
      shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
    ),

    // --- 分隔线：发丝级 ---
    // 只改颜色与线宽，不改 space —— space 参与布局占位，
    // 全局改小会挤压依赖 Divider 做间距的既有列表。
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 0.5,
    ),

    // --- 按钮 ---
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        textStyle: textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.xxl,
          vertical: Space.md,
        ),
        shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        textStyle: textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.xxl,
          vertical: Space.md,
        ),
        side: BorderSide(color: scheme.outline, width: 0.5),
        shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurface,
        highlightColor: scheme.onSurface.withValues(alpha: 0.06),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: const RoundedRectangleBorder(borderRadius: Radii.brMd),
    ),

    // --- 输入 ---
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainer,
      hintStyle: textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      border: const OutlineInputBorder(
        borderRadius: Radii.brSm,
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: Radii.brSm,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Radii.brSm,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),

    // --- 其它控件 ---
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primary.withValues(alpha: 0.12),
      side: BorderSide.none,
      // 必须显式指定颜色：为 null 时会继承祖先 DefaultTextStyle，
      // 在详情页封面（白字语境）下会变成白底白字。
      labelStyle: textTheme.labelMedium!.copyWith(color: scheme.onSurface),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
    ),

    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: textTheme.titleSmall,
      unselectedLabelStyle: textTheme.titleSmall!.copyWith(
        fontWeight: FontWeight.w400,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium!.copyWith(
        color: scheme.onInverseSurface,
      ),
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: Radii.brSm),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: Radii.brXs,
      ),
      textStyle: textTheme.labelSmall!.copyWith(
        color: scheme.onInverseSurface,
        fontWeight: FontWeight.w400,
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        return Colors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return scheme.onSurface.withValues(alpha: 0.14);
      }),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(Radii.xs),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurface.withValues(alpha: 0.22),
      ),
    ),
  );
}

/// OLED 增强：把表面压到纯黑。
/// 行为与原实现一致（仅在深色主题上叠加），不改变开关语义。
ThemeData oledDarkTheme(ThemeData defaultDarkTheme) {
  final scheme = defaultDarkTheme.colorScheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0A0A0A),
    surfaceContainer: const Color(0xFF121212),
    surfaceContainerHigh: const Color(0xFF1A1A1A),
    surfaceContainerHighest: const Color(0xFF222222),
    onSurface: Colors.white,
  );

  return defaultDarkTheme.copyWith(
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    colorScheme: scheme,
    cardTheme: defaultDarkTheme.cardTheme.copyWith(
      color: scheme.surfaceContainerLow,
    ),
    dialogTheme: defaultDarkTheme.dialogTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    bottomSheetTheme: defaultDarkTheme.bottomSheetTheme.copyWith(
      backgroundColor: scheme.surfaceContainer,
    ),
  );
}
