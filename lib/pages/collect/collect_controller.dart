import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/collect/collect_module.dart';
import 'package:miru/modules/collect/collect_type.dart';
import 'package:miru/services/sync/bangumi_sync_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/sync/github_sync.dart';
import 'package:miru/services/sync/webdav.dart';
import 'package:miru/repositories/collect_crud_repository.dart';
import 'package:miru/repositories/collect_repository.dart';
import 'package:mobx/mobx.dart';
import 'package:miru/services/logging/logger.dart';

part 'collect_controller.g.dart';

// Define actions for handling Bangumi collect deletion.
enum _BangumiDeleteSyncAction {
  deleteLocalOnly,
  markAbandoned,
  openWeb,
  cancel,
}

class CollectController = _CollectController with _$CollectController;

abstract class _CollectController with Store {
  _CollectController(
    this._collectCrudRepository,
    this._collectRepository,
  );

  final ICollectCrudRepository _collectCrudRepository;
  final ICollectRepository _collectRepository;

  List<BangumiItem> get favorites => _collectCrudRepository.getFavorites();

  @observable
  ObservableList<CollectedBangumi> collectibles =
      ObservableList<CollectedBangumi>();

  void loadCollectibles() {
    collectibles.clear();
    collectibles.addAll(_collectCrudRepository.getAllCollectibles());
  }

  int getCollectType(BangumiItem bangumiItem) {
    return _collectCrudRepository.getCollectType(bangumiItem.id);
  }

  BangumiItem? getCollectibleBangumiItem(int id) {
    return _collectCrudRepository.getCollectible(id)?.bangumiItem;
  }

  @action
  Future<void> addCollect(BangumiItem bangumiItem, {type = 1}) async {
    if (type == 0) {
      await deleteCollect(bangumiItem);
      return;
    }

    // 1. Sync with Bangumi if enabled
    final bool syncSucceeded = await _syncBangumiCollectIfEnabled(
      bangumiItem.id,
      type,
    );
    if (!syncSucceeded) {
      return;
    }

    final int currentCollectType = getCollectType(bangumiItem);
    final int collectChangeAction = currentCollectType == 0 ? 1 : 2;

    // 2. Update local database and change logs
    await _collectCrudRepository.addCollectible(bangumiItem, type);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: collectChangeAction,
      type: type,
    );
    loadCollectibles();
  }

  @action
  Future<void> deleteCollect(BangumiItem bangumiItem) async {
    // Resolve how to handle deletion with user
    final action = await _resolveBangumiDeleteSyncAction(bangumiItem);
    switch (action) {
      case _BangumiDeleteSyncAction.markAbandoned:
        await addCollect(
          bangumiItem,
          type: CollectType.abandoned.value,
        );
        return;

      case _BangumiDeleteSyncAction.openWeb:
        await _deleteCollectLocally(bangumiItem);
        await _openBangumiSubjectPage(bangumiItem.id);
        return;

      case _BangumiDeleteSyncAction.deleteLocalOnly:
        await _deleteCollectLocally(bangumiItem);
        return;

      case _BangumiDeleteSyncAction.cancel:
      case null:
        return;
    }
  }

  Future<void> _deleteCollectLocally(BangumiItem bangumiItem) async {
    await _collectCrudRepository.deleteCollectible(bangumiItem.id);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: 3,
      type: 5,
    );
    loadCollectibles();
  }

  Future<_BangumiDeleteSyncAction?> _resolveBangumiDeleteSyncAction(
      BangumiItem bangumiItem) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (!syncEnable) {
      return _BangumiDeleteSyncAction.deleteLocalOnly;
    }

    final bangumi = BangumiSyncService();
    if (!bangumi.initialized) {
      return _BangumiDeleteSyncAction.deleteLocalOnly;
    }

    return MiruDialog.show<_BangumiDeleteSyncAction>(
      clickMaskDismiss: true,
      builder: (context) => AlertDialog(
        title: const Text('Bangumi 不支持删除收藏'),
        content: const Text(
          '因为安全考虑，Bangumi 未提供删除接口，您可以选择把本地和远端标记为“抛弃”，或者选择仅删除本地收藏并打开网页后手动删除 Bangumi 数据。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.cancel);
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.openWeb);
            },
            child: const Text('打开网页'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.markAbandoned);
            },
            child: const Text('标记为抛弃'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBangumiSubjectPage(int bangumiId) async {
    final url = Uri.parse('https://bangumi.tv/subject/$bangumiId');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    MiruDialog.showToast(message: '无法打开 Bangumi 网页');
  }

  Future<bool> _syncBangumiCollectIfEnabled(
      int bangumiId, int localType) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    final bool showImmediateSyncToast =
        GStorage.getSetting(SettingsKeys.bangumiImmediateSyncToastEnable);

    if (!syncEnable) {
      return true;
    }

    final bangumi = BangumiSyncService();
    if (!bangumi.initialized) {
      MiruDialog.showToast(message: 'Bangumi 未初始化，同步失败，已取消本次状态修改');
      MiruLogger().w(
        'Bangumi: immediate collect sync skipped because Bangumi is not initialized. '
        'bangumiId=$bangumiId, type=$localType',
      );
      return false;
    }
    try {
      if (showImmediateSyncToast) {
        MiruDialog.showToast(message: '正在同步到 Bangumi...');
      }
      final bool synced =
          await bangumi.syncCollectibleWhenIdle(bangumiId, localType);
      if (synced && showImmediateSyncToast) {
        MiruDialog.showToast(message: '已同步到 Bangumi');
        return true;
      } else if (!synced) {
        MiruDialog.showToast(message: '同步到 Bangumi 失败，已取消本次状态修改');
        MiruLogger().w(
          'Bangumi: immediate collect sync did not complete. bangumiId=$bangumiId, type=$localType',
        );
        return false;
      }
      return true;
    } catch (e, stackTrace) {
      MiruDialog.showToast(message: '同步到 Bangumi 失败，已取消本次状态修改: $e');
      MiruLogger().e(
        'Bangumi: immediate collect sync failed. bangumiId=$bangumiId, type=$localType',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> updateLocalCollect(BangumiItem bangumiItem) async {
    await _collectCrudRepository.updateCollectible(bangumiItem);
    loadCollectibles();
  }

  Future<bool> syncCollectibles({bool showSuccessToast = true}) async {
    final bool webDavCollectEnable =
        GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    final bool githubCollectEnable =
        GStorage.getSetting(SettingsKeys.githubEnableCollect) &&
            GStorage.getSetting(SettingsKeys.githubEnable);
    if (!webDavCollectEnable && !githubCollectEnable) {
      MiruDialog.showToast(message: '未开启任何收藏同步通道');
      return false;
    }
    var succeeded = true;
    if (webDavCollectEnable) {
      succeeded = await _syncCollectiblesViaWebDav(showSuccessToast) && succeeded;
    }
    if (githubCollectEnable) {
      succeeded = await _syncCollectiblesViaGithub() && succeeded;
    }
    loadCollectibles();
    return succeeded;
  }

  Future<bool> _syncCollectiblesViaWebDav(bool showSuccessToast) async {
    if (!WebDav().initialized) {
      MiruDialog.showToast(message: '未开启WebDav同步或配置无效');
      return false;
    }
    bool flag = true;
    try {
      await WebDav().ping();
    } catch (e) {
      MiruLogger().e('WebDav: WebDav connection failed', error: e);
      MiruDialog.showToast(message: 'WebDav连接失败: $e');
      flag = false;
    }
    if (!flag) {
      return false;
    }
    try {
      await WebDav().syncCollectibles();
      if (showSuccessToast) {
        MiruDialog.showToast(message: 'WebDav同步完成');
      }
    } catch (e) {
      MiruDialog.showToast(message: 'WebDav同步失败 $e');
      return false;
    }
    return true;
  }

  Future<bool> _syncCollectiblesViaGithub() async {
    try {
      final github = GithubSync();
      if (!github.initialized) {
        await github.init();
      }
      await github.syncCollectibles();
      MiruDialog.showToast(message: 'GitHub 同步完成');
      return true;
    } catch (e) {
      MiruLogger().w('GithubSync: collectibles sync failed', error: e);
      MiruDialog.showToast(message: 'GitHub 同步失败：$e');
      return false;
    }
  }

  /// Only upload local collectibles and change logs to WebDAV, without downloading and merging.
  /// Used by full sync to push Bangumi-updated local changes back to WebDAV.
  Future<bool> uploadCollectiblesToWebDav(
      {bool showSuccessToast = true}) async {
    final bool webDavCollectEnable =
        GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    if (!webDavCollectEnable) {
      MiruDialog.showToast(message: '未开启WebDav收藏同步');
      return false;
    }
    if (!WebDav().initialized) {
      MiruDialog.showToast(message: '未开启WebDav同步或配置无效');
      return false;
    }
    bool flag = true;
    try {
      await WebDav().ping();
    } catch (e) {
      MiruLogger().e('WebDav: WebDav connection failed', error: e);
      MiruDialog.showToast(message: 'WebDav连接失败: $e');
      flag = false;
    }
    if (!flag) {
      return false;
    }
    try {
      await WebDav().updateCollectibles();
      if (showSuccessToast) {
        MiruDialog.showToast(message: 'WebDav上传完成');
      }
    } catch (e) {
      MiruDialog.showToast(message: 'WebDav上传失败 $e');
      return false;
    }
    // Bangumi 全量同步改动了本地收藏，GitHub 通道也要跟进上传，
    // 否则两个云端的收藏会就此分叉。
    if (GStorage.getSetting(SettingsKeys.githubEnable) &&
        GStorage.getSetting(SettingsKeys.githubEnableCollect)) {
      try {
        final github = GithubSync();
        if (!github.initialized) {
          await github.init();
        }
        await github.updateCollectibles();
      } catch (e) {
        MiruLogger().w('GithubSync: upload collectibles failed', error: e);
      }
    }
    return true;
  }

  // migrate collect from old version (favorites)
  Future<void> migrateCollect() async {
    if (favorites.isNotEmpty) {
      int count = 0;
      for (BangumiItem bangumiItem in favorites) {
        // Migration should never depend on runtime Bangumi initialization.
        // Persist locally and append change logs, then let later sync handle remote updates.
        final int currentCollectType = getCollectType(bangumiItem);
        final int collectChangeAction = currentCollectType == 0 ? 1 : 2;
        await _collectCrudRepository.addCollectible(bangumiItem, 1);
        await GStorage.appendCollectChange(
          bangumiId: bangumiItem.id,
          action: collectChangeAction,
          type: 1,
        );
        count++;
      }
      await _collectCrudRepository.clearFavorites();
      loadCollectibles();
      MiruLogger().d(
          'GStorage: detected $count uncategorized favorites, migrated to collectibles');
    }
  }

  /// 根据收藏类型获取番剧ID集合
  ///
  /// [type] 收藏类型
  /// 返回番剧ID集合
  Set<int> getBangumiIdsByType(CollectType type) {
    return _collectRepository.getBangumiIdsByType(type);
  }

  /// 过滤掉指定收藏类型的番剧
  ///
  /// [bangumiList] 原始番剧列表
  /// [excludeType] 要排除的收藏类型
  /// 返回过滤后的番剧列表
  List<BangumiItem> filterBangumiByType(
      List<BangumiItem> bangumiList, CollectType excludeType) {
    final excludeIds = getBangumiIdsByType(excludeType);
    return bangumiList.where((item) => !excludeIds.contains(item.id)).toList();
  }

  /// Sync Bangumi collectibles.
  Future<bool> syncCollectiblesBangumi(
      {void Function(String message, int current, int total)? onProgress,
      bool showSuccessToast = true}) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (!syncEnable) {
      MiruDialog.showToast(message: '未开启Bangumi同步，请先在设置中启用');
      return false;
    }

    if (!BangumiSyncService().initialized) {
      MiruDialog.showToast(message: 'Bangumi同步已开启但未初始化，请检查Token后重试');
      return false;
    }
    try {
      await BangumiSyncService().ping();
      try {
        final hasChanges =
            await BangumiSyncService().syncCollectibles(onProgress: onProgress);
        if (showSuccessToast) {
          MiruDialog.showToast(
            message: hasChanges ? 'Bangumi同步完成' : '未发现状态差异，无需同步',
          );
        }
      } catch (e) {
        MiruDialog.showToast(message: 'Bangumi同步失败 $e');
        return false;
      }
    } catch (e) {
      MiruLogger().e('Bangumi: Bangumi connection failed', error: e);
      MiruDialog.showToast(message: 'Bangumi访问失败: $e');
      return false;
    }
    loadCollectibles();
    return true;
  }
}
