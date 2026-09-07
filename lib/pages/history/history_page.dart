import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/card/bangumi_history_card.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/dialog/destructive_confirm.dart';
import 'package:miru/bean/widget/empty_state_widget.dart';
import 'package:miru/pages/history/history_controller.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/utils/constants.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.controller,
  });

  final HistoryController controller;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistoryController get historyController => widget.controller;

  bool showDelete = false;

  @override
  void initState() {
    super.initState();
    historyController.init();
  }

  void onBackPressed(BuildContext context) {
    if (MiruDialog.observer.hasMiruDialog) {
      MiruDialog.dismiss();
      return;
    }
  }

  Future<void> showHistoryClearDialog() async {
    // 统一危险确认样式：标题如实描述动作（此前叫「记录管理」，
    // 语义含糊），正文写清后果（续播进度也一并没了），确认键标 error 色。
    final confirmed = await showDestructiveConfirm(
      context,
      title: '清除全部历史',
      message: '将删除全部观看进度记录（含各番剧的续播位置），此操作不可恢复。',
      confirmLabel: '清除',
    );
    if (confirmed) {
      await _clearAllHistories();
    }
  }

  /// clearAll 是 async：之前用同步 try/catch 包裹，
  /// 异步错误根本捕不到（未 await 就逃逸成未处理异常）。
  Future<void> _clearAllHistories() async {
    try {
      await historyController.clearAll();
    } catch (e, stackTrace) {
      MiruLogger()
          .e('History: clear all histories failed', error: e, stackTrace: stackTrace);
      MiruDialog.showToast(message: '清除历史记录失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          onBackPressed(context);
        },
        child: Scaffold(
          appBar: SysAppBar(
            title: const Text('历史记录'),
            actions: [
              if (historyController.histories.isNotEmpty) ...[
                IconButton(
                  onPressed: () {
                    setState(() {
                      showDelete = !showDelete;
                    });
                  },
                  icon: showDelete
                      ? const Icon(Icons.edit_off_outlined)
                      : const Icon(Icons.edit_outlined),
                  tooltip: showDelete ? '退出编辑' : '编辑',
                ),
                IconButton(
                  onPressed: () {
                    showHistoryClearDialog();
                  },
                  icon: const Icon(Icons.delete_sweep_outlined),
                  tooltip: '清除全部',
                ),
              ],
            ],
          ),
          body: SafeArea(bottom: false, child: renderBody),
        ),
      );
    });
  }

  Widget get renderBody {
    if (historyController.histories.isNotEmpty) {
      return contentGrid;
    } else {
      return const Center(
        child: GeneralEmptyState(
          icon: Icons.history_rounded,
          title: '暂无历史记录',
        ),
      );
    }
  }

  Widget get contentGrid {
    int crossCount = 1;
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!) {
      crossCount = 2;
    }
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.medium['width']!) {
      crossCount = 3;
    }

    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double maxContentWidth = 1000;
    final double horizontalPadding =
        screenWidth > maxContentWidth ? (screenWidth - maxContentWidth) / 2 : 0;

    // 按自然日分组（今天/昨天/本周/更早）：追番应用的历史页核心
    // 诉求是回找「昨天看的那部」，纯平铺 + 卡内相对时间（3 天前/
    // 2 个月前）在长列表里扫读成本高。列表已按观看时间倒序。
    final now = DateTime.now();
    String groupOf(DateTime t) {
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(t.year, t.month, t.day);
      final diffDays = today.difference(day).inDays;
      if (diffDays <= 0) return '今天';
      if (diffDays == 1) return '昨天';
      if (diffDays < 7) return '本周';
      return '更早';
    }

    final histories = historyController.histories;
    final groups = <String, List<int>>{};
    for (var i = 0; i < histories.length; i++) {
      groups.putIfAbsent(groupOf(histories[i].lastWatchTime), () => []).add(i);
    }

    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 4)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverMainAxisGroup(
            slivers: [
              for (final entry in groups.entries) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Text(
                      entry.key,
                      style: textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    mainAxisSpacing: 2,
                    crossAxisSpacing: StyleString.cardSpace,
                    crossAxisCount: crossCount,
                    mainAxisExtent: 136,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      final historyIndex = entry.value[index];
                      return BangumiHistoryCardV(
                        historyItem: histories[historyIndex],
                        showDelete: showDelete,
                        onDeleted: () {
                          historyController
                              .deleteHistory(histories[historyIndex]);
                        },
                      );
                    },
                    childCount: entry.value.length,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
      ],
    );
  }
}
