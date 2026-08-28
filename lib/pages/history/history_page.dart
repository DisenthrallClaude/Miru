import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/card/bangumi_history_card.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
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

  void showHistoryClearDialog() {
    MiruDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('记录管理'),
          content: const Text('确认要清除所有历史记录吗?'),
          actions: [
            TextButton(
              onPressed: () {
                MiruDialog.dismiss();
              },
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () {
                MiruDialog.dismiss();
                _clearAllHistories();
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
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

    return CustomScrollView(
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 4)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              mainAxisSpacing: 2,
              crossAxisSpacing: StyleString.cardSpace,
              crossAxisCount: crossCount,
              mainAxisExtent: 136,
            ),
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                return BangumiHistoryCardV(
                  historyItem: historyController.histories[index],
                  showDelete: showDelete,
                  onDeleted: () {
                    historyController
                        .deleteHistory(historyController.histories[index]);
                  },
                );
              },
              childCount: historyController.histories.length,
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
      ],
    );
  }
}
