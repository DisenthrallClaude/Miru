import 'dart:async';

import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:miru/services/logging/logger.dart';

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
    Duration timeout = const Duration(seconds: 15),
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
        await webview.init();
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
      await _webview!.loadUrl(
        episodeUrl,
        useLegacyParser,
        offset: offset,
      );

      request.throwIfNotCurrent(_activeRequest);

      final event = await _waitForParserEvent(request, timeout);

      request.throwIfNotCurrent(_activeRequest);

      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: event.format,
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
