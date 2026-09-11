import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:miru/bean/widget/custom_dropdown_menu.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/pages/popular/popular_controller.dart';
import 'package:miru/bean/card/bangumi_feed_card.dart';
import 'package:miru/bean/card/bangumi_hero_carousel.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/utils/theme.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:miru/navigation.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:window_manager/window_manager.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:miru/utils/device.dart';

class PopularPage extends StatefulWidget {
  const PopularPage({
    super.key,
    required this.controller,
  });

  final PopularController controller;

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> {
  late final ScrollController scrollController;
  PopularController get popularController => widget.controller;

  // Key used to position the dropdown menu for the tag selector
  final GlobalKey selectorKey = GlobalKey();

  /// 封面「加载完成」的先后顺序（存 bangumi id）。
  /// 先加载完的排在信息流前面，未加载完的留在后面继续慢慢加载。
  final List<int> _loadedOrder = [];
  final Set<int> _loadedIds = {};

  /// 是否还允许按加载顺序重排。
  ///
  /// 一旦用户开始滚动就冻结顺序 —— 否则卡片会在手底下不停跳位，
  /// 既晕又会打断滚动。这是「图片优先」和「可用性」之间的取舍。
  bool _reorderFrozen = false;
  bool _reorderScheduled = false;

  /// 骨架占位条目：字段全空/零值，封面层拿到空 src 走灰底占位
  /// （不发请求），Skeletonizer 再把整张卡画成 bone。
  static final BangumiItem _skeletonBangumi = BangumiItem(
    id: 0,
    type: 2,
    name: '',
    nameCn: '占位标题',
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: const {},
    tags: const [],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  );

  /// B2：双击当前 tab 回顶——把回顶回调登记给 shell。
  /// （方法 tear-off：同一实例上的 tear-off 互相 ==，
  /// 登记与注销两端天然匹配。）
  void _scrollToTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(0,
          duration: Motion.normal, curve: Motion.standard);
    }
  }

  void _onCoverLoaded(int id) {
    if (_loadedIds.contains(id)) return;
    _loadedIds.add(id);
    _loadedOrder.add(id);
    if (_reorderFrozen || _reorderScheduled || !mounted) return;
    // 合帧：一次滚动内可能同时完成多张，避免每张都 setState
    _reorderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reorderScheduled = false;
      if (mounted && !_reorderFrozen) setState(() {});
    });
  }

  /// 已加载的排前面（按加载先后），其余保持原顺序。
  List<BangumiItem> _byLoadedFirst(List<BangumiItem> items) {
    if (_loadedOrder.isEmpty) return items;
    final rank = <int, int>{};
    for (var i = 0; i < _loadedOrder.length; i++) {
      rank[_loadedOrder[i]] = i;
    }
    final sorted = items.toList();
    // 稳定排序：Dart 的 List.sort 不稳定，这里带上原始下标兜底
    final origIndex = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      origIndex[items[i].id] = i;
    }
    sorted.sort((a, b) {
      final ra = rank[a.id];
      final rb = rank[b.id];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return -1;
      if (rb != null) return 1;
      return origIndex[a.id]!.compareTo(origIndex[b.id]!);
    });
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: popularController.scrollOffset,
    );
    scrollController.addListener(scrollListener);
    // B2：当前 tab 存活期间向 shell 登记回顶回调。
    TabScrollToTop.register(_scrollToTop);
    // 先尝试读本地缓存；命中就完全不联网，
    // 只有第一次使用（或用户主动刷新）才走网络。
    if (popularController.trendList.isEmpty) {
      if (popularController.restoreFromCache()) {
        // C8：缓存会话的封面磁盘秒开，无需「先加载完的排前面」——
        // 直接冻结重排，静止首屏不再跳动一次。
        _reorderFrozen = true;
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  @override
  void dispose() {
    TabScrollToTop.unregister(_scrollToTop);
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    super.dispose();
  }

  void scrollListener() {
    popularController.scrollOffset = scrollController.offset;
    if (!_reorderFrozen && scrollController.offset > 24) {
      _reorderFrozen = true;
    }
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !popularController.isLoadingMore) {
      MiruLogger()
          .i('PopularPageController: Fetching next recommendation batch');
      if (popularController.currentTag != '') {
        popularController.queryBangumiByTag();
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  bool showWindowButton() {
    return GStorage.getSetting(SettingsKeys.showWindowButton);
  }

  /// 手动刷新（顶栏按钮 / 下拉）：C2——请求期间旧列表保留
  /// （controller 一次性替换），新数据落地后平滑回顶，
  /// 阅读位置不再被「清空→坍缩到 0」丢掉。
  /// 刷新失败时保持原位（内容原样保留，底部有重试入口）。
  Future<void> _refreshFeed() async {
    await popularController.refresh();
    if (mounted &&
        !popularController.loadMoreFailed &&
        scrollController.hasClients) {
      await scrollController.animateTo(0,
          duration: Motion.normal, curve: Motion.standard);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        // C3：移动端信息流的第一肌肉记忆——下拉刷新。
        // edgeOffset 略过钉住的磨砂工具栏，转圈出现在工具栏下方。
        onRefresh: _refreshFeed,
        displacement: 60,
        edgeOffset: MediaQuery.paddingOf(context).top + kToolbarHeight,
        child: CustomScrollView(
          // 内容不满一屏时也要能拉出刷新（Clamping 物理下
          // 默认滚不动，RefreshIndicator 便无从触发）。
          physics: const AlwaysScrollableScrollPhysics(),
          controller: scrollController,
          slivers: [
            buildSliverAppBar(),
            SliverToBoxAdapter(
              child: Observer(
                builder: (_) => AnimatedOpacity(
                  opacity: popularController.isLoadingMore ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: popularController.isLoadingMore
                      ? const LinearProgressIndicator(minHeight: 4)
                      : const SizedBox(height: 4),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  StyleString.cardSpace, 0, StyleString.cardSpace, 0),
              sliver: Observer(builder: (_) {
                if (popularController.isTimeOut) {
                  return SliverToBoxAdapter(
                    child: SizedBox(
                      height: 400,
                      child: BangumiMirrorErrorWidget(
                        onRetry: () {
                          // 防双击（N4）：重试进行中直接挡掉，避免并发
                          // 两次请求把 offset 双推进而静默跳页。
                          if (popularController.isLoadingMore) return;
                          // v1.6.8（W-🔵1）：重试分支必须与 contentGrid/
                          // scrollListener 同口径按 currentTag 取数——
                          // 此前用 trendList.isEmpty 判定，冷启动热门加载
                          // 失败（trendList 空）后切标签又失败的场景会错
                          // 误重拉热门，成功后按标签视图渲染空的
                          // bangumiList，页面变成无状态空白。
                          if (popularController.currentTag != '') {
                            popularController.queryBangumiByTag();
                          } else {
                            popularController.queryBangumiByTrend();
                          }
                        },
                        onSettingsReturned: () {
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  );
                }
                return contentGrid(
                  (popularController.currentTag == '')
                      ? popularController.trendList
                      : popularController.bangumiList,
                );
              }),
            ),
            // 底部让出毛玻璃导航条高度
            SliverToBoxAdapter(
              child: SizedBox(
                height: Space.lg + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 首页布局：顶部横版轮播（大横幅）+ 下方竖版海报网格。
  /// 轮播内容取列表最前几条，而置顶清单被排在最前，
  /// 因此大横幅展示的必定是置顶的那批国漫。
  ///
  /// 数据完全来自 Controller 已取回的 `BangumiItem` 列表，
  /// 这里不发起任何请求，也不改变任何取数逻辑。
  Widget contentGrid(List<BangumiItem> bangumiList) {
    final width = MediaQuery.sizeOf(context).width;
    final ts = MediaQuery.textScalerOf(context);

    // 下方为竖版海报，列数与原版一致
    int crossCount = 3;
    if (width > LayoutBreakpoint.compact['width']!) crossCount = 5;
    if (width > LayoutBreakpoint.medium['width']!) crossCount = 6;

    // 轮播用内置的固定 16:9 主视觉图，不再消耗列表条目，
    // 因此网格展示完整列表（置顶清单依然排在最前）。
    final gridItems = _byLoadedFirst(bangumiList);

    // 卡片高度 = 竖版封面(0.65) + 两行标题
    final double cardWidth = (width -
            StyleString.cardSpace * 2 -
            StyleString.cardSpace * (crossCount - 1)) /
        crossCount;
    final double extent = cardWidth / 0.65 + ts.scale(46.0);

    // C1：网格空且正在拉取（冷启动 / 首次切 tag）时铺 bone 骨架——
    // 「页面被抽掉」的观感来自空白帧；数据到达后 Observer 重建
    // 自动替换为真实卡片。轮播是内置固定图，照常展示。
    if (bangumiList.isEmpty && popularController.isLoadingMore) {
      return SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Space.lg),
              child: BangumiHeroCarousel(source: bangumiList),
            ),
          ),
          SliverToBoxAdapter(
            // IgnorePointer：骨架不可点——占位卡带的假数据
            // 点进去会导航到不存在的条目。
            child: IgnorePointer(
              child: Skeletonizer(
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossCount,
                    mainAxisSpacing: Space.md,
                    crossAxisSpacing: StyleString.cardSpace,
                    mainAxisExtent: extent,
                  ),
                  itemCount: crossCount * 2,
                  itemBuilder: (_, __) =>
                      BangumiFeedCardV(bangumiItem: _skeletonBangumi),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: Space.lg),
            child: BangumiHeroCarousel(source: bangumiList),
          ),
        ),
        SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            mainAxisSpacing: Space.md,
            crossAxisSpacing: StyleString.cardSpace,
            crossAxisCount: crossCount,
            mainAxisExtent: extent,
          ),
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) {
              if (gridItems.isEmpty) return null;
              final item = gridItems[index];
              return BangumiFeedCardV(
                // key 绑定 id，重排时复用已建好的元素，避免重新解码图片
                key: ValueKey(item.id),
                bangumiItem: item,
                onImageLoaded: () => _onCoverLoaded(item.id),
              );
            },
            childCount: gridItems.length,
          ),
        ),
        // 翻页失败的重试入口（列表非空时不再静默）。
        // 单独 Observer：靠 isLoadingMore 的变化触发重建读取最新值。
        SliverToBoxAdapter(
          child: Observer(
            builder: (_) {
              if (popularController.isLoadingMore ||
                  !popularController.loadMoreFailed) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Center(
                  child: TextButton.icon(
                    // 防双击（N4）：横幅随 Observer 重建消失有约一帧延迟，
                    // 连点会并发两次翻页请求（offset 双推进跳页），入口挡掉。
                    onPressed: () {
                      if (popularController.isLoadingMore) return;
                      if (popularController.currentTag != '') {
                        popularController.queryBangumiByTag();
                      } else {
                        popularController.queryBangumiByTrend();
                      }
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('加载更多失败，点击重试'),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget buildSliverAppBar() {
    final theme = Theme.of(context);
    // 展开高度 = 工具栏 + 状态栏 + 固定的标题富余区。
    // 之前写死 120dp：状态栏较高的设备（挖孔屏/大字体）上
    // SafeArea 吃掉大半高度，标题与右侧按钮被挤进工具栏里互相遮挡。
    final double topInset = MediaQuery.paddingOf(context).top;
    final double expandedHeight = kToolbarHeight + topInset + 52;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expandedHeight,
      elevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      // 透明 + 毛玻璃：内容从下方滚过时能透出来，才有真正的玻璃效果
      backgroundColor: Colors.transparent,
      actions: buildActions(),
      title: null,
      flexibleSpace: FrostedSurface(
        child: SafeArea(
          child: dtb.DragToMoveArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double maxExtent = expandedHeight - topInset;
                final t = (1 -
                    ((constraints.maxHeight - kToolbarHeight) /
                            (maxExtent - kToolbarHeight))
                        .clamp(0.0, 1.0));
                // 衬线体只打包 400 / 600 两档，统一用 w600 保证渲染一致，
                // 层次改由字号收缩来表达。
                const fontWeight = FontWeight.w600;
                final fontSize = lerpDouble(28, 20, t)!;
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 16, top: 8, bottom: 8, right: 60),
                    child: SizedBox(
                      height: 44,
                      child: Observer(
                        builder: (_) {
                          final bool isTrend =
                              popularController.currentTag == '';
                          // v1.3.1 回退为无边框原版样式：玻璃药丸的底色
                          // 在部分主题下会遮挡标题文字。key 供 showTagMenu
                          // 定位下拉菜单。
                          return InkWell(
                            key: selectorKey,
                            borderRadius: BorderRadius.circular(8),
                            onTap: showTagMenu,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  isTrend
                                      ? '热门番组'
                                      : popularController.currentTag,
                                  style:
                                      theme.textTheme.headlineMedium!.copyWith(
                                    fontWeight: fontWeight,
                                    fontSize: fontSize,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.keyboard_arrow_down_rounded,
                                    size: fontSize,
                                    color: theme.iconTheme.color),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> buildActions() {
    final actions = <Widget>[
      if (MediaQuery.of(context).orientation == Orientation.portrait)
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.pushNamed('/search/'),
          icon: const Icon(Icons.search_rounded),
        ),
    ];
    actions.add(
      IconButton(
        tooltip: '刷新推荐',
        onPressed: () async {
          MiruDialog.showToast(message: '正在刷新推荐…', context: context);
          // C2：刷新期间旧列表保留，落地后平滑回顶（见 _refreshFeed）。
          await _refreshFeed();
        },
        icon: const Icon(Icons.refresh_rounded),
      ),
    );
    actions.add(
      IconButton(
        tooltip: '历史记录',
        onPressed: () => context.pushNamed('/settings/history/'),
        icon: const Icon(Icons.history_rounded),
      ),
    );
    if (isDesktop()) {
      if (!showWindowButton()) {
        actions.add(
          IconButton(
            tooltip: '退出',
            onPressed: () => windowManager.close(),
            icon: const Icon(Icons.close_rounded),
          ),
        );
      }
    }
    return actions;
  }

  Future<void> showTagMenu() async {
    // Calculate the position of the button manually to position the dropdown menu.
    // Using CustomDropdownMenu instead of PopupMenuButton to avoid flickering issues
    // and to support different font sizes in the button and menu items.
    final RenderBox renderBox =
        selectorKey.currentContext!.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;

    final selected = await Navigator.push<String>(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return CustomDropdownMenu(
            offset: offset,
            buttonSize: size,
            animation: animation,
            // v1.6.7（F-8）：minWidth 默认 140 会静默吞掉 maxWidth: 80——
            // 显式传 minWidth 让窄菜单真正生效（菜单不再比锚点宽一截）。
            minWidth: 80,
            maxWidth: 80,
            items: [
              '',
              ...defaultAnimeTags,
            ],
            itemBuilder: (item) => item.isEmpty ? '热门番组' : item,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      ),
    );

    if (selected == null) return;
    if (selected == '' && popularController.currentTag != '') {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag('');
      popularController.clearBangumiList();
      // 清掉分类页遗留的翻页失败态（N5）：否则切回热门后底部仍
      // 残留「加载更多失败」横幅（currentTag 变化会触发外层 Observer
      // 重建，横幅随之按新值隐藏）；反向切换由 queryBangumiByTag
      // 的 'init' 路径自行复位。
      popularController.loadMoreFailed = false;
      if (popularController.trendList.isEmpty) {
        await popularController.queryBangumiByTrend();
      }
    } else if (selected != '' && selected != popularController.currentTag) {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag(selected);
      await popularController.queryBangumiByTag(type: 'init');
    }
  }
}
