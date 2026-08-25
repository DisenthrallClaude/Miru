import 'dart:async';
import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/hive_registrar.g.dart';
import 'package:miru/modules/history/history_module.dart';
import 'package:miru/modules/collect/collect_module.dart';
import 'package:miru/modules/collect/collect_change_module.dart';
import 'package:miru/modules/collect/collect_sync_merger.dart';
import 'package:miru/modules/search/search_history_module.dart';
import 'package:miru/modules/download/download_module.dart';
import 'package:miru/services/storage/history_storage_coordinator.dart';

import 'package:miru/services/storage/settings_keys.dart';
export 'package:miru/services/storage/settings_keys.dart';

class GStorage {
  /// Don't use favorites box, it's replaced by collectibles.
  static late Box<BangumiItem> favorites;
  static late Box<CollectedBangumi> collectibles;
  static late Box<History> histories;
  static late Box<CollectedBangumiChange> collectChanges;
  static late Box<String> shieldList;
  static late final Box<dynamic> _setting;
  static late Box<SearchHistory> searchHistory;
  static late Box<DownloadRecord> downloads;

  /// 推荐页信息流的本地缓存（含置顶清单），避免每次启动都重新联网。
  static late Box<BangumiItem> popularCache;

  /// 时间表的本地缓存，按季度失效（见 SettingsKeys.calendarCacheSeason）。
  static late Box<BangumiItem> calendarCache;

  /// Hive directory path, initialized during init()
  static String? _hivePath;

  /// Queue to serialize write operations
  static Future<void> _collectChangesWriteQueue = Future.value();

  /// Next ID
  static int _nextCollectChangeId = 0;

  /// Flag to indicate if the next ID has initialized
  static bool _collectChangeIdInitialized = false;

  /// Ensure collect-related write sequentially
  static Future<T> _runCollectChangesWriteExclusive<T>(
    Future<T> Function() action,
  ) {
    final completer = Completer<T>();
    final previousWrite = _collectChangesWriteQueue;

    _collectChangesWriteQueue = (() async {
      try {
        await previousWrite;
      } catch (_) {}

      try {
        completer.complete(await action());
      } catch (e, stackTrace) {
        completer.completeError(e, stackTrace);
      }
    })();

    return completer.future;
  }

  /// init id generator
  static void _initializeNextCollectChangeIdLocked() {
    if (_collectChangeIdInitialized) {
      return;
    }

    var maxExistingId = 0;
    for (final key in collectChanges.keys) {
      if (key is int && key > maxExistingId) {
        maxExistingId = key;
      }
    }

    _nextCollectChangeId = maxExistingId;
    _collectChangeIdInitialized = true;
  }

  /// Generate id for collect change
  static int _generateCollectChangeIdLocked() {
    _initializeNextCollectChangeIdLocked();

    final currentSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Ensure ID is greater than any existing ID, or equal to current timestamp.
    var nextId = _nextCollectChangeId < currentSeconds
        ? currentSeconds
        : _nextCollectChangeId + 1;
    while (collectChanges.containsKey(nextId)) {
      nextId++;
    }
    _nextCollectChangeId = nextId;
    return nextId;
  }

  /// Append a new collect change
  static Future<CollectedBangumiChange> appendCollectChange({
    required int bangumiId,
    required int action,
    required int type,
    int? timestamp,
  }) {
    return _runCollectChangesWriteExclusive(() async {
      final change = CollectedBangumiChange(
        _generateCollectChangeIdLocked(),
        bangumiId,
        action,
        type,
        timestamp ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
      await collectChanges.put(change.id, change);
      await collectChanges.flush();
      return change;
    });
  }

  /// Update an existing collect change
  static Future<void> putCollectChange(CollectedBangumiChange change) {
    return _runCollectChangesWriteExclusive(() async {
      _initializeNextCollectChangeIdLocked();
      if (change.id > _nextCollectChangeId) {
        _nextCollectChangeId = change.id;
      }
      await collectChanges.put(change.id, change);
      await collectChanges.flush();
    });
  }

  /// Put a collectible using the same write queue
  static Future<void> putCollectible(CollectedBangumi collectible) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.put(collectible.bangumiItem.id, collectible);
      await collectibles.flush();
    });
  }

  /// Delete a collectible using the shared collect write queue.
  static Future<void> deleteCollectible(int bangumiId) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.delete(bangumiId);
      await collectibles.flush();
    });
  }

  static Future init() async {
    _hivePath = '${(await getApplicationSupportDirectory()).path}/hive';

    Hive.registerAdapters();

    // Open each box with automatic recovery on corruption
    favorites = await _openBoxSafe<BangumiItem>('favorites');
    collectibles = await _openBoxSafe<CollectedBangumi>('collectibles');
    histories = await _openBoxSafe<History>('histories');
    _setting = await _openBoxSafe<dynamic>('setting');
    collectChanges =
        await _openBoxSafe<CollectedBangumiChange>('collectchanges');
    shieldList = await _openBoxSafe<String>('shieldList');
    searchHistory = await _openBoxSafe<SearchHistory>('searchHistory');
    downloads = await _openBoxSafe<DownloadRecord>('downloads');
    popularCache = await _openBoxSafe<BangumiItem>('popularCache');
    calendarCache = await _openBoxSafe<BangumiItem>('calendarCache');
  }

  /// Open a Hive box with automatic recovery on corruption.
  /// The corrupted files are preserved as `<box>.corrupt.hive` before being
  /// removed, so a broken write never silently destroys user data.
  static Future<Box<T>> _openBoxSafe<T>(String boxName) async {
    try {
      return await Hive.openBox<T>(boxName);
    } catch (e) {
      MiruLogger().e(
          'GStorage: Box "$boxName" corrupted, attempting recovery',
          error: e);

      // Back up the corrupted box files instead of destroying them.
      await _backupAndDeleteBoxFiles(boxName);

      // Try to open again (will create a new empty box)
      try {
        final box = await Hive.openBox<T>(boxName);
        MiruLogger().i(
            'GStorage: Box "$boxName" recovered successfully (corrupted copy kept as .corrupt.hive)');
        return box;
      } catch (e2) {
        MiruLogger()
            .e('GStorage: Failed to recover box "$boxName"', error: e2);
        rethrow;
      }
    }
  }

  /// Back up then delete Hive box files for a given box name.
  static Future<void> _backupAndDeleteBoxFiles(String boxName) async {
    if (_hivePath == null) return;

    final boxFile = File('$_hivePath/$boxName.hive');
    final lockFile = File('$_hivePath/$boxName.lock');

    try {
      if (await boxFile.exists()) {
        final backupFile = File('$_hivePath/$boxName.corrupt.hive');
        try {
          await boxFile.copy(backupFile.path);
          MiruLogger()
              .i('GStorage: Corrupted box backed up to ${backupFile.path}');
        } catch (backupError) {
          // 备份失败也不能放弃恢复流程，只记录告警继续删除重建。
          MiruLogger().w(
              'GStorage: Failed to back up corrupted box "$boxName"',
              error: backupError);
        }
        await boxFile.delete();
        MiruLogger()
            .i('GStorage: Deleted corrupted box file: $boxName.hive');
      }
      if (await lockFile.exists()) {
        await lockFile.delete();
        MiruLogger().i('GStorage: Deleted lock file: $boxName.lock');
      }
    } catch (e) {
      MiruLogger()
          .e('GStorage: Failed to delete box files for "$boxName"', error: e);
    }
  }

  static Future<void> backupBox(String boxName, String backupFilePath) async {
    final appDocumentDir = await getApplicationSupportDirectory();
    final hiveBoxFile = File('${appDocumentDir.path}/hive/$boxName.hive');
    if (await hiveBoxFile.exists()) {
      await hiveBoxFile.copy(backupFilePath);
      MiruLogger().i('GStorage: backup success: $backupFilePath');
    } else {
      MiruLogger().w('GStorage: Hive box does not exist: $boxName');
    }
  }

  static Future<void> patchHistory(String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox = await Hive.openBox('tempHistoryBox', bytes: backupContent);
    try {
      final tempBoxItems = tempBox.toMap().entries;
      await HistoryStorageCoordinator().run(() async {
        for (final tempBoxItem in tempBoxItems) {
          final tempHistory = tempBoxItem.value as History;
          tempHistory.entryKind =
              HistoryEntryKind.normalize(tempHistory.entryKind);
          final targetKey = tempHistory.key;
          final existing = histories.get(targetKey);
          if (existing == null ||
              existing.lastWatchTime.isBefore(tempHistory.lastWatchTime)) {
            await histories.put(targetKey, tempHistory);
          }
        }
      });
    } finally {
      await tempBox.close();
    }
  }

  static Future<void> restoreCollectibles(String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    // 使用独立盒名，避免与 getCollectiblesFromFile 的预览盒冲突。
    final tempBox =
        await Hive.openBox('tempRestoreCollectiblesBox', bytes: backupContent);
    try {
      final tempBoxItems = tempBox.toMap().entries;
      MiruLogger().i(
          'WebDav: restoring collectibles. tempCollectiblesBox length ${tempBoxItems.length}');

      // 与 putCollectible/deleteCollectible 共享同一把写锁，
      // 否则恢复期间的用户操作会互相覆盖。
      await _runCollectChangesWriteExclusive(() async {
        // clear+put 不是事务：中途失败必须回滚旧数据，
        // 不能让一次失败的恢复把收藏清空。
        // Box<T> 的 toMap 值类型会被擦除，回滚时需显式 cast 回元素类型。
        final previousEntries =
            Map<dynamic, dynamic>.of(collectibles.toMap());
        try {
          await collectibles.clear();
          for (var tempBoxItem in tempBoxItems) {
            await collectibles.put(tempBoxItem.key, tempBoxItem.value);
          }
          await collectibles.flush();
        } catch (e) {
          await collectibles.clear();
          for (final entry in previousEntries.entries) {
            await collectibles.put(entry.key, entry.value);
          }
          await collectibles.flush();
          MiruLogger()
              .e('WebDav: restore collectibles failed, rolled back', error: e);
          rethrow;
        }
      });
    } finally {
      await tempBox.close();
    }
  }

  static Future<List<CollectedBangumi>> getCollectiblesFromFile(
      String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox =
        await Hive.openBox('tempCollectiblesBox', bytes: backupContent);
    final tempBoxItems = tempBox.toMap().entries;
    MiruLogger().i(
        'WebDav: get collectibles from file. tempCollectiblesBox length ${tempBoxItems.length}');

    final List<CollectedBangumi> collectibles = [];
    for (var tempBoxItem in tempBoxItems) {
      collectibles.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectibles;
  }

  static Future<List<CollectedBangumiChange>> getCollectChangesFromFile(
      String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox =
        await Hive.openBox('tempCollectChangesBox', bytes: backupContent);
    final tempBoxItems = tempBox.toMap().entries;
    MiruLogger().i(
        'WebDav: get collectChanges from file. tempCollectChangesBox length ${tempBoxItems.length}');

    final List<CollectedBangumiChange> collectChanges = [];
    for (var tempBoxItem in tempBoxItems) {
      collectChanges.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectChanges;
  }

  static Future<void> patchCollectibles(
      List<CollectedBangumi> remoteCollectibles,
      List<CollectedBangumiChange> remoteChanges) async {
    await _runCollectChangesWriteExclusive(() async {
      final mergeResult = CollectSyncMerger.mergeWebDav(
        localCollectibles: collectibles.values.toList(),
        localChanges: collectChanges.values.toList(),
        remoteCollectibles: remoteCollectibles,
        remoteChanges: remoteChanges,
      );

      // clear+put 不是事务，合并中途失败时回滚到旧数据，
      // 避免同步半途而废造成收藏/变更记录丢失。
      // Box<T> 的 toMap 值类型会被擦除，回滚时需显式 cast 回元素类型。
      final previousCollectibles =
          Map<dynamic, dynamic>.of(collectibles.toMap());
      final previousChanges = Map<dynamic, dynamic>.of(collectChanges.toMap());
      try {
        // Update local storage
        await collectibles.clear();
        for (var collect in mergeResult.collectibles) {
          await collectibles.put(collect.bangumiItem.id, collect);
        }
        await collectibles.flush();

        await collectChanges.clear();
        for (var change in mergeResult.changes) {
          await collectChanges.put(change.id, change);
        }
        await collectChanges.flush();
      } catch (e) {
        await collectibles.clear();
        for (final entry in previousCollectibles.entries) {
          await collectibles.put(entry.key, entry.value);
        }
        await collectibles.flush();
        await collectChanges.clear();
        for (final entry in previousChanges.entries) {
          await collectChanges.put(entry.key, entry.value);
        }
        await collectChanges.flush();
        MiruLogger()
            .e('GStorage: patch collectibles failed, rolled back', error: e);
        rethrow;
      }

      _collectChangeIdInitialized = false;
      _initializeNextCollectChangeIdLocked();
    });
  }

  static T getSetting<T>(
    SettingKey<T> key, {
    SettingContext context = const SettingContext(),
  }) {
    final defaultValue = key.resolveDefault(context);
    final storedValue = _setting.get(key.name);
    if (storedValue is T) {
      return storedValue;
    }
    return defaultValue;
  }

  static Future<void> putSetting<T>(SettingKey<T> key, T value) async {
    await _setting.put(key.name, value);
  }

  static List<String> getStringListSettingByName(
    String key, {
    List<String> defaultValue = const [],
  }) {
    final storedValue = _setting.get(key);
    if (storedValue is List) {
      return storedValue.whereType<String>().toList();
    }
    return defaultValue;
  }

  static Future<void> putStringListSettingByName(
    String key,
    List<String> value,
  ) async {
    await _setting.put(key, value);
  }

  static Future<void> resetSettings(Iterable<SettingKey<Object?>> keys) async {
    await _setting.deleteAll(keys.map((key) => key.name));
    await _setting.flush();
  }

  static Future<void> resetPlayerSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.player));
  }

  static Future<void> resetDanmakuSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.danmaku));
  }

  GStorage._();
}
