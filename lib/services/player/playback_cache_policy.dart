import 'dart:async';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/metered_network_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';

/// Owns the demuxer cache size of the player returned by [currentPlayer].
///
/// [PlayerConfiguration] seeds the size so a failed write degrades to the right
/// value instead of the media_kit default; [apply] is authoritative.
class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required this.isLocalPlayback,
    required this.currentPlayer,
  });

  /// v1.7.0（P1-10）：分级缓冲。旧实现计量网络/低内存共用 2MB——
  /// 1080p 下只够几秒，即使 cache-secs=120 也被字节上限卡住，移动
  /// 数据用户频繁卡顿却没省下多少流量（流量由观看时长决定）。
  /// 现在计量网络 32MB 前向 + 8MB 回看；用户手动开启的低内存模式
  /// 16MB（回看同前向，保守）。回看与前向分开配置。
  static const int _meteredBufferSize = 32 * 1024 * 1024;
  static const int _meteredBackBufferSize = 8 * 1024 * 1024;
  static const int _lowMemoryBufferSize = 16 * 1024 * 1024;
  static const int _defaultBufferSize = 1500 * 1024 * 1024;

  final bool Function() isLocalPlayback;
  final Player? Function() currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  bool _watching = false;

  bool get _userEnabled =>
      GStorage.getSetting<bool>(SettingsKeys.lowMemoryMode);

  /// Temporary override; local playback is exempt because it costs no data.
  bool get networkForced =>
      !_userEnabled && !isLocalPlayback() && MeteredNetworkService.isMetered;

  int get bufferSize {
    if (_userEnabled) return _lowMemoryBufferSize;
    if (networkForced) return _meteredBufferSize;
    return _defaultBufferSize;
  }

  /// v1.7.0（P1-10）：回看缓冲独立配置——demuxer-max-back-bytes。
  int get backBufferSize {
    if (_userEnabled) return _lowMemoryBufferSize;
    if (networkForced) return _meteredBackBufferSize;
    return _defaultBufferSize;
  }

  void startWatching() {
    if (_watching) {
      return;
    }
    _watching = true;
    MeteredNetworkService.listenable.addListener(_onNetworkChanged);
  }

  void stopWatching() {
    if (!_watching) {
      return;
    }
    _watching = false;
    MeteredNetworkService.listenable.removeListener(_onNetworkChanged);
  }

  /// Waits for initialization so the seed cannot land after this write. That
  /// wait stays outside the queue, where an unresolved one would stall every
  /// later write.
  Future<void> apply() async {
    final player = currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(currentPlayer(), player)) {
          return;
        }
        final size = bufferSize.toString();
        await pp.setProperty('demuxer-max-bytes', size);
        // v1.7.0（P1-10）：回看缓冲独立下发（计量网络 8MB）。
        await pp.setProperty('demuxer-max-back-bytes', backBufferSize.toString());
      });
    } catch (e) {
      MiruLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _onNetworkChanged() {
    unawaited(apply());
  }
}
