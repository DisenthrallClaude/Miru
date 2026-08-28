import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/bangumi_image_url_rewriter.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/network/system_proxy_service.dart';
import 'package:miru/services/storage/storage.dart';

class ProxyAwareImageCacheManager extends CacheManager with ImageCacheManager {
  static final ProxyAwareImageCacheManager instance =
      ProxyAwareImageCacheManager._();

  ProxyAwareImageCacheManager._()
      : super(
          Config(
            DefaultCacheManager.key,
            fileService: _ProxyAwareImageFileService(),
          ),
        );
}

class _ProxyAwareImageFileService extends FileService {
  /// 连接阶段（TCP+TLS）超时：黑洞主机必须秒级失败，
  /// 否则封面无限转圈（F1 主病灶——此前裸 HttpClient 零超时）。
  static const _connectTimeout = Duration(seconds: 5);

  /// 单次取图总预算（建连 + 响应头）：慢代理/被墙的 wsrv.nl 到点让位。
  static const _fetchDeadline = Duration(seconds: 15);

  /// 响应体相邻数据块的空闲超时：防慢滴流源站把下载挂到天荒地老。
  static const _bodyIdleTimeout = Duration(seconds: 15);

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final rewritten = BangumiImageUrlRewriter.rewrite(
      url,
      enabled: _bangumiMirrorEnabled(),
    );
    if (rewritten == url) {
      // 未重写（镜像关闭/非 bangumi 图床）：单次直取。
      return _fetch(url, headers);
    }
    // 经重写（wsrv.nl / bgmimg）取图失败（超时/非 200）时，
    // 用原始 URL 直连重试一次（F1）：失败的重写尝试从未返回响应，
    // 不会被缓存管理器落盘，无需显式 evict；重试成功后以调用方
    // 传入的原始 URL 为键入缓存（缓存键与重写无关，天然成立）。
    // 这样 wsrv.nl 单点故障不再导致封面永远加载不出来。
    try {
      return await _fetch(rewritten, headers);
    } catch (e) {
      MiruLogger().w(
        'Image: mirrored fetch failed, retrying origin once',
        error: e,
      );
      return _fetch(url, headers);
    }
  }

  Future<FileServiceResponse> _fetch(
    String url,
    Map<String, String>? headers,
  ) async {
    final client = _createHttpClient();
    try {
      final deadline = DateTime.now().add(_fetchDeadline);
      Duration remaining() => deadline.difference(DateTime.now());

      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(remaining(), onTimeout: () {
        throw TimeoutException('image connect timeout', _fetchDeadline);
      });
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(
            remaining(),
            onTimeout: () {
              throw TimeoutException('image response timeout', _fetchDeadline);
            },
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // 非 2xx（wsrv.nl 上游失败会回 5xx/4xx 错误页）一律按失败处理，
        // 触发原始 URL 回退，绝不让错误页字节混进图片缓存。
        throw HttpException(
          'image fetch HTTP ${response.statusCode}',
          uri: Uri.tryParse(url),
        );
      }
      return _ProxyAwareImageFileServiceResponse(response, client);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  bool _bangumiMirrorEnabled() {
    return GStorage.getSetting(SettingsKeys.enableBangumiProxy);
  }

  HttpClient _createHttpClient() {
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    final proxy = _currentProxy();
    if (proxy == null) {
      if (Platform.isWindows) {
        // Unlike the manual proxy path, certificate checks stay strict here.
        client.findProxy = SystemProxyService.findProxy;
      }
      return client;
    }

    client.findProxy = (_) => 'PROXY ${proxy.$1}:${proxy.$2}';
    // 证书校验只在「用户手动代理激活」分支关闭（F11 契约）：部分用户
    // 代理（MITM 型）必需；其余场景（直连 / Windows 系统代理跟随）
    // 一律保持严格校验。
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }

  (String, int)? _currentProxy() {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) return null;

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed == null) {
      MiruLogger().w('Proxy: 图片缓存代理地址格式错误或为空');
    }
    return parsed;
  }
}

class _ProxyAwareImageFileServiceResponse implements FileServiceResponse {
  _ProxyAwareImageFileServiceResponse(this._response, this._client);

  final HttpClientResponse _response;
  final HttpClient _client;
  final DateTime _receivedTime = DateTime.now();

  @override
  Stream<List<int>> get content async* {
    try {
      await for (final chunk in _response.timeout(
        _ProxyAwareImageFileService._bodyIdleTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'image body read timeout',
              _ProxyAwareImageFileService._bodyIdleTimeout,
            ),
          );
          sink.close();
        },
      )) {
        yield chunk;
      }
    } finally {
      _client.close(force: true);
    }
  }

  @override
  int? get contentLength =>
      _response.contentLength >= 0 ? _response.contentLength : null;

  @override
  String? get eTag => _response.headers.value(HttpHeaders.etagHeader);

  @override
  String get fileExtension {
    return switch (_response.headers.contentType?.mimeType.toLowerCase()) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'image/bmp' => '.bmp',
      'image/x-icon' || 'image/vnd.microsoft.icon' => '.ico',
      'image/avif' => '.avif',
      'image/svg+xml' => '.svg',
      _ => '',
    };
  }

  @override
  int get statusCode => _response.statusCode;

  @override
  DateTime get validTill {
    var ageDuration = const Duration(days: 7);
    final controlHeader =
        _response.headers.value(HttpHeaders.cacheControlHeader);
    if (controlHeader == null) {
      return _receivedTime.add(ageDuration);
    }

    // F14：no-store / no-cache / max-age=0 都必须「不缓存」——
    // 此前 max-age=0 会因 `> 0` 判断回落默认 7 天，no-store 干脆不识别。
    var preventCaching = false;
    Duration? maxAge;
    for (final setting in controlHeader.split(',')) {
      final sanitizedSetting = setting.trim().toLowerCase();
      if (sanitizedSetting == 'no-cache' ||
          sanitizedSetting == 'no-store') {
        preventCaching = true;
        continue;
      }
      if (sanitizedSetting.startsWith('max-age=')) {
        final validSeconds =
            int.tryParse(sanitizedSetting.split('=').last) ?? 0;
        maxAge = validSeconds > 0 ? Duration(seconds: validSeconds) : Duration.zero;
      }
    }
    if (preventCaching) {
      return _receivedTime;
    }
    if (maxAge != null) {
      ageDuration = maxAge;
    }

    return _receivedTime.add(ageDuration);
  }
}
