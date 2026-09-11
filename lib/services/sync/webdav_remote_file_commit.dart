typedef WebDavRemoveRemoteFile = Future<void> Function(String path);
typedef WebDavUploadRemoteFile = Future<void> Function(
  String sourceFilePath,
  String remotePath,
);
typedef WebDavRenameRemoteFile = Future<void> Function(
  String sourcePath,
  String destinationPath,
);
typedef WebDavRemoteEntryExists = Future<bool> Function(String path);

class WebDavRemoteFileCommitter {
  const WebDavRemoteFileCommitter();

  Future<void> replaceFile({
    required String sourceFilePath,
    required String temporaryPath,
    required String destinationPath,
    required WebDavRemoveRemoteFile remove,
    required WebDavUploadRemoteFile uploadFromFile,
    required WebDavRenameRemoteFile rename,
    required WebDavRemoteEntryExists exists,
  }) async {
    await _removeIfExists(
      temporaryPath,
      remove: remove,
      exists: exists,
    );
    try {
      await uploadFromFile(sourceFilePath, temporaryPath);
      await _removeIfExists(
        destinationPath,
        remove: remove,
        exists: exists,
      );
      await rename(temporaryPath, destinationPath);
    } catch (_) {
      // v1.6.7（B-🔴2）：此刻 destination 已被删、rename 又失败——
      // 绝不能直接清 temp（那会让远端文件就此丢失，触发同步层的
      // 空基底合并事故：另一台设备看到「快照缺失 + 日志存在」会把
      // 收藏整盒清空）。先尝试源文件直传 destination 兜底；仍失败
      // 才清理 temp 并抛出（此时远端确实丢了，但异常会让上层记录
      // 失败而不是静默成功）。
      try {
        await uploadFromFile(sourceFilePath, destinationPath);
        await _removeIfExists(
          temporaryPath,
          remove: remove,
          exists: exists,
        );
        return;
      } catch (_) {}
      await _removeIfExists(
        temporaryPath,
        remove: remove,
        exists: exists,
      );
      rethrow;
    }
  }

  Future<void> _removeIfExists(
    String path, {
    required WebDavRemoveRemoteFile remove,
    required WebDavRemoteEntryExists exists,
  }) async {
    try {
      await remove(path);
    } catch (_) {
      if (await exists(path)) {
        rethrow;
      }
    }
  }
}
