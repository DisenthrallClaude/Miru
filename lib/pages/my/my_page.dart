import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/bean/widget/glass.dart';
import 'package:miru/bean/widget/pressable_glass.dart';
import 'package:miru/utils/theme.dart';
import 'package:miru/modules/collect/collect_type.dart';
import 'package:miru/modules/my/watch_stats.dart';
import 'package:miru/pages/menu/route_visibility.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/pages/my/recent_watch_card.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/utils/date_time.dart';

/// 本页所有卡片统一使用的圆角令牌，保证玻璃面板之间读作同一套卡片。
const double _cardRadius = Radii.lg;

// 同屏 BackdropFilter 预算：追番卡 + 统计面板 + 入口分组 = 3 块玻璃，
// 不超过 4 块的建议上限；其余小元素保持朴素或只用半透明底色。
class MyPage extends StatefulWidget {
  const MyPage({super.key, required this.controller});

  final MyController controller;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  MyController get myController => widget.controller;

  bool _attached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // This page stays mounted under the player, which rewrites history every
    // second. Drop the subscription while covered, re-derive on the way back.
    _setAttached(!RouteVisibility.isCoveredOf(context));
  }

  @override
  void dispose() {
    _setAttached(false);
    super.dispose();
  }

  void _setAttached(bool value) {
    if (_attached == value) {
      return;
    }
    _attached = value;
    if (value) {
      myController.attach();
    } else {
      myController.detach();
    }
  }

  int _recentCrossCount() {
    final width = MediaQuery.sizeOf(context).width;
    if (width > LayoutBreakpoint.medium['width']!) {
      return 3;
    }
    if (width > LayoutBreakpoint.compact['width']!) {
      return 2;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final bool wide =
        MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!;
    return Scaffold(
      appBar: const SysAppBar(title: Text('我的'), needTopOffset: false),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Observer(
          builder: (context) {
            final stats = myController.watchStats;
            return SingleChildScrollView(
              // 底部让出毛玻璃导航条高度（SafeArea 已 bottom: false）
              padding: EdgeInsets.fromLTRB(
                Space.lg,
                Space.sm,
                Space.lg,
                Space.xxl + MediaQuery.paddingOf(context).bottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1400 : 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide) _wideHeader(stats) else ..._narrowHeader(stats),
                      ..._recentSection(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _narrowHeader(WatchStats stats) {
    return [
      _CollectHero(stats: stats),
      const SizedBox(height: 12),
      _statTiles(stats),
      const SizedBox(height: 12),
      _entryGroup(stats),
    ];
  }

  Widget _wideHeader(WatchStats stats) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CollectHero(stats: stats),
              const SizedBox(height: 12),
              _statTiles(stats),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: _entryGroup(stats)),
      ],
    );
  }

  List<Widget> _recentSection() {
    final crossCount = _recentCrossCount();
    final int maxCount = crossCount == 1 ? 3 : crossCount * 2;
    final int count = myController.recentWatches.length < maxCount
        ? myController.recentWatches.length
        : maxCount;
    if (count == 0) {
      return const [];
    }
    return [
      const SizedBox(height: 24),
      _sectionLabel('继续观看'),
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossCount,
          crossAxisSpacing: StyleString.cardSpace,
          mainAxisSpacing: StyleString.cardSpace,
          mainAxisExtent: 128,
        ),
        itemCount: count,
        itemBuilder: (context, index) {
          final item = myController.recentWatches[index];
          return RecentWatchCard(key: ValueKey(item.id), item: item);
        },
      ),
    ];
  }

  Widget _sectionLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _statTiles(WatchStats stats) {
    // 三个数据格合并到同一块玻璃面板：整行只花一次 BackdropFilter 的开销，
    // 格与格之间用发丝竖线分隔，避免同屏模糊元素超预算。
    final tiles = <Widget>[
      _StatTile(
        value: '${stats.watchedBangumiCount}',
        unit: '部',
        label: '看过番剧',
      ),
      _StatTile(
        value: '${stats.watchedEpisodeCount}',
        unit: '集',
        label: '观看集数',
      ),
      _StatTile(
        value: '${stats.downloadTaskCount}',
        unit: '集',
        label: '离线缓存',
      ),
    ];
    // Tiles hold different amounts of text; stretch keeps them level.
    return FrostedSurface(
      borderRadius: BorderRadius.circular(_cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.lg),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const _PanelDivider(),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 功能入口分组：整组一块玻璃面板，行间用发丝线分隔。
  /// 每行包一层 PressableGlass 获得弹簧按压反馈；
  /// onTap 仍走原先的 pushNamed 路由，业务逻辑零改动。
  Widget _entryGroup(WatchStats stats) {
    final githubLoggedIn = GStorage.getSetting(SettingsKeys.githubEnable) &&
        GStorage.getSetting(SettingsKeys.githubLogin).isNotEmpty;
    return FrostedSurface(
      borderRadius: BorderRadius.circular(_cardRadius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _entryTile(
            icon: Icons.history_rounded,
            title: '历史记录',
            description: stats.lastWatchName != null
                ? '最近看到 ${stats.lastWatchName}'
                : '还没有观看记录',
            onTap: () => context.pushNamed('/settings/history/'),
          ),
          const _EntryDivider(),
          _entryTile(
            icon: Icons.download_rounded,
            title: '离线下载',
            description: '缓存任务与本地文件',
            onTap: () => context.pushNamed('/settings/download/'),
          ),
          const _EntryDivider(),
          _entryTile(
            icon: Icons.cloud_sync_rounded,
            title: '数据同步',
            description: githubLoggedIn
                ? 'GitHub · @${GStorage.getSetting(SettingsKeys.githubLogin)}'
                : '本地模式 · 未登录 GitHub',
            onTap: () => context.pushNamed('/settings/github/'),
          ),
          const _EntryDivider(),
          _entryTile(
            icon: Icons.settings_rounded,
            title: '设置',
            description: '播放、弹幕、外观与规则',
            onTap: () => context.pushNamed('/settings/'),
          ),
        ],
      ),
    );
  }

  /// 单行入口：图标圆盘 + 标题/描述 + 雪佛龙，排版对齐原 SettingsCategoryTile。
  Widget _entryTile({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    return PressableGlass(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            GlassIconDisc(icon: icon, tinted: true),
            const SizedBox(width: Space.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.bodyLarge),
                  const SizedBox(height: Space.xxs),
                  Text(
                    description,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectHero extends StatelessWidget {
  const _CollectHero({required this.stats});

  final WatchStats stats;

  static const List<CollectType> _order = [
    CollectType.watching,
    CollectType.planToWatch,
    CollectType.onHold,
    CollectType.watched,
    CollectType.abandoned,
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lastWatchTime = stats.lastWatchTime;
    final String caption = lastWatchTime == null
        ? '收藏番剧后会在这里汇总'
        : '最近观看 ${formatTimestampToRelativeTime(lastWatchTime.millisecondsSinceEpoch ~/ 1000)}';

    // 头部用户信息卡片：换成液态玻璃材质，去掉生硬的不透明底色。
    // 圆角走 Radii 令牌；内容排版与数据展示保持原样。
    return FrostedSurface(
      borderRadius: BorderRadius.circular(_cardRadius),
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.favorite_rounded,
                    size: 18,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '我的追番',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${stats.collectedCount}',
                    style: textTheme.displaySmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(
                    text: ' 部',
                    style: textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (stats.collectedCount > 0)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final type in _order)
                    if ((stats.collectCounts[type] ?? 0) > 0)
                      _CollectChip(
                        label: type.label,
                        count: stats.collectCounts[type]!,
                      ),
                ],
              ),
            if (stats.collectedCount > 0) const SizedBox(height: 12),
            Text(
              caption,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectChip extends StatelessWidget {
  const _CollectChip({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $count',
        style: textTheme.labelMedium?.copyWith(
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.unit,
    required this.label,
  });

  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 只负责排版：底色与圆角由整块统计玻璃面板统一提供，
    // 避免每个数据格各自挂一个 BackdropFilter。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: textTheme.headlineSmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 统计玻璃面板内部的竖向发丝分隔线（纯绘制，无模糊开销）。
class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// 入口玻璃分组内部的横向发丝分隔线，
/// 左侧让开「16 边距 + 36 图标圆盘 + 16 间距」的缩进，对齐 iOS 分组列表。
class _EntryDivider extends StatelessWidget {
  const _EntryDivider();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 68),
      child: Container(height: 0.5, color: color),
    );
  }
}

