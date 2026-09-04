import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/shared_http_client.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

/// 提取策略标识（[FastVideoSourceResolver] 候选的来源分层）。
enum FastResolveStrategy {
  /// player_aaaa 变量直接给出的直链。
  direct,

  /// player_aaaa.from 指向第三方解析器（xxjx/jsonjx 等），
  /// 经 `/static/player/{from}.js` 定位解析接口后二跳取得直链。
  parserHop,

  /// 正文/内联 JS 中的直链正则（Artplayer 等自定义播放器）。
  inline,

  /// iframe 播放器页二跳提取。
  iframe,
}

/// 单个快解候选：解析漏斗按顺序对其探测（[_probe] 的
/// [needsPositiveConfirm] 语义见 hybrid 层），第一个通过者胜出。
class FastCandidate {
  const FastCandidate({
    required this.url,
    required this.referer,
    required this.strategy,
    required this.needsPositiveConfirm,
    required this.format,
  });

  final String url;

  /// 源站（或解析器）要求的 referer；空串表示沿用播放页。
  final String referer;

  final FastResolveStrategy strategy;

  /// 无扩展名、无强媒体信号的候选：探测阶段 unknown 视同 dead，
  /// 必须拿到正向确认（2xx + 媒体形态）才能进缓存。
  final bool needsPositiveConfirm;

  final VideoSourceFormat format;

  VideoSource toVideoSource() => VideoSource(
        url: url,
        offset: 0,
        type: VideoSourceType.online,
        format: format,
        playbackHeaders: {
          if (referer.isNotEmpty) 'referer': referer,
        },
      );
}

/// 快解层的结报告（阶段 0 / §1.3）：候选 + 失败分级。
/// [candidates] 非空时 [failure] 为 null；空候选时 [failure] 说明原因
/// （network 不写负缓存、extractFailed 写 host 级）。
class FastResolveReport {
  const FastResolveReport({required this.candidates, this.failure});

  final List<FastCandidate> candidates;
  final LevelFailureKind? failure;
}

/// 本地快速静态解析器（v1.5.2 引入，阶段 0 重写为多候选模型）。
///
/// 用一次轻量 HTTP GET 拉播放页 HTML，在手机本地提取直链：
/// 0.2~0.8 秒（Worker 要 1.5~3.5 秒，WebView 嗅探 5~30 秒），
/// 且出口 IP 与 mpv 播放完全一致——不存在「云端拿到的直链被源站
/// 防盗链绑定 IP 拒掉」的问题。
///
/// 提取策略（对齐 MacCMS V10 / 苹果CMS 系国漫站的通用结构）：
/// 1. **player_aaaa 变量**（括号配平提取——嵌套 `vod_data` 对象不再
///    截断），按官方 encrypt 字段解码；`from` 命中第三方解析器名单
///    （xxjx/jsonjx 等）或 url 形态不像直链时，走 **1.1(d) 解析器接口
///    二跳**：`/static/player/{from}.js` → MacPlayer.Parse → 解析接口
///    `?url=<token>` → JSON/HTML 提取直链（深度上限 2）；
/// 2. **正文/内联 JS 直链正则**（m3u8/mp4 等，排除广告/预滚动域）；
/// 3. **iframe 二跳**（限一层），对子页面重复 1/2。
///
/// 输出为 **候选列表**（[resolveCandidates]，最多 4 个、去重、按
/// direct > parserHop > inline > iframe 排序），由 hybrid 层逐个探测
/// 取第一个通过者；旧单结果入口 [resolve] 保留为 firstOrNull 包装。
///
/// host 级成功策略记忆（Hive `fast_resolver_hints`）：下次同 host 的
/// 候选排序优先跑上次成功的策略，省去无谓的解析器二跳等待。
///
/// 任何一步失败都静默返回空/ null（调用方降级云端解析），
/// 绝不抛异常、绝不阻塞主链路。
class FastVideoSourceResolver {
  FastVideoSourceResolver._();

  static final FastVideoSourceResolver instance = FastVideoSourceResolver._();

  /// 单次页面拉取的限时（响应头阶段）。播放页 HTML 通常 <256KB，
  /// 慢源 5 秒足够；超时即放弃降级云端（云端从 CF 边缘访问可能更快）。
  static const Duration pageTimeout = Duration(seconds: 5);

  /// 响应体读取总限时：慢滴流源站不得在 body 阶段挂死整条漏斗。
  static const Duration bodyTimeout = Duration(seconds: 8);

  /// 解析器 JS（/static/player/{from}.js）拉取限时。
  static const Duration parserScriptTimeout = Duration(seconds: 8);

  /// 解析器接口二跳的限时。
  static const Duration parserHopTimeout = Duration(seconds: 8);

  /// MacCMS 第三方解析器 `from` 名单（1.1(b)）：命中者 player_aaaa.url
  /// 是「喂给解析器的 token/中转地址」，不是直链——直接返回会被探测
  /// 放行（unknown），最终 mpv 打开 HTML 报 Failed to open。
  static const List<String> thirdPartyParserHints = [
    'xxjx',
    'jsonjx',
    'parse',
    'jx',
    'iqiyi',
    'qq',
    'qiyi',
    'youku',
    'mgtv',
    'bilibili',
    'sohu',
    'pptv',
    'letv',
    '1905',
    'm1905',
    'xigua',
    'ixigua',
    'wasu',
    'le',
  ];

  /// 广告/统计域黑名单（与 WebView 嗅探、Worker 保持一致）。
  static const List<String> _adHostHints = [
    'googleads',
    'googlesyndication',
    'adtrafficquality',
    'doubleclick',
    'prestrain.html',
    'prestrain%2Ehtml',
  ];

  /// 内联直链路径去噪（1.1(f)）：命中的 URL 大概率是预滚动广告/
  /// loading 占位/示例片段，不是正片。
  static final RegExp _adPathRe = RegExp(
      r'(preroll|prestrain|/ad[\s._/-]|/ads?[\s._/-]|tips|loading|demo|sample)',
      caseSensitive: false);

  /// 常见视频直链扩展。
  static final RegExp _videoExtRe = RegExp(
      r'\.(m3u8|mp4|flv|ts|mkv|mov|webm)(?=$|[?#])',
      caseSensitive: false);

  static final RegExp _urlRe = RegExp(r'''https?:\\?/\\?\/[^\s"'<>`]+''');

  static const String _defaultUA =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36';

  /// host → 上次成功策略（Hive，懒开盒；开盒失败退化为无记忆，绝不抛）。
  Box? _hintsBox;

  Future<Box?> _hints() async {
    final existing = _hintsBox;
    if (existing != null && !existing.isOpen) {
      _hintsBox = null;
    } else if (existing != null) {
      return existing;
    }
    try {
      return _hintsBox = await Hive.openBox('fast_resolver_hints');
    } catch (e) {
      MiruLogger().d('FastResolver: hints box unavailable', error: e);
      return null;
    }
  }

  Future<String?> _hintStrategyFor(String pageUrl) async {
    final host = Uri.tryParse(pageUrl)?.host;
    if (host == null || host.isEmpty) return null;
    try {
      final box = await _hints();
      final v = box?.get(host);
      if (v is Map && v['s'] is String) return v['s'] as String;
    } catch (_) {}
    return null;
  }

  Future<void> _recordHostHint(String pageUrl, FastResolveStrategy strategy) async {
    final host = Uri.tryParse(pageUrl)?.host;
    if (host == null || host.isEmpty) return;
    try {
      final box = await _hints();
      if (box == null) return;
      final existing = box.get(host);
      final prevHits = existing is Map ? ((existing['h'] as num?)?.toInt() ?? 0) : 0;
      // 策略未变且计数未到节流点：跳过写盘，避免每次解析都触盘。
      final sameStrategy = existing is Map && existing['s'] == strategy.name;
      if (sameStrategy && prevHits > 0 && prevHits % 5 != 0) return;
      await box.put(host, {
        's': strategy.name,
        'h': (prevHits + 1).clamp(0, 99),
        't': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 公开入口
  // ---------------------------------------------------------------------------

  /// 解析播放页，返回候选报告（≤4 个候选、去重、按优先级排序 +
  /// 失败分级）。失败/无候选返回空候选 + 失败原因（不抛异常）。
  Future<FastResolveReport> resolveCandidates(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    if (episodeUrl.isEmpty) {
      return const FastResolveReport(
          candidates: [], failure: LevelFailureKind.extractFailed);
    }
    final started = DateTime.now();
    try {
      final candidates = await _extractCandidates(
        episodeUrl,
        userAgent ?? _defaultUA,
        referer ?? episodeUrl,
        0,
      );
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      MiruLogger().i('FastResolver: ${candidates.length} candidate(s) in '
          '${elapsed}ms for ${_hostOf(episodeUrl)}');
      if (candidates.isEmpty) {
        // 页面拉到了但提不出任何候选：该站静态结构解不了（非网络问题）
        return const FastResolveReport(
            candidates: [], failure: LevelFailureKind.extractFailed);
      }
      return FastResolveReport(candidates: candidates);
    } catch (e) {
      // 传输层失败（超时/连接错误/HTTP >= 400）：不写负缓存的分级
      MiruLogger().d('FastResolver: failed for $episodeUrl', error: e);
      return const FastResolveReport(
          candidates: [], failure: LevelFailureKind.network);
    }
  }

  /// 旧单结果入口（兼容既有调用方）：取首个候选。
  Future<VideoSource?> resolve(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    final report = await resolveCandidates(episodeUrl,
        userAgent: userAgent, referer: referer);
    final candidates = report.candidates;
    if (candidates.isEmpty) return null;
    final first = candidates.first;
    MiruLogger().i(
        'FastResolver: resolved via ${first.strategy.name}: '
        '${first.url.substring(0, first.url.length.clamp(0, 90))}');
    return first.toVideoSource();
  }

  /// 测试注入/进程收尾用：仅重置提示盒缓存，不关闭共享 HttpClient
  /// （连接池是进程级的，见 SharedHttpClient）。
  void resetHintsCacheForTest() {
    _hintsBox = null;
  }

  // ---------------------------------------------------------------------------
  // 候选收集主流程
  // ---------------------------------------------------------------------------

  Future<List<FastCandidate>> _extractCandidates(
      String pageUrl, String ua, String referer, int depth) async {
    final html = await _fetchText(pageUrl, ua, referer);
    if (html.isEmpty) return const [];

    final candidates = <FastCandidate>[];

    // ---- 策略 1：player_aaaa（括号配平 + encrypt 解码 + from 分流）----
    final playerVar = _extractPlayerVarFull(html);
    if (playerVar != null) {
      final (rawUrl, varReferer, from) = playerVar;
      final isParserSource = _isThirdPartyParser(from, rawUrl);
      final resolved = _absolutize(rawUrl, pageUrl);
      final likely = _isLikelyMediaUrl(resolved ?? rawUrl);

      if (isParserSource || !resolved!.startsWith('http')) {
        // 1.1(d) 解析器接口二跳：token/中转地址不是直链，从
        // /static/player/{from}.js 定位解析接口后二次提取。
        final hopped = await _resolveViaThirdPartyParser(
          pageUrl,
          from,
          rawUrl,
          ua,
          depth,
        );
        for (final url in hopped) {
          candidates.add(FastCandidate(
            url: url,
            referer: varReferer.isNotEmpty ? varReferer : referer,
            strategy: FastResolveStrategy.parserHop,
            needsPositiveConfirm: !_isLikelyMediaUrl(url),
            format: _formatOf(url),
          ));
        }
      } else {
        candidates.add(FastCandidate(
          url: resolved,
          referer: varReferer.isNotEmpty ? varReferer : referer,
          strategy: FastResolveStrategy.direct,
          needsPositiveConfirm: !likely,
          format: _formatOf(resolved),
        ));
      }
    }

    // ---- 策略 2：正文/内联 JS 直链 ----
    final direct = _extractDirectVideoUrl(html);
    if (direct != null) {
      final resolved = _absolutize(direct, pageUrl);
      if (resolved != null && !isAdUrl(resolved)) {
        candidates.add(FastCandidate(
          url: resolved,
          referer: referer,
          strategy: FastResolveStrategy.inline,
          needsPositiveConfirm: !_isLikelyMediaUrl(resolved),
          format: _formatOf(resolved),
        ));
      }
    }

    // ---- 策略 3：iframe 二跳（限一层，防止深递归烧时间）----
    if (depth < 1) {
      final iframeSrc = _extractIframeSrc(html);
      if (iframeSrc != null) {
        final iframeUrl = _absolutize(iframeSrc, pageUrl);
        if (iframeUrl != null && !isAdUrl(iframeUrl)) {
          try {
            final nested = await _extractCandidates(
              iframeUrl,
              ua,
              pageUrl,
              depth + 1,
            );
            candidates.addAll(nested.map((c) => FastCandidate(
                  url: c.url,
                  referer: c.referer,
                  strategy: FastResolveStrategy.iframe,
                  needsPositiveConfirm: c.needsPositiveConfirm,
                  format: c.format,
                )));
          } catch (_) {
            // iframe 拉取失败继续走完
          }
        }
      }
    }

    return _normalizeCandidates(candidates, pageUrl);
  }

  /// 去重、排序（direct > parserHop > inline > iframe，host 提示加权）、
  /// 截断至 4 个；首个「强媒体信号」候选的策略写回 host 提示。
  Future<List<FastCandidate>> _normalizeCandidates(
      List<FastCandidate> candidates, String pageUrl) async {
    if (candidates.isEmpty) return const [];

    // 去重：同 URL 只保留优先级最高的来源
    final byUrl = <String, FastCandidate>{};
    for (final c in candidates) {
      final key = c.url.trim();
      if (key.isEmpty) continue;
      final existing = byUrl[key];
      if (existing == null ||
          _strategyRank(c.strategy) < _strategyRank(existing.strategy)) {
        byUrl[key] = c;
      }
    }

    var ordered = byUrl.values.toList();
    // host 提示：上次成功的策略排到最前（省去无谓的二跳等待）
    final hint = await _hintStrategyFor(pageUrl);
    if (hint != null) {
      final hinted =
          ordered.where((c) => c.strategy.name == hint).toList(growable: false);
      if (hinted.isNotEmpty) {
        ordered = [...hinted, ...ordered.where((c) => c.strategy.name != hint)];
        // 提示命中仍要防「策略只对旧页面有效」：确认 hinted 之外
        // 还有非同 URL 的候选时才敢整体重排，否则保持原序。
        if (hinted.length == ordered.length) {
          ordered = byUrl.values.toList();
        }
      }
    }

    final capped = ordered.take(4).toList(growable: false);

    // host 级策略记忆：首个强媒体信号候选的策略即是下次应先跑的
    for (final c in capped) {
      if (!c.needsPositiveConfirm) {
        await _recordHostHint(pageUrl, c.strategy);
        break;
      }
    }
    return capped;
  }

  static int _strategyRank(FastResolveStrategy s) => switch (s) {
        FastResolveStrategy.direct => 0,
        FastResolveStrategy.parserHop => 1,
        FastResolveStrategy.inline => 2,
        FastResolveStrategy.iframe => 3,
      };

  // ---------------------------------------------------------------------------
  // 第三方解析器二跳（1.1(d)）
  // ---------------------------------------------------------------------------

  /// from 是否命中第三方解析器名单（大小写不敏感、包含匹配），
  /// 或 url 形态注定不是直链（非 http 开头且无媒体扩展）。
  static bool _isThirdPartyParser(String? from, String url) {
    final f = (from ?? '').toLowerCase();
    if (f.isNotEmpty) {
      for (final hint in thirdPartyParserHints) {
        if (f.contains(hint)) return true;
      }
    }
    final lower = url.toLowerCase();
    final noExt = !lower.contains('.m3u8') && !lower.contains('.mp4');
    final notHttp =
        !url.startsWith('http://') && !url.startsWith('https://');
    return notHttp && noExt;
  }

  /// 解析器接口二跳：定位 `/static/player/{from}.js` 里的解析地址，
  /// 带上 player_aaaa.url 请求，从 JSON/HTML 响应提取直链（≤3 个）。
  Future<List<String>> _resolveViaThirdPartyParser(
    String pageUrl,
    String from,
    String rawUrl,
    String ua,
    int depth,
  ) async {
    if (from.isEmpty || depth >= 2) return const [];
    try {
      final parserAddr = await _locateParserEndpoint(pageUrl, from, ua);
      if (parserAddr == null) return const [];
      final hopUrl = _composeParserRequest(parserAddr, rawUrl);
      if (hopUrl == null) return const [];
      return await _extractFromParserResponse(hopUrl, ua, pageUrl, depth);
    } catch (e) {
      MiruLogger()
          .d('FastResolver: parser hop failed (from=$from)', error: e);
      return const [];
    }
  }

  /// 拉取 `/static/player/{from}.js`（≤256KB），正则提取解析地址。
  Future<String?> _locateParserEndpoint(
      String pageUrl, String from, String ua) async {
    final base = Uri.tryParse(pageUrl);
    if (base == null) return null;
    final scriptUrl =
        '${base.scheme}://${base.host}${base.port == 80 || base.port == 443 ? '' : ':${base.port}'}'
        '/static/player/$from.js';
    final js = await _fetchText(scriptUrl, ua, pageUrl,
        timeout: parserScriptTimeout, maxBytes: 256 * 1024);
    if (js.isEmpty) return null;

    // MacCMS 播放器 JS 的解析地址写法族：
    // MacPlayer.Parse="https://jx.xxx.com/?url="
    // "parse":"https://jx.xxx.com/api.php"  |  'url':'https://jx...'
    final patterns = [
      RegExp(r'''MacPlayer\.Parse\s*=\s*["']([^"']+)["']'''),
      RegExp(r'''["']?parse["']?\s*[:=]\s*["']([^"']+)["']'''),
      RegExp(r'''["']url["']?\s*[:=]\s*["'](https?://[^"']*\?url=)["']'''),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(js);
      if (m != null) {
        var addr = m.group(1)!.trim();
        if (addr.startsWith('//')) addr = 'https:$addr';
        if (addr.startsWith('http://') || addr.startsWith('https://')) {
          return addr;
        }
      }
    }
    return null;
  }

  /// 组装解析请求：解析地址已带 `?url=`/结尾 `=` 时直接追加编码 token，
  /// 否则补 `?url=`（已有 query 补 `&url=`）。
  static String? _composeParserRequest(String parserAddr, String rawUrl) {
    final encoded = Uri.encodeComponent(rawUrl);
    if (parserAddr.endsWith('?url=')) return '$parserAddr$encoded';
    if (parserAddr.endsWith('=')) return '$parserAddr$encoded';
    if (parserAddr.contains('?')) return '$parserAddr&url=$encoded';
    return '$parserAddr?url=$encoded';
  }

  /// 请求解析接口并从响应提取直链：JSON（url|m3u8|link|data.url|
  /// data.m3u8）优先，HTML 时重跑策略 1/2/3（深度 +1，上限 2）。
  Future<List<String>> _extractFromParserResponse(
      String hopUrl, String ua, String referer, int depth) async {
    final text = await _fetchText(hopUrl, ua, referer,
        timeout: parserHopTimeout,
        accept: 'application/json,text/html,*/*;q=0.8');
    if (text.isEmpty) return const [];
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      final urls = _extractFromParserJson(trimmed);
      if (urls.isNotEmpty) return urls;
    }
    // HTML/JS 响应：重跑页面提取策略（只取直链类，不再触发嵌套二跳）
    final direct = _extractDirectVideoUrl(text);
    final playerVar = _extractPlayerVarFull(text);
    final urls = <String>[
      if (direct != null) direct,
      if (playerVar != null &&
          playerVar.$1.startsWith('http') &&
          _isLikelyMediaUrl(playerVar.$1))
        playerVar.$1,
    ];
    return urls.take(2).toList(growable: false);
  }

  /// 解析器 JSON 响应的字段族提取（url|m3u8|link|data.url|data.m3u8）。
  static List<String> _extractFromParserJson(String text) {
    try {
      final data = json.decode(text);
      if (data is! Map) return const [];
      dynamic candidate;
      for (final key in ['url', 'm3u8', 'link']) {
        candidate = data[key];
        if (candidate is String && candidate.startsWith('http')) {
          return [candidate];
        }
      }
      final inner = data['data'];
      if (inner is Map) {
        for (final key in ['url', 'm3u8']) {
          candidate = inner[key];
          if (candidate is String && candidate.startsWith('http')) {
            return [candidate];
          }
        }
      }
    } catch (_) {}
    return const [];
  }

  // ---------------------------------------------------------------------------
  // 提取器（纯函数，单测覆盖）
  // ---------------------------------------------------------------------------

  /// 括号配平提取 player_aaaa/player_data 等变量的 JSON，并解码 url。
  ///
  /// 返回 (解码后的 url, 源站 referer)；失败返回 null。
  /// 仅接受「直链形态」的 url（http(s)/协议相对/站内绝对路径开头）——
  /// 第三方解析器 token 在这里被拒（调用方拿 from 做二跳的是
  /// [_extractPlayerVarFull]）。
  static (String, String)? _extractPlayerVar(String html) {
    final full = _extractPlayerVarFull(html);
    if (full == null) return null;
    final (url, referer, _) = full;
    // 形态约束：直链必须以 http(s)/协议相对/站内绝对路径开头。
    // 「ACG-xxx」这类第三方解析器 token 既不是直链也不是路径，
    // 拿去探测只会白白浪费一个 RTT（甚至被源站 200 误判）。
    if (!url.startsWith('http://') &&
        !url.startsWith('https://') &&
        !url.startsWith('//') &&
        !url.startsWith('/')) {
      return null;
    }
    return (url, referer);
  }

  /// 同 [_extractPlayerVar]，但不做直链形态过滤——url 为空时回退
  /// link 字段，并带回 `from`（解析器名，供二跳）。
  static (String, String, String)? _extractPlayerVarFull(String html) {
    final varRe = RegExp(r'(?:var\s+)?(player_[a-z0-9]+)\s*=\s*\{');
    for (final m in varRe.allMatches(html)) {
      final raw = _balancedJsonAt(html, m.end - 1);
      if (raw == null) continue;
      final obj = _tryParseJson(raw);
      if (obj == null) continue;
      // url 为空串时回退 link/link_next 字段（与 Worker 端对齐）
      final urlField = obj['url'];
      var url = (urlField is String && urlField.trim().isNotEmpty)
          ? urlField
          : obj['link'];
      if (url is! String || url.trim().isEmpty) {
        final next = obj['link_next'];
        url = (next is String && next.trim().isNotEmpty) ? next : null;
      }
      if (url is! String || url.trim().isEmpty) continue;
      final decoded = _decodeMacUrl(url.trim(), obj['encrypt']);
      if (decoded == null || decoded.isEmpty) continue;
      // player 变量所在页面即播放器要求的 referer（站点把 referer 写成
      // 数字/对象时不要抛 TypeError 中止整层提取，降级为空即可）
      final referer =
          obj['referer'] is String ? obj['referer'] as String : '';
      final from = obj['from'] is String ? obj['from'] as String : '';
      return (decoded, referer, from);
    }
    return null;
  }

  /// 从 [openIdx]（指向 `{`）开始括号配平截取 JSON 字符串。
  /// 字符串字面量里的花括号、转义引号都会正确跳过。
  static String? _balancedJsonAt(String html, int openIdx) {
    if (openIdx >= html.length || html[openIdx] != '{') return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = openIdx; i < html.length && i < openIdx + 20000; i++) {
      final c = html[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == r'\') {
        if (inString) escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          return html.substring(openIdx, i + 1);
        }
      }
    }
    return null;
  }

  /// JSON 解析：先严格解析，再宽松修复（单引号/尾逗号）。
  static Map<String, dynamic>? _tryParseJson(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      return null;
    } catch (_) {}
    try {
      final fixed = raw
          .replaceAll("'", '"')
          .replaceAll(RegExp(r',(\s*[}\]])'), r'$1');
      final v = jsonDecode(fixed);
      if (v is Map<String, dynamic>) return v;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// MacCMS 官方编码方案解码（maccms10 All.php）：
  /// encrypt=1 → escape()；encrypt=2 → base64(escape())；0 → 原文。
  static String? _decodeMacUrl(String url, dynamic encrypt) {
    final enc = int.tryParse('${encrypt ?? 0}') ?? 0;
    var result = url;
    try {
      if (enc == 2) {
        result = _macUnescape(normalizedBase64Decode(result));
      } else if (enc == 1) {
        result = _macUnescape(result);
      } else if (result.contains('%')) {
        // encrypt=0：可能套了一层 encodeURIComponent
        try {
          final decoded = Uri.decodeFull(result);
          if (decoded.startsWith('http')) result = decoded;
        } catch (_) {}
      }
    } catch (_) {
      return null;
    }
    return result;
  }

  /// JS `escape()` 的解码：`%uXXXX`（UTF-16）与 `%XX`。
  static String _macUnescape(String s) {
    final sb = StringBuffer();
    final re = RegExp(r'%u([0-9A-Fa-f]{4})|%([0-9A-Fa-f]{2})');
    var last = 0;
    for (final m in re.allMatches(s)) {
      sb.write(s.substring(last, m.start));
      if (m.group(1) != null) {
        sb.writeCharCode(int.parse(m.group(1)!, radix: 16));
      } else {
        sb.writeCharCode(int.parse(m.group(2)!, radix: 16));
      }
      last = m.end;
    }
    sb.write(s.substring(last));
    return sb.toString();
  }

  /// 宽松 base64 解码（自动补 padding）。
  static String normalizedBase64Decode(String input) {
    var s = input;
    if (s.contains('-') || s.contains('_')) {
      s = s.replaceAll('-', '+').replaceAll('_', '/');
    }
    final pad = (4 - s.length % 4) % 4;
    if (pad > 0) s = s + '=' * pad;
    final bytes = base64.decode(s);
    // escape() 编码的产物是纯 ASCII（%XX / %uXXXX），latin1 读取无损
    return latin1.decode(bytes);
  }

  /// 从 HTML / 内联 JS 中提取 m3u8/mp4 直链（排除广告域与广告路径）。
  static String? _extractDirectVideoUrl(String html) {
    final candidates = <String>[];
    for (final m in _urlRe.allMatches(html)) {
      var raw = m.group(0)!;
      // 内联 JS 中的转义斜杠还原
      raw = raw.replaceAll(r'\/', '/');
      if (!isAdUrl(raw) &&
          !_isAdPath(raw) &&
          _videoExtRe.hasMatch(_stripQuery(raw))) {
        candidates.add(raw);
      }
    }
    if (candidates.isEmpty) return null;
    // m3u8 优先（国漫源绝大多数是 HLS）；同级取首个
    for (final c in candidates) {
      if (_stripQuery(c).toLowerCase().endsWith('.m3u8')) return c;
    }
    return candidates.first;
  }

  /// 提取第一个可用 iframe src（排除 about:blank 与广告域）。
  static String? _extractIframeSrc(String html) {
    final re = RegExp(
        r'''<iframe[^>]+src=(["'])([^"']+)\1''',
        caseSensitive: false);
    for (final m in re.allMatches(html)) {
      final src = m.group(2)!.trim();
      if (src.isEmpty || src == 'about:blank') continue;
      if (src.startsWith('javascript:')) continue;
      if (isAdUrl(src)) continue;
      return src;
    }
    return null;
  }

  /// URL 是否「疑似媒体直链」（1.1(c)）：路径带视频扩展、query 带
  /// m3u8/mp4 字样、或 host 含 cdn/vod/stream/play 且路径深度 ≥2。
  /// 不满足者由调用方标记 needsPositiveConfirm（探测必须正向确认）。
  static bool _isLikelyMediaUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return _videoExtRe.hasMatch(_stripQuery(url));
    }
    final path = uri.path.toLowerCase();
    if (_videoExtRe.hasMatch(path)) return true;
    final query = (uri.query).toLowerCase();
    if (query.contains('m3u8') || query.contains('mp4')) return true;
    final host = uri.host.toLowerCase();
    final hasCdnHint = host.contains('cdn') ||
        host.contains('vod') ||
        host.contains('stream') ||
        host.contains('play');
    if (hasCdnHint) {
      final segments =
          path.split('/').where((s) => s.isNotEmpty).length;
      if (segments >= 2) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 网络层（共享连接池，§1.6）
  // ---------------------------------------------------------------------------

  Future<String> _fetchText(
    String url,
    String ua,
    String referer, {
    Duration timeout = pageTimeout,
    int maxBytes = 1024 * 1024,
    String accept = 'text/html,application/xhtml+xml,*/*;q=0.8',
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const VideoSourceNotFoundException('invalid url');
    }
    // SharedHttpClient.io 已带 5s 连接超时；这里只包响应头与整体读取。
    final request = await SharedHttpClient.io
        .getUrl(uri)
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('connect: $url', timeout);
    });
    request.headers.set(HttpHeaders.userAgentHeader, ua);
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
    final response = await request.close().timeout(timeout);
    if (response.statusCode >= 400) {
      throw HttpException('page fetch failed: ${response.statusCode}');
    }
    final bytes = await _readBodyLimited(response, maxBytes, bodyTimeout);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 读取响应体（封顶 [maxBytes]）。总耗时超过 [timeout] 时取消订阅
  /// 并抛 TimeoutException——取消订阅即可释放连接，由共享池的
  /// idleTimeout 兜底回收（慢滴流源站不得挂死第 2 级漏斗）。
  Future<List<int>> _readBodyLimited(
      HttpClientResponse response, int maxBytes, Duration timeout) {
    final bytes = <int>[];
    final completer = Completer<List<int>>();
    Timer? timer;
    StreamSubscription<List<int>>? subscription;

    void settle(Object? error) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(bytes);
      }
    }

    void finish(Object? error) {
      timer?.cancel();
      timer = null;
      final pending = subscription?.cancel();
      subscription = null;
      if (pending == null) {
        settle(error);
      } else {
        pending.whenComplete(() => settle(error)).catchError((_) {});
      }
    }

    timer = Timer(timeout, () {
      finish(TimeoutException('body read exceeded $timeout', timeout));
    });
    subscription = response.listen((chunk) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) {
        finish(null);
      }
    }, onError: (Object e) {
      finish(e);
    }, onDone: () {
      finish(null);
    }, cancelOnError: true);
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static String? _absolutize(String url, String base) {
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('/')) {
      final b = Uri.tryParse(base);
      if (b == null) return null;
      return '${b.scheme}://${b.host}${b.port == 80 || b.port == 443 ? '' : ':${b.port}'}$trimmed';
    }
    try {
      return Uri.parse(base).resolve(trimmed).toString();
    } catch (_) {
      return null;
    }
  }

  static VideoSourceFormat _formatOf(String url) {
    return _stripQuery(url).toLowerCase().endsWith('.m3u8')
        ? VideoSourceFormat.hls
        : VideoSourceFormat.auto;
  }

  static String _stripQuery(String url) {
    return url.split('#').first.split('?').first;
  }

  static String _hostOf(String url) {
    return Uri.tryParse(url)?.host ?? url;
  }

  static bool isAdUrl(String url) {
    final lower = url.toLowerCase();
    for (final hint in _adHostHints) {
      if (lower.contains(hint)) return true;
    }
    return false;
  }

  /// 广告/占位路径判定（1.1(f)）。
  static bool _isAdPath(String url) => _adPathRe.hasMatch(url);
}

/// 测试探针：把私有纯函数转发给单元测试（@visibleForTesting 的
/// 静态类形态，避免为测试放宽私有成员可见性）。
class FastVideoSourceResolverPlayerVarProbe {
  /// 返回 (解码后的 url, 源站 referer)。
  static (String, String)? extract(String html) =>
      FastVideoSourceResolver._extractPlayerVar(html);

  static String? extractDirect(String html) =>
      FastVideoSourceResolver._extractDirectVideoUrl(html);

  static String? extractIframe(String html) =>
      FastVideoSourceResolver._extractIframeSrc(html);

  static String macUnescape(String s) =>
      FastVideoSourceResolver._macUnescape(s);
}

/// 候选纯函数的测试探针（阶段 0 新增逻辑）。
class FastVideoSourceResolverCandidateProbe {
  /// 返回 (解码后的 url, 源站 referer, from)。
  static (String, String, String)? extractFull(String html) =>
      FastVideoSourceResolver._extractPlayerVarFull(html);

  static bool isThirdPartyParser(String? from, String url) =>
      FastVideoSourceResolver._isThirdPartyParser(from, url);

  static bool isLikelyMediaUrl(String? url) =>
      FastVideoSourceResolver._isLikelyMediaUrl(url);

  static String? composeParserRequest(String parserAddr, String rawUrl) =>
      FastVideoSourceResolver._composeParserRequest(parserAddr, rawUrl);

  static List<String> extractFromParserJson(String text) =>
      FastVideoSourceResolver._extractFromParserJson(text);

  static bool isAdPath(String url) => FastVideoSourceResolver._isAdPath(url);
}
