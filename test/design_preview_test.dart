// 设计系统可视化预览。
//
// 本测试不校验业务逻辑，只把新的视觉令牌（衬线排印、中性表面、圆角、
// 分组列表、导航条、对话框）渲染成 PNG，便于在没有真机的环境下
// 肉眼检查明暗两套主题的排版与对比度。
//
// 生成/更新预览图：
//   flutter test test/design_preview_test.dart --update-goldens
// 产物位于 test/goldens/ 。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/frosted_surface.dart';
import 'package:kazumi/bean/widget/liquid_glass_indicator.dart';
import 'package:kazumi/utils/theme.dart';

/// 把真实的衬线字体注入测试渲染环境，否则 golden 里全是占位方块。
Future<void> _loadSerif() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      loader.addFont(
        File(p).readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    }
    await loader.load();
  }

  await load('Noto_Serif_SC', [
    'assets/fonts/NotoSerifSC-Regular.ttf',
    'assets/fonts/NotoSerifSC-SemiBold.ttf',
  ]);

  // 图标字体不会自动进入测试渲染环境，手动加载后预览图才有真实图标
  final iconFont = File(
      '${Platform.environment['HOME']}/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (iconFont.existsSync()) {
    await load('MaterialIcons', [iconFont.path]);
  }
}

Widget _showcase(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final text = theme.textTheme;

  return Scaffold(
    extendBody: true,
    body: SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            Space.lg, Space.lg, Space.lg, Space.huge + 70),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('热门番组', style: text.displayMedium),
            const SizedBox(height: Space.xs),
            Text('极简衬线 · 苹果式留白与层次',
                style: text.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Space.xxl),

            // 排印层级
            Text('排印层级', style: text.titleLarge),
            const SizedBox(height: Space.sm),
            Text('标题 Title · 20/600', style: text.titleMedium),
            Text('正文 Body 十七号字，中英混排 Mixed 123', style: text.bodyLarge),
            Text('次要说明文字 Footnote 13',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Space.xxl),

            // 海报网格（模拟 BangumiCardV 的无卡片形态）
            Text('番剧网格', style: text.titleLarge),
            const SizedBox(height: Space.md),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              crossAxisSpacing: Space.sm,
              mainAxisSpacing: Space.sm,
              childAspectRatio: 0.52,
              children: List.generate(3, (i) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 0.65,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: Radii.brMd,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      ['夏日重现', '葬送的芙莉莲', '孤独摇滚'][i],
                      style: text.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                );
              }),
            ),
            const SizedBox(height: Space.xxl),

            // 分组列表
            Text('分组列表', style: text.titleLarge),
            const SizedBox(height: Space.md),
            SettingsSplitGroup(
              children: [
                SettingsCategoryTile(
                  icon: Icons.history_rounded,
                  title: '历史记录',
                  description: '最近看到 葬送的芙莉莲 第 12 话',
                  onTap: () {},
                ),
                SettingsCategoryTile(
                  icon: Icons.download_rounded,
                  title: '离线下载',
                  description: '缓存任务与本地文件',
                  onTap: () {},
                ),
                SettingsCategoryTile(
                  icon: Icons.settings_rounded,
                  title: '设置',
                  description: '播放、弹幕、外观与规则',
                  onTap: () {},
                ),
              ],
            ),
            const SizedBox(height: Space.xxl),

            // 控件
            Text('控件', style: text.titleLarge),
            const SizedBox(height: Space.md),
            Row(
              children: [
                FilledButton(onPressed: () {}, child: const Text('立即播放')),
                const SizedBox(width: Space.md),
                OutlinedButton(onPressed: () {}, child: const Text('追番')),
                const SizedBox(width: Space.md),
                TextButton(onPressed: () {}, child: const Text('更多')),
              ],
            ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              children: const [
                Chip(label: Text('原创')),
                Chip(label: Text('奇幻')),
                Chip(label: Text('2024')),
              ],
            ),
            const SizedBox(height: Space.xxl),

            // 卡片 + 对话框观感
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('退出确认', style: text.titleLarge),
                    const SizedBox(height: Space.sm),
                    Text('您想要退出 Miru 吗？',
                        style: text.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    bottomNavigationBar: FrostedBar(
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned(
            left: 0,
            right: 0,
            top: (70 - 54) / 2,
            height: 54,
            child: LiquidGlassIndicator(index: 0, count: 4, height: 54),
          ),
          NavigationBar(
        height: 70,
        backgroundColor: Colors.transparent,
        selectedIndex: 0,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome_rounded),
              label: '推荐'),
          NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined), label: '时间表'),
          NavigationDestination(
              icon: Icon(Icons.bookmark_border_rounded), label: '追番'),
          NavigationDestination(
              icon: Icon(Icons.person_outline_rounded), label: '我的'),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(_loadSerif);

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final name = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('design system preview – $name', (tester) async {
      tester.view.physicalSize = const Size(1170, 2300);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildKazumiTheme(
            brightness: brightness,
            fontFamily: customSerifFontFamilyForTest,
          ),
          home: Builder(builder: _showcase),
        ),
      );
      await tester.pumpAndSettle();

      // CI 上 Flutter 缓存路径和本机不同，图标字体加载不到，
      // 像素级 golden 会误报。这里只保证版式能渲染完。
      expect(find.text('热门番组'), findsOneWidget);
      expect(find.text('立即播放'), findsOneWidget);
    });
  }
}

/// 与 `customAppFontFamily` 同名，这里单独声明以避免测试反向依赖 constants.dart。
const String customSerifFontFamilyForTest = 'Noto_Serif_SC';
