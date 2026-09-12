import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/utils/http_headers.dart';

/// WebView 视频源解析服务
///
/// 使用 WebView 解析视频页面，提取视频源 URL。
/// WebView 实例在服务生命周期内复用，切换集数时调用 unloadPage 释放页面资源，
/// 仅在 [dispose] 时才真正销毁 WebView。
class WebViewVideoSourceService implements IVideoSourceService {
  VideoWebviewController? _webview;
  StreamSubscription? _logSubscription;

  // 单个服务实例持有一个 WebView，因此解析任务按实例串行执行。
  // 下载并行通过多个服务实例实现。
  Future<void>? _resolveTail = Future<void>.value();
  _ResolveRequest? _activeRequest;

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    // 默认超时统一 20s（B7）：与 video_source_service 接口默认、
    // hybrid 编排层对齐；实际值由 video_controller 读
    // SettingsKeys.parseTimeout（设置页「解析超时」）后显式传入。
    // WebView 嗅探按自家文档需 5~30s，15s 会系统性砍掉慢 JS 站。
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final resolveTail = _resolveTail;
    if (resolveTail == null) {
      throw const VideoSourceCancelledException();
    }

    _activeRequest?.cancel();
    final request = _ResolveRequest();
    _activeRequest = request;

    final resolveFuture = resolveTail.then(
      (_) => _runResolve(
        request,
        episodeUrl,
        useLegacyParser: useLegacyParser,
        offset: offset,
        timeout: timeout,
      ),
    );

    _resolveTail = resolveFuture.then<void>((_) {}, onError: (_) {});
    return resolveFuture;
  }

  Future<VideoSource> _runResolve(
    _ResolveRequest request,
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
  }) async {
    request.throwIfNotCurrent(_activeRequest);

    if (_webview == null) {
      final webview = VideoWebviewControllerFactory.getController();
      try {
        // 初始化必须有硬超时（P8 余项）：headless WebView 创建挂起时
        // init() 永不完成，本实例的 _resolveTail 串行队列会被卡死，
        // 后续所有解析请求全部排队等死。参照
        // captcha_verification_service 的 10s 初始化上限：超时抛
        // TimeoutException，走下方「初始化失败不残留」分支 dispose
        // 后重抛，本次解析立即失败并降级/重试，不拖垮整条队列。
        await webview.init().timeout(const Duration(seconds: 10));
      } catch (e) {
        // 初始化失败的 WebView 绝不能残留：半初始化实例会让下一次
        // resolve 直接操作不可用的控制器（NPE / 行为异常）。
        await webview.dispose();
        rethrow;
      }
      _webview = webview;
      _logSubscription = webview.onLog.listen((log) {
        if (!_logController.isClosed) {
          _logController.add(log);
        }
      });
    }

    var didStartLoad = false;
    try {
      request.throwIfNotCurrent(_activeRequest);
      didStartLoad = true;
      // v1.6.6 修复（B1-🟡12）：loadUrl 同样要有硬超时（与 init 的
      // 10s 同款 P8 问题）——WebView 进程僵死/通道丢失时 future
      // 永不完成，串行队列卡死、dispose 悬挂、实例泄漏。
      // 超时抛 VideoSourceTimeoutException，走既有 finally 的
      // unloadPage 清理与上层降级链路。
      await _webview!.loadUrl(
        episodeUrl,
        useLegacyParser,
        offset: offset,
      ).timeout(const Duration(seconds: 10),
          onTimeout: () => throw VideoSourceTimeoutException(
              const Duration(seconds: 10)));

      request.throwIfNotCurrent(_activeRequest);

      final event = await _waitForParserEvent(request, timeout);

      request.throwIfNotCurrent(_activeRequest);

      // v1.6.9（P0-2）：嗅探回调未标注 format 且 URL 形似 HLS 时，
      // 不再直接按后缀强制 hls——先用首 1KB 内容确认 #EXTM3U magic，
      // 确认后才给 mpv 设 demuxer-lavf-format=hls；内容不是清单
      //（如 .m3u8 后缀的 MP4 / 重定向到媒体流）则保留 auto 交给
      // mpv 自探测，避免「URL 像清单但实际是媒体流」被强制按 HLS
      // 解析而直接失败。嗅探不可判定时维持 auto（mpv 自探测），
      // 不因嗅探失败损失可播性。
      var format = event.format;
      if (format == VideoSourceFormat.auto && _looksLikeHls(event.url)) {
        final sniffHeaders = <String, String>{
          ...?event.headers,
          'user-agent':
              (event.headers?['user-agent'] ?? event.headers?['User-Agent'])
                      ?.trim()
                      .isNotEmpty ==
                  true
                  ? (event.headers?['user-agent'] ??
                      event.headers?['User-Agent'])!
                  : getSessionUA(),
        };
        final isManifest = await _sniffManifestMagic(event.url, sniffHeaders);
        request.throwIfNotCurrent(_activeRequest);
        if (isManifest == true) {
          format = VideoSourceFormat.hls;
        } else if (isManifest == false) {
          MiruLogger().i(
              'WebViewResolver: url looks like m3u8 but content is not a '
              'manifest, keeping format=auto for mpv self-probe');
        }
      }

      // 网络层嗅探捕获的请求头（Referer/Cookie，阶段 0 / §1.5）：
      // 随结果带给播放层，防盗链 CDN 不再因丢 Referer 拒播。
      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: format,
        playbackHeaders: event.headers ?? const {},
      );
    } catch (e) {
      if (e is VideoSourceCancelledException) {
        rethrow;
      }
      request.throwIfNotCurrent(_activeRequest);
      rethrow;
    } finally {
      if (didStartLoad) {
        try {
          await _webview?.unloadPage();
        } catch (e) {
          // 清理失败不能覆盖原始解析异常，只记日志。
          MiruLogger().w('WebViewVideoSourceService: unloadPage failed',
              error: e);
        }
      }
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
      }
    }
  }

  /// 等待解析器事件。使用显式订阅而非 `.first.timeout`：
  /// 超时/取消路径下广播流订阅会被立即释放，避免悬挂订阅泄漏。
  Future<VideoParserEvent> _waitForParserEvent(
    _ResolveRequest request,
    Duration timeout,
  ) {
    final completer = Completer<VideoParserEvent>();
    StreamSubscription<VideoParserEvent>? subscription;
    Timer? timer;

    void settle(VideoParserEvent event) {
      if (!completer.isCompleted) {
        completer.complete(event);
      }
    }

    subscription = _webview!.onVideoURLParser.listen(settle);
    request.cancelled.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const VideoSourceCancelledException());
      }
    });
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(VideoSourceTimeoutException(timeout));
      }
    });

    return completer.future.whenComplete(() async {
      // timer 是闭包捕获的可空局部变量，无法类型提升，需条件调用。
      timer?.cancel();
      await subscription?.cancel();
    });
  }

  @override
  void cancel() {
    _activeRequest?.cancel();
  }

  @override
  Future<void> dispose() async {
    final resolveTail = _resolveTail;
    _resolveTail = null;
    cancel();
    await resolveTail;
    _activeRequest = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    if (!_logController.isClosed) {
      await _logController.close();
    }
    await _webview?.dispose();
    _webview = null;
  }
}

class _ResolveRequest {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}

/// URL 是否应按 HLS 流处理：以 .m3u8 结尾，或 .m3u8 后跟查询串/锚点。
bool _looksLikeHls(String url) {
  final path = url.split('#').first.split('?').first;
  // v1.6.6 修复（B1-🔵6）：大小写不敏感（大写 .M3U8 同为 HLS），
  // 与 hybrid 层判定对齐，避免两侧语义漂移。
  return path.toLowerCase().endsWith('.m3u8');
}

/// v1.6.9（P0-2）：首 1KB 内容嗅探是否为 HLS 清单（#EXTM3U magic）。
///
/// 用 Range 请求只拉开头若干字节：
/// - 返回 true：内容以 #EXTM3U 开头（BOM/空白后），确认是清单；
/// - 返回 false：拿到了内容但不是清单（媒体流/HTML 错误页）；
/// - 返回 null：嗅探不可判定（网络失败/超时），调用方维持 auto。
Future<bool?> _sniffManifestMagic(
  String url,
  Map<String, String> headers,
) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 3));
    // 只取首 1KB：源站不支持 Range 时读满 1KB 即主动断开，不会拉多。
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 4));
    final builder = BytesBuilder(copy: false);
    await for (final chunk
        in response.timeout(const Duration(seconds: 4))) {
      builder.add(chunk);
      if (builder.length >= 1024) break;
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) return null;
    // 跳过 UTF-8 BOM 与前导空白后找 #EXTM3U magic。
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    while (start < bytes.length &&
        (bytes[start] == 0x20 ||
            bytes[start] == 0x09 ||
            bytes[start] == 0x0A ||
            bytes[start] == 0x0D)) {
      start++;
    }
    final head = String.fromCharCodes(bytes.skip(start).take(7));
    return head.toUpperCase() == '#EXTM3U';
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}
