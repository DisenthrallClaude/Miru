import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:miru/modules/download/download_module.dart';
import 'package:miru/request/clients/download_http_client.dart';
import 'package:miru/request/core/network_exception.dart';
import 'package:miru/utils/m3u8_parser.dart';
import 'package:miru/utils/m3u8_ad_filter.dart';
import 'package:miru/utils/format.dart' as fmt;
import 'package:miru/utils/file_system.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/platform/secure_bookmark_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:path/path.dart' as path;

class _NotM3u8Exception implements Exception {
  final String message;
  _NotM3u8Exception(this.message);
  @override
  String toString() => message;
}

class _InsufficientStorageException implements Exception {
  final int availableBytes;
  final int requiredBytes;
  _InsufficientStorageException(this.availableBytes, this.requiredBytes);
  @override
  String toString() => '存储空间不足';
}

class DownloadTask {
  final String recordKey;
  final int episodeNumber;
  CancelToken cancelToken;
  bool isPaused;

  DownloadTask({
    required this.recordKey,
    required this.episodeNumber,
    CancelToken? cancelToken,
    this.isPaused = false,
  }) : cancelToken = cancelToken ?? CancelToken();
}

typedef ProgressCallback = void Function(
    String recordKey, int episodeNumber, DownloadEpisode episode, double speed);

final _m3u8SegmentFileNamePattern = RegExp(r'^seg_\d+\.ts$');

Future<int> calculateM3u8VideoBytes(String episodeDir) async {
  final dir = Directory(episodeDir);
  if (!await dir.exists()) return 0;

  var totalBytes = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(entity.uri.pathSegments.last)
        : entity.path.split(Platform.pathSeparator).last;
    if (!_m3u8SegmentFileNamePattern.hasMatch(name)) continue;

    try {
      totalBytes += await entity.length();
    } on FileSystemException {
      // Ignore transient filesystem failures while reporting display size.
    }
  }
  return totalBytes;
}

class DownloadRequest {
  final String recordKey;
  final int bangumiId;
  final String pluginName;
  final int episodeNumber;
  final String m3u8Url;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final DownloadEpisode episode;

  const DownloadRequest({
    required this.recordKey,
    required this.bangumiId,
    required this.pluginName,
    required this.episodeNumber,
    required this.m3u8Url,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episode,
  });
}

abstract class IDownloadManager {
  ProgressCallback? onProgress;

  bool isDownloading(String recordKey, int episodeNumber);
  Future<void> enqueue(DownloadRequest request);
  Future<void> enqueuePriority(DownloadRequest request);
  void pause(String recordKey, int episodeNumber);
  Future<void> resume(DownloadRequest request);
  void cancel(String recordKey, int episodeNumber);
  String? getLocalVideoPath(DownloadEpisode? episode);
  Future<void> deleteEpisodeFiles(
      int bangumiId, String pluginName, int episodeNumber,
      {DownloadEpisode? episode});
  Future<void> deleteRecordFiles(int bangumiId, String pluginName,
      {DownloadRecord? record});
  double getSpeed(String recordKey, int episodeNumber);
}

class _SpeedTracker {
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();
  double currentSpeed = 0.0; // bytes/sec

  void update(int totalBytes) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTime).inMilliseconds;
    if (elapsed > 500) {
      final bytesDownloaded = totalBytes - _lastBytes;
      currentSpeed = bytesDownloaded / (elapsed / 1000);
      _lastBytes = totalBytes;
      _lastTime = now;
    }
  }

  void reset() {
    _lastBytes = 0;
    _lastTime = DateTime.now();
    currentSpeed = 0.0;
  }
}

class DownloadManager implements IDownloadManager {
  DownloadManager() {
    _loadSettings();
  }

  final DownloadHttpClient _http = DownloadHttpClient.instance;

  final Map<String, DownloadTask> _activeTasks = {};
  final List<DownloadRequest> _queue = [];
  final Map<String, _SpeedTracker> _speedTrackers = {};
  int maxParallelEpisodes = 2;
  int maxParallelSegments = 3;
  int _runningCount = 0;

  @override
  ProgressCallback? onProgress;

  static const _minRequiredSpace = 100 * 1024 * 1024; // 100MB minimum
  static const _storageChannel = MethodChannel('io.github.disenthrallclaude.miru/storage');

  void _loadSettings() {
    maxParallelEpisodes =
        GStorage.getSetting(SettingsKeys.downloadParallelEpisodes);
    maxParallelSegments =
        GStorage.getSetting(SettingsKeys.downloadParallelSegments);
  }

  /// Returns available bytes, or -1 if unable to determine
  Future<int> _getAvailableStorage(String path) async {
    try {
      final result = await _storageChannel.invokeMethod<int>(
        'getAvailableStorage',
        {'path': path},
      );
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } catch (e) {
      MiruLogger().w('DownloadManager: failed to get storage info', error: e);
      return -1;
    }
  }

  Future<void> _checkStorageSpace(String downloadDir,
      {int requiredBytes = 0}) async {
    final available = await _getAvailableStorage(downloadDir);
    if (available == -1) return; // Skip check if unable to determine

    final required = requiredBytes > 0 ? requiredBytes : _minRequiredSpace;
    if (available < required) {
      throw _InsufficientStorageException(available, required);
    }
  }

  String _getStorageErrorMessage(FileSystemException e) {
    // POSIX error code 28 = ENOSPC (No space left on device)
    if (e.osError?.errorCode == 28) {
      return '存储空间不足，请清理后重试';
    }
    // POSIX error code 13 = EACCES (Permission denied)
    if (e.osError?.errorCode == 13) {
      return '存储权限被拒绝';
    }
    // POSIX error code 30 = EROFS (Read-only file system)
    if (e.osError?.errorCode == 30) {
      return '存储为只读，无法写入';
    }
    return '存储错误: ${e.message}';
  }

  @override
  double getSpeed(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    return _speedTrackers[key]?.currentSpeed ?? 0.0;
  }

  String _taskKey(String recordKey, int episodeNumber) =>
      '${recordKey}_$episodeNumber';

  @override
  bool isDownloading(String recordKey, int episodeNumber) =>
      _activeTasks.containsKey(_taskKey(recordKey, episodeNumber));

  Future<String> get _downloadBaseDir async {
    if (supportsCustomDownloadDirectory) {
      final customDir =
          GStorage.getSetting(SettingsKeys.downloadDirectory).trim();
      if (customDir.isNotEmpty) {
        // On macOS this re-establishes sandbox access after a restart;
        // elsewhere it returns the path unchanged.
        final usable = await SecureBookmarkService.restore(customDir);
        if (usable != null) return usable;
        MiruLogger().w(
            'DownloadManager: custom download directory unavailable, falling back to default');
      }
    }
    return getDefaultDownloadDirectory();
  }

  String _getEpisodeDir(String downloadBase, int bangumiId, String pluginName,
      int episodeNumber) {
    return path.join(
        downloadBase, '${bangumiId}_$pluginName', '$episodeNumber');
  }

  /// Resolves the episode directory (kept from a previous attempt if any),
  /// verifies it is writable, and persists it on the episode.
  Future<String> _prepareEpisodeDir(
    DownloadEpisode episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode.downloadDirectory.trim();
    final episodeDir = storedDir.isNotEmpty
        ? storedDir
        : _getEpisodeDir(
            await _downloadBaseDir, bangumiId, pluginName, episodeNumber);
    await ensureDirectoryWritable(episodeDir);
    episode.downloadDirectory = episodeDir;
    await _checkStorageSpace(episodeDir);
    return episodeDir;
  }

  /// Directory to remove for an episode: the recorded one, or the default
  /// location for episodes that never started downloading.
  Future<String> _episodeDirForDeletion(
    DownloadEpisode? episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode?.downloadDirectory.trim() ?? '';
    if (storedDir.isNotEmpty) return storedDir;
    return _getEpisodeDir(await getDefaultDownloadDirectory(), bangumiId,
        pluginName, episodeNumber);
  }

  @override
  Future<void> enqueue(DownloadRequest request) async {
    // 并发参数热生效：每次入队时重读设置（与解析池的 resize 热生效
    // 对齐），设置页「修改后对新开始的下载生效」的说明自此为真。
    _loadSettings();
    final key = _taskKey(request.recordKey, request.episodeNumber);
    final existing = _activeTasks[key];
    if (existing != null) {
      if (!existing.isPaused && !existing.cancelToken.isCancelled) {
        // 真在跑：幂等去重。
        return;
      }
      // v1.6.6 修复：暂停后立刻「继续」会撞上旧任务收尾窗口（分片重试
      // 退避最长 9s，任务要等在途 await 收尾后才从 _activeTasks 摘除），
      // 此前 enqueue 静默 no-op，集数永久卡在 downloading 直到重启。
      // 与 enqueuePriority 同语义：取消收尾中的旧任务并替换。
      existing.cancelToken.cancel('superseded by re-enqueue');
      _activeTasks.remove(key);
      _queue.removeWhere(
        (r) =>
            r.recordKey == request.recordKey &&
            r.episodeNumber == request.episodeNumber,
      );
    }

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );

    if (_runningCount < maxParallelEpisodes) {
      _runningCount++;
      _activeTasks[key] = task;
      _runEpisodeDownload(
        task: task,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    } else {
      request.episode.status = DownloadStatus.pending;
      _queue.add(request);
      _activeTasks[key] = task;
      // v1.6.6 修复：满载降级 pending 也要通知——仓库/UI/通知栏
      // 与内存对象三处口径一致（此前静默，UI 一直显示 downloading）。
      _notifyProgress(
          request.recordKey, request.episodeNumber, request.episode);
    }
  }

  @override
  Future<void> enqueuePriority(DownloadRequest request) async {
    _loadSettings();
    final key = _taskKey(request.recordKey, request.episodeNumber);

    _queue.removeWhere(
      (r) =>
          r.recordKey == request.recordKey &&
          r.episodeNumber == request.episodeNumber,
    );

    // 同键任务若仍在跑，先取消再插队：两个执行流并发写同一集的
    // 分片会互相覆盖（此前仅靠 UI 不对 downloading 状态暴露按钮兜底）。
    final running = _activeTasks.remove(key);
    if (running != null) {
      running.cancelToken.cancel('superseded by priority re-enqueue');
    }

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );

    // Start immediately, bypassing the parallel limit (priority download)
    _runningCount++;
    _activeTasks[key] = task;
    _runEpisodeDownload(
      task: task,
      bangumiId: request.bangumiId,
      pluginName: request.pluginName,
      m3u8Url: request.m3u8Url,
      httpHeaders: request.httpHeaders,
      adBlockerEnabled: request.adBlockerEnabled,
      episode: request.episode,
    );
  }

  @override
  void pause(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      task.isPaused = true;
      task.cancelToken.cancel('paused');
    }
  }

  @override
  Future<void> resume(DownloadRequest request) async {
    _loadSettings();
    final key = _taskKey(request.recordKey, request.episodeNumber);
    // v1.6.6 修复：先取消旧任务再重建——此前只 remove 不取消，
    // 旧下载循环会继续跑并与新循环并发写同一集的分片。
    _activeTasks.remove(key)?.cancelToken.cancel('superseded by resume');

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );
    _activeTasks[key] = task;

    if (_runningCount < maxParallelEpisodes) {
      _runningCount++;
      _runEpisodeDownload(
        task: task,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    } else {
      _queue.add(request);
    }
  }

  @override
  void cancel(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      task.cancelToken.cancel('cancelled');
      _activeTasks.remove(key);
      _queue.removeWhere(
        (r) => r.recordKey == recordKey && r.episodeNumber == episodeNumber,
      );
    }
  }

  void _processQueue() {
    // 批次启动前重读并发设置：队列里积压的任务按最新配置起跑。
    _loadSettings();
    while (_runningCount < maxParallelEpisodes && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      final key = _taskKey(request.recordKey, request.episodeNumber);
      final existingTask = _activeTasks[key];
      if (existingTask == null ||
          existingTask.isPaused ||
          existingTask.cancelToken.isCancelled) {
        _activeTasks.remove(key);
        continue;
      }

      _runningCount++;
      _runEpisodeDownload(
        task: existingTask,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    }
  }

  Future<void> _runEpisodeDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String m3u8Url,
    required Map<String, String> httpHeaders,
    required bool adBlockerEnabled,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    try {
      final episodeDir = await _prepareEpisodeDir(
          episode, bangumiId, pluginName, task.episodeNumber);

      episode.status = DownloadStatus.downloading;
      episode.networkM3u8Url = m3u8Url;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      String m3u8Content;
      try {
        m3u8Content = await _fetchM3u8(m3u8Url, httpHeaders, task.cancelToken);
      } on _NotM3u8Exception {
        MiruLogger().i(
          'DownloadManager: URL is not M3U8, falling back to direct file download '
          'for episode ${task.episodeNumber}',
        );
        await _runDirectFileDownload(
          task: task,
          bangumiId: bangumiId,
          pluginName: pluginName,
          videoUrl: m3u8Url,
          httpHeaders: httpHeaders,
          episode: episode,
        );
        return;
      }

      final type = M3u8Parser.detectType(m3u8Content);
      String mediaM3u8Content = m3u8Content;
      String mediaM3u8Url = m3u8Url;

      if (type == M3u8Type.master) {
        final master = M3u8Parser.parseMasterPlaylist(m3u8Content, m3u8Url);
        // v1.6.6 修复：master 无有效变体（STREAM-INF 后缺 URI 行、或
        // 媒体清单被误判为 master）时 bestVariant 抛不可读的
        // StateError——判空后把原清单当媒体清单回落解析。
        final bestVariant = master.bestVariantOrDefault;
        if (bestVariant != null) {
          mediaM3u8Url = bestVariant.uri;
          mediaM3u8Content =
              await _fetchM3u8(mediaM3u8Url, httpHeaders, task.cancelToken);
        }
      }

      final playlist =
          M3u8Parser.parseMediaPlaylist(mediaM3u8Content, mediaM3u8Url);

      // 展开嵌套 m3u8 片段（部分源将实际内容嵌套在 m3u8 引用中）
      final resolvedSegments = await M3u8Parser.resolveNestedSegments(
        playlist.segments,
        (url) => _fetchM3u8(url, httpHeaders, task.cancelToken),
      );
      final resolvedPlaylist = M3u8MediaPlaylist(
        segments: resolvedSegments,
        targetDuration: playlist.targetDuration,
        isVod: playlist.isVod,
      );

      if (!resolvedPlaylist.isVod) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '不支持下载直播流 (无有效分片)';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      if (resolvedPlaylist.segments.isEmpty) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = 'M3U8 中未找到可下载的分片';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      List<M3u8Segment> segments = resolvedPlaylist.segments;
      if (adBlockerEnabled) {
        segments = M3u8AdFilter.filterAds(segments);
      }

      // v1.6.6 修复：清单指纹校验。resume 此前「按文件名信任磁盘分片」：
      // 换线路/源站重切片/广告过滤开关变化都会让分片索引整体错位，
      // 新旧两套分片按同名文件错位拼接产出损坏视频（旧分片数≥新数时
      // 甚至「秒完成」产出旧内容）。指纹不一致（含旧记录的空指纹）
      // 时丢弃整个集目录重建，代价是一次重下，正确性优先。
      final fingerprint =
          'm3u8|$mediaM3u8Url|ad:$adBlockerEnabled|n:${segments.length}'
          '|f:${segments.first.uri}|l:${segments.last.uri}';
      if (episode.playlistFingerprint != fingerprint) {
        MiruLogger().w(
            'DownloadManager: playlist fingerprint changed for episode ${task.episodeNumber}, rebuilding episode directory');
        final staleDir = Directory(episodeDir);
        if (await staleDir.exists()) {
          await staleDir.delete(recursive: true);
        }
        await ensureDirectoryWritable(episodeDir);
        episode.downloadedSegments = 0;
        episode.progressPercent = 0.0;
        episode.totalBytes = 0;
      }
      episode.playlistFingerprint = fingerprint;

      final keys = M3u8Parser.extractUniqueKeys(
        M3u8MediaPlaylist(
          segments: segments,
          targetDuration: resolvedPlaylist.targetDuration,
          isVod: true,
        ),
      );
      final keyUriToLocal = <String, String>{};
      for (int i = 0; i < keys.length; i++) {
        final keyFile = 'key_$i.key';
        final keyPath = path.join(episodeDir, keyFile);
        await _downloadFile(
            keys[i].uri, keyPath, httpHeaders, task.cancelToken);
        keyUriToLocal[keys[i].uri] = keyFile;
      }

      episode.totalSegments = segments.length;
      episode.downloadedSegments = 0;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      final episodeDirObj = Directory(episodeDir);
      if (await episodeDirObj.exists()) {
        await for (final entity in episodeDirObj.list()) {
          if (entity.path.endsWith('.tmp')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      final existingSegments = <int>{};
      var existingBytes = 0;
      for (int i = 0; i < segments.length; i++) {
        final segFile = File(
            path.join(episodeDir, 'seg_${i.toString().padLeft(5, '0')}.ts'));
        if (await segFile.exists()) {
          final segmentBytes = await segFile.length();
          if (segmentBytes <= 0) continue;
          existingSegments.add(i);
          episode.downloadedSegments++;
          existingBytes += segmentBytes;
        }
      }
      episode.totalBytes = existingBytes;
      episode.progressPercent = episode.totalSegments > 0
          ? episode.downloadedSegments / episode.totalSegments
          : 0.0;
      // v1.6.6：downloadedBytes 单独记录已落盘字节；m3u8 完整大小
      // 完成前不可知，下载中 totalBytes 为按进度估算的完整大小
      // （完成后回写实际值），供下载页「剩余时间」计算。
      episode.downloadedBytes = existingBytes;
      episode.totalBytes = _estimatedTotalBytes(episode);
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      final pendingIndices = <int>[];
      for (int i = 0; i < segments.length; i++) {
        if (!existingSegments.contains(i)) {
          pendingIndices.add(i);
        }
      }

      var sessionBytes = 0;
      final completer = Completer<void>();
      int completedCount = 0;
      int failedCount = 0;
      final semaphore = _Semaphore(maxParallelSegments);

      _speedTrackers[key] = _SpeedTracker();

      if (pendingIndices.isEmpty) {
      } else {
        for (final idx in pendingIndices) {
          if (task.isPaused || task.cancelToken.isCancelled) break;

          await semaphore.acquire();
          if (task.isPaused || task.cancelToken.isCancelled) {
            semaphore.release();
            break;
          }

          _downloadSegmentWithRetry(
            segments[idx].uri,
            path.join(episodeDir, 'seg_${idx.toString().padLeft(5, '0')}.ts'),
            httpHeaders,
            task.cancelToken,
          ).then((bytes) {
            sessionBytes += bytes;
            episode.downloadedSegments++;
            episode.progressPercent =
                episode.downloadedSegments / episode.totalSegments;
            episode.downloadedBytes = existingBytes + sessionBytes;
            episode.totalBytes = _estimatedTotalBytes(episode);
            _speedTrackers[key]?.update(sessionBytes);
            _notifyProgress(task.recordKey, task.episodeNumber, episode);
            completedCount++;
            semaphore.release();
            if (completedCount + failedCount == pendingIndices.length) {
              completer.complete();
            }
          }).catchError((e) {
            failedCount++;
            semaphore.release();
            if (completedCount + failedCount == pendingIndices.length) {
              completer.complete();
            }
          });
        }

        if (!task.isPaused &&
            !task.cancelToken.isCancelled &&
            pendingIndices.isNotEmpty) {
          await completer.future;
        }
      }

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      if (failedCount > 0) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '$failedCount 个分片下载失败';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      final targetDuration = adBlockerEnabled
          ? M3u8AdFilter.calculateTargetDuration(segments)
          : resolvedPlaylist.targetDuration;
      final localM3u8 = M3u8Parser.buildLocalM3u8(
        segments,
        targetDuration: targetDuration,
        keyUriToLocal: keyUriToLocal,
      );
      final m3u8Path = path.join(episodeDir, 'playlist.m3u8');
      await File(m3u8Path).writeAsString(localM3u8);
      final finalVideoBytes = await calculateM3u8VideoBytes(episodeDir);

      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = m3u8Path;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes =
          finalVideoBytes > 0 ? finalVideoBytes : existingBytes + sessionBytes;
      episode.downloadedBytes = episode.totalBytes;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      MiruLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed. '
        '${segments.length} segments, ${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
    } catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = e.toString();
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger().e('DownloadManager: episode download failed', error: e);
    } finally {
      _onTaskComplete(key, task);
    }
  }

  Future<void> _runDirectFileDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String videoUrl,
    required Map<String, String> httpHeaders,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    try {
      final episodeDir = await _prepareEpisodeDir(
          episode, bangumiId, pluginName, task.episodeNumber);

      final filePath = path.join(episodeDir, 'video.mp4');
      final tmpPath = '$filePath.tmp';

      int existingBytes = 0;
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) {
        existingBytes = await tmpFile.length();
      }

      // v1.6.6 修复：直链同样做来源指纹校验——同集号换线路/直链变化后
      // 重下时，旧 tmp 的字节属于另一个文件，续传拼接必然损坏；
      // 指纹不一致（含旧记录的空指纹）时作废旧 tmp 从 0 重下。
      final directFingerprint = 'direct|$videoUrl';
      if (episode.playlistFingerprint != directFingerprint) {
        episode.playlistFingerprint = directFingerprint;
        if (existingBytes > 0) {
          try {
            await tmpFile.delete();
          } catch (_) {}
          existingBytes = 0;
        }
      }

      episode.totalSegments = 1;
      episode.downloadedSegments = 0;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      final requestHeaders = Map<String, String>.from(httpHeaders);
      bool useRange = existingBytes > 0;
      if (useRange) {
        requestHeaders['Range'] = 'bytes=$existingBytes-';
      }

      Response<ResponseBody> response;
      try {
        response = await _http.getStream(
          videoUrl,
          headers: requestHeaders,
          receiveTimeout: const Duration(minutes: 30),
          cancelToken: task.cancelToken,
        );
      } on NetworkException catch (e) {
        if (e.statusCode == 416 && useRange) {
          MiruLogger().w(
            'DownloadManager: 416 Range Not Satisfiable, deleting tmp file and retrying',
          );
          await tmpFile.delete();
          existingBytes = 0;
          requestHeaders.remove('Range');
          response = await _http.getStream(
            videoUrl,
            headers: requestHeaders,
            receiveTimeout: const Duration(minutes: 30),
            cancelToken: task.cancelToken,
          );
        } else {
          rethrow;
        }
      }

      final contentRange = response.headers.value('content-range');
      // v1.6.6 修复：直链续传校验 206（代理层 B12 同款）。服务器忽略
      // Range 回 200 全量时，旧 tmp 前缀作废从 0 重写——否则全量体被
      // append 到半截文件后必然损坏；回 206 但 Content-Range 起始不
      // 匹配 existingBytes（字节错位）同样作废续传。
      final isPartial = response.statusCode == HttpStatus.partialContent;
      var resumeValid = false;
      if (useRange && isPartial) {
        final rangeStart = _contentRangeStart(contentRange);
        resumeValid = rangeStart != null && rangeStart == existingBytes;
      }
      if (useRange && !resumeValid) {
        MiruLogger().w(
          'DownloadManager: server rejected Range resume (status ${response.statusCode}), restarting direct download from scratch',
        );
        existingBytes = 0;
        useRange = false;
      }
      final contentLength = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      int totalSize;
      if (isPartial && contentRange != null) {
        final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
        totalSize = totalMatch != null ? int.parse(totalMatch.group(1)!) : 0;
      } else {
        // 200 全量：总长即响应体长度，不与旧字节双计。
        totalSize = contentLength;
      }

      final raf = await tmpFile.open(
          mode: existingBytes > 0 ? FileMode.append : FileMode.write);
      int received = existingBytes;

      _speedTrackers[key] = _SpeedTracker();

      try {
        await for (final chunk in response.data!.stream) {
          if (task.isPaused || task.cancelToken.isCancelled) break;
          await raf.writeFrom(chunk);
          received += chunk.length;
          // v1.6.6：downloadedBytes 记录已落盘字节，totalBytes 在直链
          // 场景为已知完整大小（Content-Length/Content-Range），供下载
          // 页「剩余时间」计算；未知时退化为已落盘字节数。
          episode.downloadedBytes = received;
          episode.totalBytes = totalSize > 0 ? totalSize : received;
          episode.progressPercent = totalSize > 0 ? received / totalSize : 0;
          // Update speed tracker
          _speedTrackers[key]?.update(received);
          _notifyProgress(task.recordKey, task.episodeNumber, episode);
        }
      } finally {
        await raf.close();
      }

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      await File(tmpPath).rename(filePath);

      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = filePath;
      episode.downloadedSegments = 1;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes = await File(filePath).length();
      episode.downloadedBytes = episode.totalBytes;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      MiruLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed (direct download). '
        '${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
    } catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = e.toString();
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      MiruLogger()
          .e('DownloadManager: direct file download failed', error: e);
    }
  }

  void _onTaskComplete(String key, DownloadTask task) {
    // 只清理自己注册的任务：插队被取消的旧任务完成时，不能把同键的
    // 新任务从活跃表/速度表里误删。
    if (identical(_activeTasks[key], task)) {
      _activeTasks.remove(key);
      _speedTrackers.remove(key);
    }
    _runningCount--;
    _processQueue();
  }

  void _notifyProgress(
      String recordKey, int episodeNumber, DownloadEpisode episode) {
    final key = _taskKey(recordKey, episodeNumber);
    final speed = _speedTrackers[key]?.currentSpeed ?? 0.0;
    onProgress?.call(recordKey, episodeNumber, episode, speed);
  }

  /// 解析 Content-Range 的起始字节（"bytes N-M/T" 里的 N），
  /// 续传前校验上游确实从请求的偏移开始（与代理层 B12 同款）。
  int? _contentRangeStart(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-').firstMatch(contentRange.trim());
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// m3u8 下载中的完整大小估算：已落盘字节 / 进度。进度为 0 或
  /// 已完成时退化为已落盘字节数，保证 totalBytes ≥ downloadedBytes，
  /// 「剩余时间」不会算出负数。
  int _estimatedTotalBytes(DownloadEpisode episode) {
    final downloaded = episode.downloadedBytes;
    if (downloaded <= 0) return 0;
    final progress = episode.progressPercent;
    if (progress > 0.0 && progress < 1.0) {
      return (downloaded / progress).round();
    }
    return downloaded;
  }

  Future<String> _fetchM3u8(
      String url, Map<String, String> headers, CancelToken cancelToken) async {
    final fetchToken = CancelToken();

    if (cancelToken.isCancelled) {
      throw NetworkException(
        type: NetworkExceptionType.cancel,
        message: '请求已被取消，请重新请求',
      );
    }

    try {
      final content = await _http.getPlain(
        url,
        headers: headers,
        receiveTimeout: const Duration(seconds: 15),
        cancelToken: fetchToken,
        onReceiveProgress: (received, total) {
          if (cancelToken.isCancelled) {
            fetchToken.cancel('task cancelled');
            return;
          }
          if (received > 2 * 1024 * 1024) {
            fetchToken.cancel('too large');
          }
        },
      );

      final trimmed = content.trimLeft();
      if (!trimmed.startsWith('#EXTM3U')) {
        throw _NotM3u8Exception('URL 不是 M3U8 播放列表');
      }

      return content;
    } on NetworkException catch (e) {
      if (cancelToken.isCancelled) rethrow;
      if (e.type == NetworkExceptionType.cancel) {
        throw _NotM3u8Exception('响应过大，非 M3U8 播放列表');
      }
      rethrow;
    }
  }

  Future<void> _downloadFile(String url, String savePath,
      Map<String, String> headers, CancelToken cancelToken) async {
    await _http.download(
      url,
      savePath,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<int> _downloadSegmentWithRetry(
    String url,
    String savePath,
    Map<String, String> headers,
    CancelToken cancelToken, {
    int maxRetries = 3,
  }) async {
    final tmpPath = '$savePath.tmp';
    int retryCount = 0;
    while (true) {
      try {
        await _http.download(
          url,
          tmpPath,
          headers: headers,
          cancelToken: cancelToken,
        );
        await File(tmpPath).rename(savePath);
        return await File(savePath).length();
      } catch (e) {
        try {
          final tmpFile = File(tmpPath);
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        if (cancelToken.isCancelled) rethrow;
        retryCount++;
        if (retryCount >= maxRetries) rethrow;
        final delay = Duration(seconds: [1, 3, 9][retryCount - 1]);
        await Future.delayed(delay);
      }
    }
  }

  @override
  Future<void> deleteEpisodeFiles(
      int bangumiId, String pluginName, int episodeNumber,
      {DownloadEpisode? episode}) async {
    final dir = Directory(await _episodeDirForDeletion(
        episode, bangumiId, pluginName, episodeNumber));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteRecordFiles(int bangumiId, String pluginName,
      {DownloadRecord? record}) async {
    if (record == null) {
      final dir = Directory(path.join(
          await getDefaultDownloadDirectory(), '${bangumiId}_$pluginName'));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    }

    // Episodes may live under different base directories, so delete each
    // episode directory individually.
    final parentDirs = <String>{};
    for (final entry in record.episodes.entries) {
      final episodeDir = await _episodeDirForDeletion(
          entry.value, bangumiId, pluginName, entry.key);
      final dir = Directory(episodeDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      parentDirs.add(path.dirname(episodeDir));
    }

    for (final parentDir in parentDirs) {
      try {
        await Directory(parentDir).delete();
      } on FileSystemException {
        // Parent is missing or still holds other files; leave it.
      }
    }
  }

  @override
  String? getLocalVideoPath(DownloadEpisode? episode) {
    if (episode == null) return null;
    if (episode.status != DownloadStatus.completed) return null;
    if (episode.localM3u8Path.isEmpty) return null;
    final file = File(episode.localM3u8Path);
    if (!file.existsSync()) return null;
    return episode.localM3u8Path;
  }
}

class _Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final _waitQueue = <Completer<void>>[];

  _Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeAt(0);
      completer.complete();
    } else {
      _currentCount--;
    }
  }
}
