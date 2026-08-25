import 'dart:io';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:path_provider/path_provider.dart';
import 'package:miru/modules/history/history_sync.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/modules/collect/collect_module.dart';
import 'package:miru/modules/collect/collect_change_module.dart';
import 'package:miru/services/sync/history_sync_service.dart';
import 'package:miru/services/sync/webdav_remote_file_commit.dart';
import 'package:miru/utils/async_serial_queue.dart';
import 'package:miru/utils/async_single_flight.dart';

class WebDav {
  static const String _syncRootPath = '/miruSync';
  /// 旧上游时代的同步根目录。仅用于一次性迁移：
  /// 老用户网盘里的历史数据不能因为改名而「丢失」。
  static const String _legacySyncRootPath = '/kazumiSync';
  static const String _historyRootPath = '$_syncRootPath/history';
  static const String _historyChangesPath = '$_historyRootPath/changes';
  static const String _historySnapshotPath = '$_historyRootPath/snapshot.json';

  late String webDavURL;
  late String webDavUsername;
  late String webDavPassword;
  late Directory webDavLocalTempDirectory;
  late webdav.Client client;

  bool initialized = false;
  static const Duration _staleRunDirectoryAge = Duration(hours: 24);

  final AsyncSingleFlight<void> _historySyncSingleFlight =
      AsyncSingleFlight<void>();
  final AsyncSerialQueue _webDavOperationQueue = AsyncSerialQueue();
  final WebDavRemoteFileCommitter _remoteFileCommitter =
      const WebDavRemoteFileCommitter();

  bool get isHistorySyncing => _historySyncSingleFlight.isRunning;

  WebDav._internal();
  static final WebDav _instance = WebDav._internal();
  factory WebDav() => _instance;

  Future<void> init() async {
    var directory = await getApplicationSupportDirectory();
    webDavLocalTempDirectory = Directory('${directory.path}/webdavTemp');
    webDavURL = GStorage.getSetting(SettingsKeys.webDavURL);
    webDavUsername = GStorage.getSetting(SettingsKeys.webDavUsername);
    // 密码以 Keystore 密文落盘，这里先解密再交给客户端；
    // 解密失败说明密钥已丢失，必须让用户重新配置而不是拿密文去认证。
    final storedPassword = GStorage.getSetting(SettingsKeys.webDavPassword);
    final password = await SecureFieldCodec.decrypt(storedPassword);
    if (password == null) {
      throw Exception('WebDAV 密码无法解密（密钥可能已被系统清除），请重新保存 WebDAV 配置');
    }
    webDavPassword = password;
    if (webDavURL.isEmpty) {
      throw Exception('请先填写WebDAV URL');
    }
    client = webdav.newClient(
      webDavURL,
      user: webDavUsername,
      password: webDavPassword,
      debug: false,
    );
    client.setHeaders({'accept-charset': 'utf-8'});
    client.c.options.contentType = 'application/octet-stream';
    try {
      await client.ping();
      await _ensureRemoteDirectory(_syncRootPath);
      await _migrateLegacySyncDirectory();
      await _ensureLocalTempDirectory();
      initialized = true;
      MiruLogger().i('WebDav: webDav backup directory ready');
    } catch (e) {
      MiruLogger().e('WebDav: WebDAV ping failed', error: e);
      rethrow;
    }
  }

  /// 旧上游目录的一次性迁移：/kazumiSync → /miruSync。
  ///
  /// 仅当旧目录存在且新目录还没有历史数据时执行；
  /// 迁移失败不阻塞同步（用户仍可从零开始），只记录日志。
  Future<void> _migrateLegacySyncDirectory() async {
    try {
      if (!await _remoteEntryExists('$_legacySyncRootPath/history')) {
        return;
      }
      if (await _remoteEntryExists(_historyRootPath)) {
        // 新目录已有数据：以新目录为准，避免覆盖用户在 Miru 里的新进度。
        return;
      }
      final legacyHistory =
          '$_legacySyncRootPath/history'.replaceAll('//', '/');
      final entries = await client.readDir(legacyHistory);
      for (final entry in entries) {
        final srcPath = entry.path ?? '';
        if (srcPath.isEmpty) continue;
        final name = srcPath.split('/').where((s) => s.isNotEmpty).last;
        final target = '$_historyRootPath/$name';
        if (entry.isDir ?? false) {
          await _ensureRemoteDirectory(target);
          final subEntries = await client.readDir(srcPath);
          for (final sub in subEntries) {
            final subPath = sub.path ?? '';
            if (subPath.isEmpty) continue;
            final subName =
                subPath.split('/').where((s) => s.isNotEmpty).last;
            await client.copy(subPath, '$target/$subName', true);
          }
        } else {
          await client.copy(srcPath, target, true);
        }
      }
      MiruLogger().i(
          'WebDav: migrated legacy sync data from $_legacySyncRootPath to $_syncRootPath');
    } catch (e) {
      // 迁移是尽力而为：网盘不支持 copy 等情况不应挡住正常同步。
      MiruLogger().w('WebDav: legacy sync directory migration skipped',
          error: e);
    }
  }

  Future<T> _runWebDavExclusive<T>(Future<T> Function() action) {
    return _webDavOperationQueue.run(action);
  }

  Future<void> _updateBox(String boxName) async {
    var directory = await getApplicationSupportDirectory();
    final localFilePath = '${directory.path}/hive/$boxName.hive';
    final tempFilePath = '${webDavLocalTempDirectory.path}/$boxName.tmp';
    final webDavPath = '$_syncRootPath/$boxName.tmp';
    await File(localFilePath).copy(tempFilePath);
    await _publishRemoteFile(
      sourceFilePath: tempFilePath,
      destinationPath: webDavPath,
      temporaryPath: '$webDavPath.cache',
    );
    try {
      await File(tempFilePath).delete();
    } catch (_) {}
  }

  Future<void> syncHistory() {
    return _historySyncSingleFlight.run(() async {
      try {
        await _runWebDavExclusive(_syncHistory);
      } catch (e) {
        MiruLogger().e('WebDav: history sync failed', error: e);
        rethrow;
      }
    });
  }

  Future<void> updateCollectibles() async {
    try {
      await _runWebDavExclusive(() async {
        await _updateBox('collectibles');
        if (GStorage.collectChanges.isNotEmpty) {
          await _updateBox('collectchanges');
        }
      });
    } catch (e) {
      MiruLogger().e('WebDav: update collectibles failed', error: e);
      rethrow;
    }
  }

  Future<void> _downloadBox(String boxName) async {
    String fileName = '$boxName.tmp';
    final existingFile = File('${webDavLocalTempDirectory.path}/$fileName');
    if (await existingFile.exists()) {
      await existingFile.delete();
    }
    await client.read2File('$_syncRootPath/$fileName', existingFile.path);
  }

  Future<void> syncCollectibles() async {
    return _runWebDavExclusive(_syncCollectibles);
  }

  Future<void> _syncCollectibles() async {
    List<CollectedBangumi> remoteCollectibles = [];
    List<CollectedBangumiChange> remoteChanges = [];

    final files = await client.readDir(_syncRootPath);
    final collectiblesExists =
        files.any((file) => file.name == 'collectibles.tmp');
    final changesExists =
        files.any((file) => file.name == 'collectchanges.tmp');
    if (!collectiblesExists && !changesExists) {
      await _updateBox('collectibles');
      if (GStorage.collectChanges.isNotEmpty) {
        await _updateBox('collectchanges');
      }
      return;
    }

    List<Future<void>> downloadFutures = [];
    if (collectiblesExists) {
      downloadFutures.add(_downloadBox('collectibles').catchError((e) {
        MiruLogger().e('WebDav: download collectibles failed', error: e);
        throw Exception('WebDav: download collectibles failed');
      }));
    }
    if (changesExists) {
      downloadFutures.add(_downloadBox('collectchanges').catchError((e) {
        MiruLogger().e('WebDav: download collectchanges failed', error: e);
        throw Exception('WebDav: download collectchanges failed');
      }));
    }
    if (downloadFutures.isNotEmpty) {
      await Future.wait(downloadFutures);
    }
    try {
      if (collectiblesExists) {
        remoteCollectibles = await GStorage.getCollectiblesFromFile(
            '${webDavLocalTempDirectory.path}/collectibles.tmp');
      }
      if (changesExists) {
        remoteChanges = await GStorage.getCollectChangesFromFile(
            '${webDavLocalTempDirectory.path}/collectchanges.tmp');
      }
    } catch (e) {
      MiruLogger().e('WebDav: get collectibles failed', error: e);
      throw Exception('WebDav: get collectibles from file failed');
    }
    if (remoteChanges.isNotEmpty || remoteCollectibles.isNotEmpty) {
      await GStorage.patchCollectibles(remoteCollectibles, remoteChanges);
    }
    await _updateBox('collectibles');
    if (GStorage.collectChanges.isNotEmpty) {
      await _updateBox('collectchanges');
    }
  }

  Future<void> _syncHistory() async {
    await _ensureHistoryStorage();
    final historySync = HistorySyncService();
    final deviceId = await historySync.getDeviceId();
    final runDirectory = await _createHistorySyncRunDirectory();

    try {
      final downloads = await _downloadHistorySyncFiles(
        runDirectory: runDirectory,
        deviceId: deviceId,
      );
      final snapshotReadResult = await _readRemoteHistorySnapshot(
        historySync,
        downloads.snapshotFile,
      );
      var remoteSnapshot = snapshotReadResult.snapshot;
      var importedLegacyHistory = false;

      if (_isEmptyHistorySnapshot(remoteSnapshot) &&
          downloads.eventFiles.isEmpty) {
        importedLegacyHistory = await _tryImportLegacyHistory(runDirectory);
        if (importedLegacyHistory) {
          remoteSnapshot = await historySync.buildSnapshotFromLocal();
        }
      }

      final snapshotInitialized =
          GStorage.getSetting(SettingsKeys.historySyncSnapshotInitialized);
      final localBatch = await historySync.prepareLocalLogs(
        runDirectory: runDirectory,
        forceCheckpoint: snapshotInitialized != true ||
            snapshotReadResult.needsRepair ||
            downloads.currentDeviceLogOversized ||
            importedLegacyHistory,
      );
      final mergedRemoteSnapshot = await _mergeRemoteHistoryEventFiles(
        historySync: historySync,
        snapshot: remoteSnapshot,
        eventFiles: downloads.eventFiles,
      );
      // Locally-owned logs tolerate malformed lines: a crash mid-append must
      // not permanently block sync, and the Hive box still holds the state a
      // damaged line described. Remote logs above stay fail-closed so an
      // invalid file is quarantined as a whole.
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
        await _publishHistorySnapshot(
          snapshotFile: snapshotFile,
          deviceId: deviceId,
        );
        await historySync.completeCheckpoint(localBatch);
        await _removeDeviceHistoryChanges(deviceId);
        await GStorage.putSetting(
          SettingsKeys.historySyncSnapshotInitialized,
          true,
        );
      } else {
        final uploadFile =
            await historySync.copyActiveLogForUpload(runDirectory);
        if (uploadFile != null) {
          await _publishDeviceHistoryChanges(
            sourceFile: uploadFile,
            deviceId: deviceId,
          );
        }
      }
    } finally {
      try {
        if (await runDirectory.exists()) {
          await runDirectory.delete(recursive: true);
        }
      } catch (e) {
        MiruLogger().w(
          'WebDav: failed to clean history sync temp directory',
          error: e,
        );
      }
    }
  }

  bool _isEmptyHistorySnapshot(HistorySyncSnapshot snapshot) {
    return snapshot.histories.isEmpty &&
        snapshot.itemVersions.isEmpty &&
        snapshot.progressVersions.isEmpty &&
        snapshot.deletedVersions.isEmpty &&
        snapshot.clearVersion == null;
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
        'WebDav: invalid history snapshot, rebuilding from event logs',
        error: e,
        stackTrace: stackTrace,
      );
      return _HistorySnapshotReadResult(
        snapshot: HistorySyncSnapshot.empty(),
        needsRepair: true,
      );
    }
  }

  Future<HistorySyncSnapshot> _mergeRemoteHistoryEventFiles({
    required HistorySyncService historySync,
    required HistorySyncSnapshot snapshot,
    required List<_DownloadedHistoryEventFile> eventFiles,
  }) async {
    final eventFilesByPath = {
      for (final eventFile in eventFiles)
        eventFile.localFile.path: eventFile.remoteName,
    };
    return historySync.mergeRemoteEventFiles(
      snapshot: snapshot,
      eventFiles: eventFiles.map((eventFile) => eventFile.localFile),
      onInvalidFile: (file, error, stackTrace) async {
        final remoteName = eventFilesByPath[file.path]!;
        MiruLogger().w(
          'WebDav: invalid remote history event log $remoteName, skipping',
          error: error,
          stackTrace: stackTrace,
        );
        await _quarantineRemoteHistoryEventFile(remoteName);
      },
    );
  }

  Future<Directory> _createHistorySyncRunDirectory() async {
    await _cleanupStaleHistorySyncRunDirectories();
    return webDavLocalTempDirectory.createTemp('history-sync-run-');
  }

  Future<void> _cleanupStaleHistorySyncRunDirectories() async {
    await _ensureLocalTempDirectory();
    final staleBefore = DateTime.now().subtract(_staleRunDirectoryAge);
    await for (final entity
        in webDavLocalTempDirectory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('history-sync-run-')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        // A recent directory may belong to another running Miru process.
        if (stat.modified.isAfter(staleBefore)) {
          continue;
        }
        await entity.delete(recursive: true);
      } catch (e) {
        MiruLogger().w(
          'WebDav: failed to remove stale history sync directory $name',
          error: e,
        );
      }
    }
  }

  Future<_HistorySyncDownloads> _downloadHistorySyncFiles({
    required Directory runDirectory,
    required String deviceId,
  }) async {
    File? snapshotFile;
    final historyEntries = await client.readDir(_historyRootPath);
    final hasSnapshot = historyEntries.any(
      (file) => file.name == 'snapshot.json',
    );
    if (hasSnapshot) {
      snapshotFile = File(
        '${runDirectory.path}${Platform.pathSeparator}remote-snapshot.json',
      );
      await client.read2File(_historySnapshotPath, snapshotFile.path);
    }

    final eventFiles = <_DownloadedHistoryEventFile>[];
    var currentDeviceLogOversized = false;
    final changeEntries = await client.readDir(_historyChangesPath);
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
      await client.read2File(
        '$_historyChangesPath/$name',
        localFile.path,
      );
      if (name == '$deviceId.jsonl' &&
          await localFile.length() >
              HistorySyncService.checkpointLogThresholdBytes) {
        currentDeviceLogOversized = true;
      }
      eventFiles.add(
        _DownloadedHistoryEventFile(
          remoteName: name,
          localFile: localFile,
        ),
      );
    }

    return _HistorySyncDownloads(
      snapshotFile: snapshotFile,
      eventFiles: eventFiles,
      currentDeviceLogOversized: currentDeviceLogOversized,
    );
  }

  Future<void> _publishHistorySnapshot({
    required File snapshotFile,
    required String deviceId,
  }) {
    return _publishRemoteFile(
      sourceFilePath: snapshotFile.path,
      destinationPath: _historySnapshotPath,
      temporaryPath: '$_historySnapshotPath.$deviceId.cache',
    );
  }

  Future<void> _publishDeviceHistoryChanges({
    required File sourceFile,
    required String deviceId,
  }) {
    final destinationPath = '$_historyChangesPath/$deviceId.jsonl';
    return _publishRemoteFile(
      sourceFilePath: sourceFile.path,
      destinationPath: destinationPath,
      temporaryPath: '$destinationPath.cache',
    );
  }

  Future<void> _publishRemoteFile({
    required String sourceFilePath,
    required String destinationPath,
    required String temporaryPath,
  }) async {
    await _remoteFileCommitter.replaceFile(
      sourceFilePath: sourceFilePath,
      temporaryPath: temporaryPath,
      destinationPath: destinationPath,
      remove: (path) => client.remove(path),
      uploadFromFile: (sourceFilePath, remotePath) =>
          client.writeFromFile(sourceFilePath, remotePath),
      rename: (sourcePath, targetPath) =>
          client.rename(sourcePath, targetPath, true),
      exists: _remoteEntryExists,
    );
  }

  Future<void> _removeDeviceHistoryChanges(String deviceId) async {
    final remotePath = '$_historyChangesPath/$deviceId.jsonl';
    try {
      await client.remove(remotePath);
    } catch (e) {
      MiruLogger().w(
        'WebDav: failed to remove checkpointed device history log',
        error: e,
      );
    }
  }

  Future<void> _quarantineRemoteHistoryEventFile(String remoteName) {
    final sourcePath = '$_historyChangesPath/$remoteName';
    final quarantinePath = '$sourcePath.invalid.'
        '${DateTime.now().millisecondsSinceEpoch}';
    return _quarantineRemoteFile(
      sourcePath: sourcePath,
      quarantinePath: quarantinePath,
      description: 'history event log $remoteName',
    );
  }

  Future<void> _ensureHistoryStorage() async {
    await _ensureLocalTempDirectory();
    await _ensureRemoteDirectory(_syncRootPath);
    await _ensureRemoteDirectory(_historyRootPath);
    await _ensureRemoteDirectory(_historyChangesPath);
  }

  Future<void> _ensureLocalTempDirectory() async {
    if (!await webDavLocalTempDirectory.exists()) {
      await webDavLocalTempDirectory.create(recursive: true);
    }
  }

  Future<void> _ensureRemoteDirectory(String path) async {
    try {
      await client.mkdir(path);
    } catch (e) {
      if (!await _remoteEntryExists(path)) {
        rethrow;
      }
    }
  }

  Future<bool> _remoteEntryExists(String path) async {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    final parent = index <= 0 ? '/' : normalized.substring(0, index);
    final name = normalized.substring(index + 1);
    try {
      final files = await client.readDir(parent);
      return files.any((file) => file.name == name);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryImportLegacyHistory(Directory runDirectory) async {
    final syncEntries = await client.readDir(_syncRootPath);
    if (!syncEntries.any((file) => file.name == 'histories.tmp')) {
      return false;
    }

    const fileName = 'histories.tmp';
    final existingFile = File(
      '${runDirectory.path}${Platform.pathSeparator}$fileName',
    );
    try {
      await client.read2File('$_syncRootPath/$fileName', existingFile.path);
    } catch (e, stackTrace) {
      MiruLogger().w(
        'WebDav: failed to download legacy history backup, skipping import',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }

    try {
      await GStorage.patchHistory(existingFile.path);
      MiruLogger().i('WebDav: imported legacy history backup');
      return true;
    } catch (e, stackTrace) {
      MiruLogger().w(
        'WebDav: invalid legacy history backup, skipping import',
        error: e,
        stackTrace: stackTrace,
      );
      await _quarantineLegacyHistoryBackup();
      return false;
    }
  }

  Future<void> _quarantineLegacyHistoryBackup() async {
    final quarantinePath = '$_syncRootPath/histories.invalid.'
        '${DateTime.now().millisecondsSinceEpoch}.tmp';
    await _quarantineRemoteFile(
      sourcePath: '$_syncRootPath/histories.tmp',
      quarantinePath: quarantinePath,
      description: 'legacy history backup',
    );
  }

  Future<void> _quarantineRemoteFile({
    required String sourcePath,
    required String quarantinePath,
    required String description,
  }) async {
    try {
      await client.rename(
        sourcePath,
        quarantinePath,
        false,
      );
      MiruLogger().w(
        'WebDav: moved invalid $description to $quarantinePath',
      );
    } catch (e, stackTrace) {
      MiruLogger().w(
        'WebDav: failed to quarantine invalid $description',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> ping() async {
    try {
      await client.ping();
    } catch (e) {
      MiruLogger().e('WebDav: WebDav ping failed', error: e);
      rethrow;
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
