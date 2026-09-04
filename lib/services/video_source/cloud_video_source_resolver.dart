import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:hive_ce/hive.dart';
import 'package:miru/request/clients/download_http_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/core/network_exception.dart';
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
/// - **端点熔断**（B6）：连续 [circuitThreshold] 次失败（超时/网络错误/
///   非 ok 响应）的端点在 [circuitOpenDuration] 内直接跳过，窗口结束后
///   半开试探——典型场景：官方 workers.dev 端点在大陆不可达，
///   每次播放白付 4s 延迟税；
/// - 结果校验：只接受 http(s) 且带视频扩展/明显是直链的地址；
/// - 429（配额用尽）与其它非 ok 一样静默降级，但按原因分类记日志（B14），
///   云端层到底是超时/被墙/配额/提取失败不再是黑盒；
/// - 全程静默失败：所有异常只记日志，绝不向上抛。
class CloudVideoSourceResolver {
  CloudVideoSourceResolver._();

  static final CloudVideoSourceResolver instance =
      CloudVideoSourceResolver._();

  static const Duration perEndpointTimeout = Duration(milliseconds: 2500);

  /// 熔断阈值：连续失败这么多次的端点打开熔断。
  static const int circuitThreshold = 3;

  /// 熔断时长：打开后这么长时间内直接跳过该端点，到期半开试探。
  static const Duration circuitOpenDuration = Duration(minutes: 5);

  /// warmUp 健康探测限时（§1.4）。
  static const Duration warmUpTimeout = Duration(milliseconds: 1500);

  final DownloadHttpClient _client = DownloadHttpClient.instance;

  /// 匿名设备标识（懒生成，首次访问时创建并持久化）。
  String? _cachedUid;

  /// 端点缓存：设置变更后调用 [invalidateEndpoints] 失效。
  List<Uri>? _endpoints;

  /// 端点健康（持久化到 Hive `cloud_resolver_health`，§1.4）：
  /// endpoint → 连续失败数/熔断时刻。进程重启后熔断状态保留——
  /// 之前每次冷启动要重新交 3×4s 的「学费」才熔断，大陆用户尤甚。
  final Map<String, _EndpointHealth> _endpointHealth = {};

  /// 健康盒懒加载状态：null = 未加载，false = 加载失败（退化为内存态）。
  bool? _healthLoaded;

  Future<void> _ensureHealthLoaded() async {
    if (_healthLoaded != null) return;
    try {
      final box = await Hive.openBox('cloud_resolver_health');
      final data = box.get('health');
      if (data is Map) {
        data.forEach((key, value) {
          if (key is String && value is Map) {
            final failures = (value['f'] as num?)?.toInt() ?? 0;
            final openedAt = (value['o'] as num?)?.toInt();
            if (failures > 0) {
              _endpointHealth[key] = _EndpointHealth()
                ..consecutiveFailures = failures
                ..openedAt = openedAt != null && openedAt > 0
                    ? DateTime.fromMillisecondsSinceEpoch(openedAt)
                    : null;
            }
          }
        });
      }
      _healthLoaded = true;
    } catch (_) {
      _healthLoaded = false; // Hive 不可用：退化为内存态（行为=旧版）
    }
  }

  Future<void> _persistHealth() async {
    if (_healthLoaded != true) return;
    try {
      final box = await Hive.openBox('cloud_resolver_health');
      final payload = <String, dynamic>{
        for (final e in _endpointHealth.entries)
          e.key: {
            'f': e.value.consecutiveFailures,
            'o': e.value.openedAt?.millisecondsSinceEpoch ?? 0,
          },
      };
      await box.put('health', payload);
    } catch (_) {
      // 持久化失败不影响内存态熔断
    }
  }

  void invalidateEndpoints() {
    _endpoints = null;
  }

  /// 启动预热（§1.4）：对所有端点并发 GET /health（1.5s 超时），
  /// 失败直接计入熔断（大陆 workers.dev 不可达的端点在第一次播放
  /// 之前就被熔断，不再交「首次播放白付 4s」的税）。
  /// 在 main.dart 启动流程末尾 unawaited 调用。
  Future<void> warmUp() async {
    await _ensureHealthLoaded();
    // 熔断过滤（与正式解析同口径）：已熔断端点不再探测。
    final targets =
        endpoints.where((e) => !_isCircuitOpen(e)).toList(growable: false);
    if (targets.isEmpty) return;
    final results = await Future.wait(
      targets.map((endpoint) async {
        try {
          final uri = endpoint.replace(path: '/health');
          await _client.getPlain(
            uri.toString(),
            receiveTimeout: warmUpTimeout,
          ).timeout(warmUpTimeout);
          _recordEndpointSuccess(endpoint);
          return true;
        } catch (e) {
          final failureClass = _classifyFailure(e);
          // 传输层/服务器故障才计熔断（与正式解析同一口径）
          if (failureClass == 'timeout' ||
              failureClass == 'connect-error' ||
              failureClass == 'bad-certificate' ||
              failureClass.startsWith('http-5')) {
            _recordEndpointFailure(endpoint);
          }
          return false;
        }
      }),
      eagerError: false,
    );
    await _persistHealth();
    final ok = results.where((r) => r).length;
    MiruLogger().i(
        'CloudResolver: warmUp done ($ok/${targets.length} endpoints alive)');
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

  /// 请求云端解析。返回 null 表示「不可用/失败/未配置」；
  /// 调用方应降级本地解析；绝不抛异常。
  Future<VideoSource?> resolve(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    final report = await resolveWithReport(episodeUrl,
        userAgent: userAgent, referer: referer);
    return report.source;
  }

  /// 带失败分类的解析入口（阶段 0 / §1.3）：
  /// [CloudResolveReport.source] 为 null 时 [CloudResolveReport.failureClass]
  /// 携带本次「最常见」的失败分类（timeout / extract-failed / http-429 …），
  /// 供 hybrid 层做分级负缓存决策。
  Future<CloudResolveReport> resolveWithReport(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    if (episodeUrl.isEmpty) {
      return const CloudResolveReport(null, null);
    }
    await _ensureHealthLoaded();
    // 熔断过滤：连续失败的端点短窗内不再请求（省 2.5s×N 延迟税）
    final targets =
        endpoints.where((e) => !_isCircuitOpen(e)).toList(growable: false);
    if (targets.isEmpty) {
      if (endpoints.isNotEmpty) {
        MiruLogger()
            .w('CloudResolver: all endpoints circuit-open, skipping cloud');
      }
      return const CloudResolveReport(null, 'circuit-open');
    }

    final failures = <String>[];
    final result = await _race(
      targets.map((endpoint) => _resolveFromEndpoint(
            endpoint,
            episodeUrl,
            userAgent: userAgent,
            referer: referer,
            onFailure: failures.add,
          )),
    );
    if (result == null) {
      // 各端点的失败原因已在 _resolveFromEndpoint 里分类记录（B14）
      MiruLogger().w(
          'CloudResolver: all ${targets.length} endpoint(s) failed for $episodeUrl');
      // 端点全部同因时取该原因；混合原因时优先传输层（网络语义）
      var failureClass = failures.isNotEmpty ? failures.first : 'error';
      if (failures.contains('timeout') ||
          failures.contains('connect-error')) {
        failureClass = failures.contains('connect-error') &&
                !failures.contains('timeout')
            ? 'connect-error'
            : 'timeout';
      }
      return CloudResolveReport(null, failureClass);
    }
    MiruLogger().i(
        'CloudResolver: resolved via ${result.$2} in ${result.$3}ms: ${result.$1.url}');
    await _persistHealth();
    return CloudResolveReport(result.$1, null);
  }

  /// 健康检查（设置页「测试连接」用）：返回最快应答的端点，全挂返回 null。
  /// 刻意绕过熔断——用户显式点测试就该真去打；测试成功顺手解除熔断。
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
        _recordEndpointSuccess(endpoint);
        return (endpoint, DateTime.now().millisecondsSinceEpoch);
      }),
    );
    return result?.$1;
  }

  // ---------------------------------------------------------------------------
  // 端点熔断（内存态，B6）
  // ---------------------------------------------------------------------------

  /// 熔断是否处于打开状态（窗口结束则半开：允许下一次请求试探）。
  bool _isCircuitOpen(Uri endpoint) {
    final health = _endpointHealth[endpoint.toString()];
    if (health == null) return false;
    final openedAt = health.openedAt;
    if (openedAt == null) return false;
    if (DateTime.now().difference(openedAt) >= circuitOpenDuration) {
      // 熔断窗口结束：半开试探（保持失败计数在阈值上，试探失败立即重开）
      health.openedAt = null;
      return false;
    }
    return true;
  }

  void _recordEndpointSuccess(Uri endpoint) {
    _endpointHealth.remove(endpoint.toString());
    unawaited(_persistHealth());
  }

  void _recordEndpointFailure(Uri endpoint) {
    final key = endpoint.toString();
    final health =
        _endpointHealth.putIfAbsent(key, _EndpointHealth.new);
    health.consecutiveFailures++;
    if (health.consecutiveFailures >= circuitThreshold) {
      health.openedAt ??= DateTime.now();
    }
    unawaited(_persistHealth());
  }

  /// 失败分类（可观测性，B14）：超时 / 连接失败 / HTTP 状态（含 429
  /// 配额）/ 提取失败 / 响应坏——诊断「云端层为什么慢/为什么不可用」
  /// 全靠这里，别再吞成一句 all endpoints failed。
  String _classifyFailure(Object e) {
    if (e is TimeoutException) return 'timeout';
    if (e is NetworkException) {
      switch (e.type) {
        case NetworkExceptionType.connectionTimeout:
        case NetworkExceptionType.receiveTimeout:
        case NetworkExceptionType.sendTimeout:
          return 'timeout';
        case NetworkExceptionType.connectionError:
          return 'connect-error';
        case NetworkExceptionType.badResponse:
          final code = e.statusCode;
          if (code == 429) return 'http-429-quota';
          return 'http-$code';
        case NetworkExceptionType.badCertificate:
          return 'bad-certificate';
        case NetworkExceptionType.cancel:
          return 'cancelled';
        case NetworkExceptionType.parseError:
        case NetworkExceptionType.unknown:
          break;
      }
    }
    if (e is FormatException) return 'bad-json';
    final message = e.toString();
    if (message.contains('not-ok')) return 'extract-failed';
    if (message.contains('invalid url')) return 'invalid-url';
    return 'error';
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
    void Function(String failureClass)? onFailure,
  }) async {
    final started = DateTime.now();
    try {
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
        throw Exception('resolver responded not-ok');
      }
      final videoUrl = data['videoUrl'] as String? ?? '';
      if (!videoUrl.startsWith('http')) {
        throw Exception('resolver returned invalid url');
      }
      final formatName = data['format'] as String? ?? 'auto';
      // Worker 提取直链时确认的源站 referer（防盗链要求），
      // 一并带回给 mpv 播放头（v1.5.2）。
      final resolvedReferer = (data['referer'] as String?) ?? '';
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      _recordEndpointSuccess(endpoint);
      return (
        VideoSource(
          url: videoUrl,
          offset: 0,
          type: VideoSourceType.online,
          format: formatName == 'hls'
              ? VideoSourceFormat.hls
              : VideoSourceFormat.auto,
          playbackHeaders: {
            if (resolvedReferer.isNotEmpty) 'referer': resolvedReferer,
          },
        ),
        endpoint,
        elapsed,
      );
    } catch (e) {
      // 失败分类记日志（B14）+ 熔断计数（B6），异常继续向上抛给 _race 吞掉
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final failureClass = _classifyFailure(e);
      onFailure?.call(failureClass);
      MiruLogger().w('CloudResolver: endpoint ${endpoint.host} failed in '
          '${elapsed}ms ($failureClass)');
      // 熔断只计传输层/服务端故障（timeout、连接错误、证书、5xx）。
      // 站点级失败（extract-failed/bad-json/invalid-url）是「这个站云端解不了」，
      // 换个站依然可用，计熔断会让一个 WebView-only 站点连锁关闭整个云端层；
      // 429 配额超限同样不计（配额是全局的，熔断与否不影响它，还白丢加速机会）。
      const circuitBreakerClasses = {
        'timeout',
        'connect-error',
        'bad-certificate',
      };
      if (circuitBreakerClasses.contains(failureClass) ||
          failureClass.startsWith('http-5')) {
        _recordEndpointFailure(endpoint);
      }
      rethrow;
    }
  }
}

/// 端点健康状态（持久化于 Hive `cloud_resolver_health`，§1.4）。
class _EndpointHealth {
  int consecutiveFailures = 0;

  /// 熔断打开时刻；null = 未熔断（只是累计失败数）。
  DateTime? openedAt;
}

/// 云端解析结果报告（阶段 0 / §1.3）：source + 失败分类。
class CloudResolveReport {
  const CloudResolveReport(this.source, this.failureClass);

  final VideoSource? source;

  /// 全端点失败时的分类（timeout / connect-error / extract-failed /
  /// http-429-quota / circuit-open …）；成功时为 null。
  final String? failureClass;
}
