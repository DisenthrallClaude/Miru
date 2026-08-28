import 'dart:io';

import 'package:miru/modules/collect/collect_change_module.dart';
import 'package:miru/modules/collect/collect_module.dart';
import 'package:miru/modules/history/history_sync.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/sync/github_api.dart';
import 'package:miru/services/sync/history_sync_service.dart';
import 'package:miru/utils/async_serial_queue.dart';
import 'package:miru/utils/async_single_flight.dart';
import 'package:path_provider/path_provider.dart';

/// GitHub 云同步：把观看历史与追番收藏同步到用户自己的私有仓库。
///
/// 与 WebDAV 同步共用同一套合并引擎（HistorySyncService /
/// GStorage.patchCollectibles），仅传输层不同——远端是一个 git 仓库：
///
/// ```
/// <repo>/
/// └── data/
///     ├── history/
///     │   ├── snapshot.json          # 全量快照
///     │   └── changes/<deviceId>.jsonl  # 各设备增量日志
///     ├── collectibles.tmp           # 收藏 Hive 盒快照
///     └── collectchanges.tmp         # 收藏变更日志 Hive 盒快照
/// ```
///
/// 认证只接受 Personal Access Token（GitHub 已废弃第三方账号密码直登）。
class GithubSync {
  GithubSync._internal();

  static final GithubSync _instance = GithubSync._internal();
  factory GithubSync() => _instance;

  static const String _dataRoot = 'data';
  static const String _historyRootPath = '$_dataRoot/history';
  static const String _historyChangesPath = '$_historyRootPath/changes';
  static const String _historySnapshotPath = '$_historyRootPath/snapshot.json';
  static const String _defaultRepoName = 'miru-sync';

  GithubApi? _api;
  String _owner = '';
  String _repo = '';
  late Directory _tempDirectory;
  bool initialized = false;

  final AsyncSingleFlight<void> _historySyncSingleFlight =
      AsyncSingleFlight<void>();
  final AsyncSerialQueue _operationQueue = AsyncSerialQueue();

  bool get isHistorySyncing => _historySyncSingleFlight.isRunning;

  /// 当前登录用户名（缓存自上次验证，空串表示未登录）。
  String get login => GStorage.getSetting(SettingsKeys.githubLogin);

  bool get isLoggedIn =>
      GStorage.getSetting(SettingsKeys.githubEnable) &&
      login.isNotEmpty &&
      GStorage.getSetting(SettingsKeys.githubToken).isNotEmpty;

  /// 初始化：解密 Token → 验证身份 → 校验仓库可访问。
  /// Token 无效抛 [GithubAuthException]，仓库不存在抛 [GithubNotFoundException]。
  Future<void> init() async {
    final storedToken = GStorage.getSetting(SettingsKeys.githubToken);
    final token = await SecureFieldCodec.decrypt(storedToken);
    if (token == null || token.isEmpty) {
      throw GithubAuthException('Token 无法解密（密钥可能已被系统清除），请重新登录');
    }

    final api = GithubApi(token: token);
    final user = await api.getUser();
    final owner = user.login;
    if (owner.isEmpty) {
      throw GithubAuthException('GitHub 未返回用户名');
    }

    var repoFullName = GStorage.getSetting(SettingsKeys.githubRepo);
    // 兼容三种历史输入：空、"repo"、"owner/repo"。
    final repoName = repoFullName.contains('/')
        ? repoFullName.split('/').last
        : (repoFullName.isEmpty ? _defaultRepoName : repoFullName);
    final normalized = '$owner/$repoName';

    final repoInfo = await api.getRepo(owner: owner, repo: repoName);
    if (repoInfo == null) {
      api.dispose();
      throw GithubNotFoundException(
        '仓库 $normalized 不存在，请在设置页创建或手动新建',
      );
    }
    if (!repoInfo.isPrivate) {
      MiruLogger().w(
          'GithubSync: repo $normalized is PUBLIC; sync data would be visible to everyone');
    }

    _api?.dispose();
    _api = api;
    _owner = owner;
    _repo = repoName;
    _tempDirectory =
        Directory('${(await getApplicationSupportDirectory()).path}/githubTemp');
    await _ensureLocalTempDirectory();
    if (repoFullName != normalized) {
      await GStorage.putSetting(SettingsKeys.githubRepo, normalized);
    }
    await GStorage.putSetting(SettingsKeys.githubLogin, owner);
    await GStorage.putSetting(SettingsKeys.githubAvatarUrl, user.avatarUrl);
    initialized = true;
    MiruLogger().i('GithubSync: ready for $normalized');
  }

  /// 登录：验证 Token 并确保私有仓库存在（不存在则自动创建私有仓库）。
  /// 返回 "owner/repo" 全名。
  Future<String> loginAndEnsureRepo({String? repoName}) async {
    final storedToken = GStorage.getSetting(SettingsKeys.githubToken);
    final token = await SecureFieldCodec.decrypt(storedToken);
    if (token == null || token.isEmpty) {
      throw GithubAuthException('Token 无法解密，请重新输入');
    }
    final api = GithubApi(token: token);
    final user = await api.getUser();
    final owner = user.login;

    var name = repoName?.trim() ?? '';
    if (name.contains('/')) {
      name = name.split('/').last;
    }
    if (name.isEmpty) {
      final stored = GStorage.getSetting(SettingsKeys.githubRepo);
      name = stored.contains('/') ? stored.split('/').last : stored;
    }
    if (name.isEmpty) {
      name = _defaultRepoName;
    }

    var repoInfo = await api.getRepo(owner: owner, repo: name);
    if (repoInfo == null) {
      repoInfo = await api.createPrivateRepo(name: name);
      MiruLogger().i('GithubSync: created private repo ${repoInfo.fullName}');
    }

    _api?.dispose();
    _api = api;
    _owner = owner;
    _repo = name;
    _tempDirectory =
        Directory('${(await getApplicationSupportDirectory()).path}/githubTemp');
    await _ensureLocalTempDirectory();
    await GStorage.putSetting(SettingsKeys.githubRepo, repoInfo.fullName);
    await GStorage.putSetting(SettingsKeys.githubLogin, owner);
    await GStorage.putSetting(SettingsKeys.githubAvatarUrl, user.avatarUrl);
    await GStorage.putSetting(SettingsKeys.githubEnable, true);
    initialized = true;
    return repoInfo.fullName;
  }

  /// 退出登录：清除凭据与缓存，停用同步。本地数据不受影响。
  Future<void> logout() async {
    _api?.dispose();
    _api = null;
    _owner = '';
    _repo = '';
    initialized = false;
    await GStorage.putSetting(SettingsKeys.githubToken, '');
    await GStorage.putSetting(SettingsKeys.githubLogin, '');
    await GStorage.putSetting(SettingsKeys.githubAvatarUrl, '');
    await GStorage.putSetting(SettingsKeys.githubEnable, false);
    MiruLogger().i('GithubSync: logged out');
  }

  Future<void> ping() async {
    _requireInitialized();
    await _api!.getUser();
  }

  // ---------------------------------------------------------------------------
  // 观看历史同步（流程与 WebDav._syncHistory 一致，仅传输层不同）
  // ---------------------------------------------------------------------------

  Future<void> syncHistory() {
    return _historySyncSingleFlight.run(() async {
      try {
        await _operationQueue.run(_syncHistory);
      } catch (e) {
        MiruLogger().e('GithubSync: history sync failed', error: e);
        rethrow;
      }
    });
  }

  Future<void> _syncHistory() async {
    _requireInitialized();
    final historySync = HistorySyncService();
    final deviceId = await historySync.getDeviceId();
    final runDirectory = await _createRunDirectory();

    try {
      final downloads = await _downloadHistorySyncFiles(
        runDirectory: runDirectory,
        deviceId: deviceId,
      );
      final snapshotReadResult = await _readRemoteHistorySnapshot(
        historySync,
        downloads.snapshotFile,
      );
      final remoteSnapshot = snapshotReadResult.snapshot;

      final snapshotInitialized =
          GStorage.getSetting(SettingsKeys.historySyncSnapshotInitialized);
      final localBatch = await historySync.prepareLocalLogs(
        runDirectory: runDirectory,
        forceCheckpoint: snapshotInitialized != true ||
            snapshotReadResult.needsRepair ||
            downloads.currentDeviceLogOversized,
      );
      final mergedRemoteSnapshot = await historySync.mergeRemoteEventFiles(
        snapshot: remoteSnapshot,
        eventFiles: downloads.eventFiles.map((f) => f.localFile),
        onInvalidFile: (file, error, stackTrace) async {
          MiruLogger().w(
            'GithubSync: invalid remote history event log '
            '${downloads.eventFiles
                    .firstWhere((f) => f.localFile.path == file.path)
                    .remoteName}, skipping',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      final mergedFromFiles = await historySync.mergeEventFiles(
        snapshot: mergedRemoteSnapshot,
        eventFiles: localBatch.files,
        inMemoryEvents: await historySync.buildLocalStateEvents(),
        tolerateMalformedLines: true,
      );

      final mergedSnapshot = await historySync.reconcileAndApplySnapshot(
        mergedFromFiles,
      );

      if (localBatch.shouldCheckpoint) {
        final snapshotFile = File(
          '${runDirectory.path}${Platform.pathSeparator}snapshot.json',
        );
        await historySync.writeSnapshotFile(mergedSnapshot, snapshotFile);
        final bytes = await snapshotFile.readAsBytes();
        await _putFile(
          path: _historySnapshotPath,
          message: 'miru: history snapshot',
          bytes: bytes,
        );
        await historySync.completeCheckpoint(localBatch);
        await _deleteFile(
          path: '$_historyChangesPath/$deviceId.jsonl',
          message: 'miru: remove checkpointed device log',
        );
        await GStorage.putSetting(
          SettingsKeys.historySyncSnapshotInitialized,
          true,
        );
      } else {
        final uploadFile =
            await historySync.copyActiveLogForUpload(runDirectory);
        if (uploadFile != null) {
          final bytes = await uploadFile.readAsBytes();
          await _putFile(
            path: '$_historyChangesPath/$deviceId.jsonl',
            message: 'miru: history events',
            bytes: bytes,
          );
        }
      }

      await GStorage.putSetting(
        SettingsKeys.githubLastSyncTime,
        DateTime.now().millisecondsSinceEpoch,
      );
    } finally {
      try {
        if (await runDirectory.exists()) {
          await runDirectory.delete(recursive: true);
        }
      } catch (e) {
        MiruLogger().w('GithubSync: failed to clean sync temp directory',
            error: e);
      }
    }
  }

  Future<_HistorySyncDownloads> _downloadHistorySyncFiles({
    required Directory runDirectory,
    required String deviceId,
  }) async {
    File? snapshotFile;
    final historyEntries = await _api!.listDir(
      owner: _owner,
      repo: _repo,
      path: _historyRootPath,
    );
    if (historyEntries.any((e) => e.name == 'snapshot.json')) {
      snapshotFile = File(
        '${runDirectory.path}${Platform.pathSeparator}remote-snapshot.json',
      );
      await _writeRemoteFileTo(
        path: _historySnapshotPath,
        target: snapshotFile,
      );
    }

    final eventFiles = <_DownloadedHistoryEventFile>[];
    var currentDeviceLogOversized = false;
    final changeEntries = await _api!.listDir(
      owner: _owner,
      repo: _repo,
      path: _historyChangesPath,
    );
    var index = 0;
    for (final entry in changeEntries) {
      final name = entry.name ?? '';
      if (!name.endsWith('.jsonl') || entry.size == 0) {
        continue;
      }
      final localFile = File(
        '${runDirectory.path}${Platform.pathSeparator}'
        'remote-events-${index++}.jsonl',
      );
      await _writeRemoteFileTo(
        path: '$_historyChangesPath/$name',
        target: localFile,
      );
      if (name == '$deviceId.jsonl' &&
          await localFile.length() >
              HistorySyncService.checkpointLogThresholdBytes) {
        currentDeviceLogOversized = true;
      }
      eventFiles.add(
        _DownloadedHistoryEventFile(remoteName: name, localFile: localFile),
      );
    }

    return _HistorySyncDownloads(
      snapshotFile: snapshotFile,
      eventFiles: eventFiles,
      currentDeviceLogOversized: currentDeviceLogOversized,
    );
  }

  Future<_HistorySnapshotReadResult> _readRemoteHistorySnapshot(
    HistorySyncService historySync,
    File? snapshotFile,
  ) async {
    if (snapshotFile == null) {
      return _HistorySnapshotReadResult(
        snapshot: HistorySyncSnapshot.empty(),
        needsRepair: false,
      );
    }
    try {
      return _HistorySnapshotReadResult(
        snapshot: await historySync.readSnapshotFile(snapshotFile),
        needsRepair: false,
      );
    } catch (e, stackTrace) {
      MiruLogger().w(
        'GithubSync: invalid history snapshot, rebuilding from event logs',
        error: e,
        stackTrace: stackTrace,
      );
      return _HistorySnapshotReadResult(
        snapshot: HistorySyncSnapshot.empty(),
        needsRepair: true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 追番收藏同步（与 WebDav._syncCollectibles 一致）
  // ---------------------------------------------------------------------------

  Future<void> updateCollectibles() async {
    await _operationQueue.run(() async {
      await _updateBox('collectibles');
      if (GStorage.collectChanges.isNotEmpty) {
        await _updateBox('collectchanges');
      }
    });
  }

  Future<void> syncCollectibles() async {
    await _operationQueue.run(_syncCollectibles);
  }

  Future<void> _syncCollectibles() async {
    _requireInitialized();
    List<CollectedBangumi> remoteCollectibles = [];
    List<CollectedBangumiChange> remoteChanges = [];

    final entries = await _api!.listDir(
      owner: _owner,
      repo: _repo,
      path: _dataRoot,
    );
    final collectiblesExists = entries.any((e) => e.name == 'collectibles.tmp');
    final changesExists = entries.any((e) => e.name == 'collectchanges.tmp');
    if (!collectiblesExists && !changesExists) {
      await _updateBox('collectibles');
      if (GStorage.collectChanges.isNotEmpty) {
        await _updateBox('collectchanges');
      }
      return;
    }

    try {
      if (collectiblesExists) {
        final file = await _writeRemoteFileTo(
          path: '$_dataRoot/collectibles.tmp',
          target: File('${_tempDirectory.path}/collectibles.tmp'),
        );
        remoteCollectibles =
            await GStorage.getCollectiblesFromFile(file.path);
      }
      if (changesExists) {
        final file = await _writeRemoteFileTo(
          path: '$_dataRoot/collectchanges.tmp',
          target: File('${_tempDirectory.path}/collectchanges.tmp'),
        );
        remoteChanges = await GStorage.getCollectChangesFromFile(file.path);
      }
    } catch (e) {
      MiruLogger().e('GithubSync: parse remote collectibles failed', error: e);
      throw Exception('GithubSync: 远端收藏数据解析失败');
    }

    if (remoteChanges.isNotEmpty || remoteCollectibles.isNotEmpty) {
      await GStorage.patchCollectibles(remoteCollectibles, remoteChanges);
    }
    await _updateBox('collectibles');
    if (GStorage.collectChanges.isNotEmpty) {
      await _updateBox('collectchanges');
    }
    await GStorage.putSetting(
      SettingsKeys.githubLastSyncTime,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 上传本地 Hive 盒文件到远端（与 WebDav._updateBox 同语义）。
  Future<void> _updateBox(String boxName) async {
    _requireInitialized();
    // 先 flush 让 Hive 把内存中的追加完整落盘，缩小与用户写入之间的
    // 撕裂窗口（盒写入与本读取都在主 isolate，flush 返回后读到的
    // 是自洽的盒文件）。
    await _flushBoxBeforeUpload(boxName);
    final directory = await getApplicationSupportDirectory();
    final localFilePath = '${directory.path}/hive/$boxName.hive';
    final localFile = File(localFilePath);
    if (!await localFile.exists()) {
      MiruLogger().w('GithubSync: local box file $boxName.hive missing, skip');
      return;
    }
    final List<int> bytes;
    try {
      bytes = await localFile.readAsBytes();
    } catch (e, stackTrace) {
      // 活文件读取失败（与用户写入竞争被撕裂/被系统清理等）：
      // 跳过本轮上传而非让整个同步崩溃——远端仍是上一次的完整快照，
      // 下一轮同步会自然重试。
      MiruLogger().w(
        'GithubSync: failed to read live box file $boxName.hive, '
        'skip this round',
        error: e,
        stackTrace: stackTrace,
      );
      return;
    }
    await _putFile(
      path: '$_dataRoot/$boxName.tmp',
      message: 'miru: $boxName backup',
      bytes: bytes,
    );
  }

  /// 上传前尽力把对应 Hive 盒的内存写入 flush 到磁盘。
  Future<void> _flushBoxBeforeUpload(String boxName) async {
    try {
      if (boxName == 'collectibles') {
        await GStorage.collectibles.flush();
      } else if (boxName == 'collectchanges') {
        await GStorage.collectChanges.flush();
      }
    } catch (e) {
      // flush 失败不阻塞上传：文件里已有的内容是最后一次成功落盘的状态。
      MiruLogger().w('GithubSync: flush box $boxName failed', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // 传输原语
  // ---------------------------------------------------------------------------

  Future<File> _writeRemoteFileTo({
    required String path,
    required File target,
  }) async {
    final remote = await _api!.readFile(
      owner: _owner,
      repo: _repo,
      path: path,
    );
    if (remote == null) {
      throw GithubNotFoundException('远端文件 $path 不存在');
    }
    await target.parent.create(recursive: true);
    await target.writeAsBytes(remote.content, flush: true);
    return target;
  }

  Future<void> _putFile({
    required String path,
    required String message,
    required List<int> bytes,
  }) async {
    await _api!.putFileWithRetry(
      owner: _owner,
      repo: _repo,
      path: path,
      message: message,
      bytes: bytes,
    );
  }

  Future<void> _deleteFile({
    required String path,
    required String message,
  }) async {
    try {
      await _api!.deleteFile(
        owner: _owner,
        repo: _repo,
        path: path,
        message: message,
      );
    } catch (e) {
      // 删除失败不阻塞同步主流程（下次同步会重新覆盖）。
      MiruLogger().w('GithubSync: failed to delete $path', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // 基础设施
  // ---------------------------------------------------------------------------

  void _requireInitialized() {
    if (!initialized || _api == null) {
      throw StateError('GithubSync 未初始化，请先在设置中登录 GitHub');
    }
  }

  Future<Directory> _createRunDirectory() async {
    await _cleanupStaleRunDirectories();
    return _tempDirectory.createTemp('history-sync-run-');
  }

  Future<void> _cleanupStaleRunDirectories() async {
    await _ensureLocalTempDirectory();
    final staleBefore = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entity in _tempDirectory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('history-sync-run-')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(staleBefore)) {
          continue;
        }
        await entity.delete(recursive: true);
      } catch (e) {
        MiruLogger().w('GithubSync: failed to remove stale run dir $name',
            error: e);
      }
    }
  }

  Future<void> _ensureLocalTempDirectory() async {
    if (!await _tempDirectory.exists()) {
      await _tempDirectory.create(recursive: true);
    }
  }
}

class _HistorySyncDownloads {
  const _HistorySyncDownloads({
    required this.snapshotFile,
    required this.eventFiles,
    required this.currentDeviceLogOversized,
  });

  final File? snapshotFile;
  final List<_DownloadedHistoryEventFile> eventFiles;
  final bool currentDeviceLogOversized;
}

class _DownloadedHistoryEventFile {
  const _DownloadedHistoryEventFile({
    required this.remoteName,
    required this.localFile,
  });

  final String remoteName;
  final File localFile;
}

class _HistorySnapshotReadResult {
  const _HistorySnapshotReadResult({
    required this.snapshot,
    required this.needsRepair,
  });

  final HistorySyncSnapshot snapshot;
  final bool needsRepair;
}
