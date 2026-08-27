import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:miru/request/clients/download_http_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

/// 云端解析层客户端（Cloudflare Workers + KV，见 cloudflare-worker/）。
///
/// 秒开链路的第二层：把「播放页 → 直链」的解析搬到边缘节点并发处理，
/// 手机端只发一个轻量 GET（1~2 秒），彻底绕开 WebView 嗅探的页面加载
/// 与播放器初始化（5~30 秒）。KV 缓存命中时更是毫秒级返回。
///
/// v1.5.1 起内置官方端点（[ApiEndpoints.cloudResolverOfficialEndpoint]），
/// 零配置即用；设置里可换自建 Worker（可填多个，逗号分隔）。
///
/// 可靠性设计（任何一层失败都不影响可播放性）：
/// - 多端点竞速：同时请求，最先返回有效结果者胜出，其余自动放弃——
///   单个 Worker 故障/被墙时无感切换；
/// - 单端点限时 [perEndpointTimeout]（默认 4s），到点放弃降级本地解析；
/// - 结果校验：只接受 http(s) 且带视频扩展/明显是直链的地址；
/// - 429（配额用尽）与其它非 ok 一样静默降级，绝不影响播放；
/// - 全程静默失败：所有异常只记日志，绝不向上抛。
class CloudVideoSourceResolver {
  CloudVideoSourceResolver._();

  static final CloudVideoSourceResolver instance =
      CloudVideoSourceResolver._();

  static const Duration perEndpointTimeout = Duration(seconds: 4);

  final DownloadHttpClient _client = DownloadHttpClient.instance;

  /// 匿名设备标识（懒生成，首次访问时创建并持久化）。
  String? _cachedUid;

  /// 端点缓存：设置变更后调用 [invalidateEndpoints] 失效。
  List<Uri>? _endpoints;

  void invalidateEndpoints() {
    _endpoints = null;
  }

  /// 是否已配置云端解析（开关开 + 至少一个端点）。
  /// v1.5.1 起未自建时也返回 true（内置官方端点）。
  bool get isConfigured {
    return endpoints.isNotEmpty;
  }

  /// 匿名 uid：用于 Worker 端「每日活跃人数」统计与动态配额。
  /// 随机 16 位 hex，不含任何个人信息。
  String get uid {
    final cached = _cachedUid;
    if (cached != null && cached.isNotEmpty) return cached;
    var stored = GStorage.getSetting(SettingsKeys.anonUid);
    if (stored.isEmpty) {
      final rnd = Random.secure();
      stored = List.generate(
        16,
        (_) => '0123456789abcdef'[rnd.nextInt(16)],
      ).join();
      unawaited(GStorage.putSetting(SettingsKeys.anonUid, stored));
    }
    _cachedUid = stored;
    return stored;
  }

  List<Uri> get endpoints {
    final cached = _endpoints;
    if (cached != null) return cached;
    final enabled = GStorage.getSetting(SettingsKeys.cloudResolverEnable);
    if (!enabled) {
      return _endpoints = const [];
    }
    final raw = GStorage.getSetting(SettingsKeys.cloudResolverUrl);
    // 自定义地址优先；留空则用内置官方端点（v1.5.1 零配置可用）
    final source = raw.trim().isEmpty
        ? ApiEndpoints.cloudResolverOfficialEndpoint
        : raw;
    final parsed = <Uri>[];
    for (final part in source.split(RegExp(r'[,\s]+'))) {
      var candidate = part.trim();
      if (candidate.isEmpty) continue;
      if (!candidate.startsWith('http://') &&
          !candidate.startsWith('https://')) {
        candidate = 'https://$candidate';
      }
      // 去掉误填的末尾斜杠与 /resolve 后缀，统一拼 /resolve
      candidate = candidate.replaceAll(RegExp(r'/+$'), '');
      candidate = candidate.replaceAll(RegExp(r'/resolve$'), '');
      final uri = Uri.tryParse('$candidate/resolve');
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        parsed.add(uri);
      }
    }
    return _endpoints = parsed;
  }

  /// 请求云端解析。返回 null 表示「不可用/失败/未配置」，
  /// 调用方应降级本地解析；绝不抛异常。
  Future<VideoSource?> resolve(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    final targets = endpoints;
    if (targets.isEmpty || episodeUrl.isEmpty) return null;

    try {
      final result = await _race(
        targets.map((endpoint) => _resolveFromEndpoint(
              endpoint,
              episodeUrl,
              userAgent: userAgent,
              referer: referer,
            )),
      );
      if (result == null) return null;
      MiruLogger().i(
          'CloudResolver: resolved via ${result.$2} in ${result.$3}ms: ${result.$1.url}');
      return result.$1;
    } catch (e) {
      MiruLogger().w('CloudResolver: all endpoints failed', error: e);
      return null;
    }
  }

  /// 健康检查（设置页「测试连接」用）：返回最快应答的端点，全挂返回 null。
  Future<Uri?> healthCheck() async {
    final targets = endpoints;
    if (targets.isEmpty) return null;
    final result = await _race(
      targets.map((endpoint) async {
        final uri = endpoint.replace(path: '/health');
        await _client.getPlain(
          uri.toString(),
          receiveTimeout: const Duration(seconds: 5),
        );
        return (endpoint, DateTime.now().millisecondsSinceEpoch);
      }),
    );
    return result?.$1;
  }

  /// 并发赛跑：任一成功立即返回其结果；全部失败/为空返回 null。
  /// 单个 future 的异常被吞掉（视为该端点失败）。
  Future<T?> _race<T>(Iterable<Future<T?>> futures) {
    final list = futures.toList();
    if (list.isEmpty) return Future.value(null);
    final completer = Completer<T?>();
    var pending = list.length;
    for (final future in list) {
      unawaited(
        future.then((value) {
          if (!completer.isCompleted && value != null) {
            completer.complete(value);
          }
        }).catchError((_) => null).whenComplete(() {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }),
      );
    }
    return completer.future;
  }

  Future<(VideoSource, Uri, int)?> _resolveFromEndpoint(
    Uri endpoint,
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    final started = DateTime.now();
    final query = {
      'url': episodeUrl,
      'uid': uid,
      if (userAgent != null && userAgent.isNotEmpty) 'ua': userAgent,
      if (referer != null && referer.isNotEmpty) 'referer': referer,
    };
    final uri = endpoint.replace(queryParameters: {
      ...endpoint.queryParameters,
      ...query,
    });
    final raw = await _client.getPlain(
      uri.toString(),
      receiveTimeout: perEndpointTimeout,
    ).timeout(perEndpointTimeout);

    final data = json.decode(raw);
    if (data is! Map<String, dynamic> || data['ok'] != true) {
      throw Exception('resolver responded not-ok: $raw');
    }
    final videoUrl = data['videoUrl'] as String? ?? '';
    if (!videoUrl.startsWith('http')) {
      throw Exception('resolver returned invalid url');
    }
    final formatName = data['format'] as String? ?? 'auto';
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    return (
      VideoSource(
        url: videoUrl,
        offset: 0,
        type: VideoSourceType.online,
        format: formatName == 'hls' ? VideoSourceFormat.hls : VideoSourceFormat.auto,
      ),
      endpoint,
      elapsed,
    );
  }
}
