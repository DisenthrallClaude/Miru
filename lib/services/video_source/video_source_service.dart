import 'dart:async';

import 'package:miru/services/video_source/video_source_format.dart';

/// 视频源类型
enum VideoSourceType {
  /// 在线解析（WebView）
  online,

  /// 本地缓存
  cached,
}

/// 视频源解析结果
class VideoSource {
  /// 视频 URL (M3U8/MP4/本地路径)。秒开链路下可能是本地代理地址
  /// （`http://127.0.0.1:<port>/...`），直连兜底时用 [directUrl]。
  final String url;

  /// 原始直链（未经本地代理改写）。mpv 打开代理失败时用它直连重试。
  final String directUrl;

  /// 播放偏移量（秒）
  final int offset;

  /// 视频源类型
  final VideoSourceType type;

  /// 解析视频源时确认的媒体格式提示
  final VideoSourceFormat format;

  /// 解析层确认的源站播放请求头（v1.5.2）。
  ///
  /// 云端/本地快速解析提取直链时，可能同时确认了源站要求的
  /// referer/UA（防盗链）。这组头会合并进 mpv 的 http-header-fields，
  /// 保证「探测可达 → 播放也可达」。插件自身声明的头仍优先。
  final Map<String, String> playbackHeaders;

  const VideoSource({
    required this.url,
    required this.offset,
    required this.type,
    this.format = VideoSourceFormat.auto,
    String? directUrl,
    this.playbackHeaders = const {},
  }) : directUrl = directUrl ?? url;

  /// 是否为本地代理地址（127.0.0.1）。
  bool get isProxied => directUrl != url;

  @override
  String toString() =>
      'VideoSource(url: $url, offset: $offset, type: $type, format: $format)';
}

/// 视频源未找到异常
class VideoSourceNotFoundException implements Exception {
  final String message;
  const VideoSourceNotFoundException([this.message = 'Video source not found']);

  @override
  String toString() => 'VideoSourceNotFoundException: $message';
}

/// 视频源解析超时异常
class VideoSourceTimeoutException implements Exception {
  final Duration timeout;
  const VideoSourceTimeoutException(this.timeout);

  @override
  String toString() =>
      'VideoSourceTimeoutException: Timed out after ${timeout.inSeconds}s';
}

/// 视频源解析取消异常
class VideoSourceCancelledException implements Exception {
  const VideoSourceCancelledException();

  @override
  String toString() =>
      'VideoSourceCancelledException: Resolution was cancelled';
}

/// 解析层级失败的分级（阶段 0 / §1.3）——决定负缓存的写法：
/// - [extractFailed]：页面拿到了但提不出候选（该站静态结构解不了），
///   写 **host 级**负缓存（同站所有集都跳过该层）；
/// - [network]：传输层失败（超时/连接错误），**不写负缓存**——
///   网络抖动不应放大成整层跳过；
/// - [probeDead]：候选直链被探测判死，写 **URL 级**负缓存（仅影响本集）。
enum LevelFailureKind { extractFailed, network, probeDead }

/// 视频源解析服务接口
///
/// 抽象视频源的获取方式，支持多种实现：
/// - WebView 解析（在线）
/// - 本地缓存读取
/// - 组合策略（优先缓存，回退 WebView）
abstract class IVideoSourceService {
  /// 解析视频源 URL
  ///
  /// [episodeUrl] 集数页面 URL
  /// [useLegacyParser] 是否使用旧版解析器（iframe 监听）
  /// [offset] 播放偏移量（秒）
  /// [timeout] 解析超时时间（签名默认统一 20s，B7；实际播放路径由
  ///   video_controller 读 SettingsKeys.parseTimeout 设置后显式传入）
  ///
  /// 返回 [VideoSource] 包含解析后的视频 URL 和元数据
  ///
  /// 可能抛出：
  /// - [VideoSourceNotFoundException] 未找到视频源
  /// - [VideoSourceTimeoutException] 解析超时
  /// - [VideoSourceCancelledException] 解析被取消
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 20),
  });

  /// 取消当前正在进行的解析
  ///
  /// 调用后，正在进行的 [resolve] 会抛出 [VideoSourceCancelledException]
  void cancel();

  /// 释放资源
  Future<void> dispose();
}
