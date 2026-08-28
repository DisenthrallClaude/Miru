import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

/// 本地快速静态解析器（v1.5.2）。
///
/// 用一次轻量 HTTP GET 拉播放页 HTML，在手机本地提取直链：
/// 0.2~0.8 秒（Worker 要 1.5~3.5 秒，WebView 嗅探 5~30 秒），
/// 且出口 IP 与 mpv 播放完全一致——不存在「云端拿到的直链被源站
/// 防盗链绑定 IP 拒掉」的问题。
///
/// 提取策略（对齐 MacCMS V10 / 苹果CMS 系国漫站的通用结构）：
/// 1. **player_aaaa 变量**（括号配平提取——嵌套 `vod_data` 对象不再
///    截断，这是旧正则 `{[^}]*}` 在 blbl/lblb/淘片等站全挂的根因），
///    并按官方 encrypt 字段解码：
///    - `encrypt=0`：原文（可能套一层 encodeURIComponent，解码兜底）
///    - `encrypt=1`：`escape()` 编码 → unescape 解码
///    - `encrypt=2`：`base64(escape())` → 先 base64 再 unescape
///    （官方 maccms10 源码 All.php 的编码顺序即如此）
/// 2. **正文/内联 JS 直链正则**（m3u8/mp4 等，排除广告域；兼容
///    内联 JS 的 `\/` 转义）——Artplayer 等自定义播放器的直链就在
///    页面里（如 MXdm）。
/// 3. **iframe 二跳**（限一层）：iframe 的 src 常是同站播放器页
///    `/static/player/{from}.html?url=...`，对子页面重复 1/2。
///
/// 任何一步失败都静默返回 null（调用方降级云端解析），
/// 绝不抛异常、绝不阻塞主链路。
class FastVideoSourceResolver {
  FastVideoSourceResolver._();

  static final FastVideoSourceResolver instance = FastVideoSourceResolver._();

  /// 单次页面拉取的限时（响应头阶段）。播放页 HTML 通常 <256KB，
  /// 慢源 5 秒足够；超时即放弃降级云端（云端从 CF 边缘访问可能更快）。
  static const Duration pageTimeout = Duration(seconds: 5);

  /// 响应体读取总限时（B2）：[pageTimeout] 只包住响应头，慢滴流源站
  /// 可以在 body 阶段无限挂起整条漏斗（iframe 二跳再叠一层）；
  /// 这里给整段读取一个硬顶，超时取消订阅并放弃。
  static const Duration bodyTimeout = Duration(seconds: 8);

  /// 广告/统计域黑名单（与 WebView 嗅探、Worker 保持一致；含
  /// prestrain 的 %2E 编码变体）。
  static const List<String> _adHostHints = [
    'googleads',
    'googlesyndication',
    'adtrafficquality',
    'doubleclick',
    'prestrain.html',
    'prestrain%2Ehtml',
  ];

  /// 常见视频直链扩展。
  static final RegExp _videoExtRe = RegExp(
      r'\.(m3u8|mp4|flv|ts|mkv|mov|webm)(?=$|[?#])',
      caseSensitive: false);

  static final RegExp _urlRe = RegExp(r'''https?:\\?/\\?\/[^\s"'<>`]+''');

  static const String _defaultUA =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36';

  HttpClient? _client;

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 10);

  /// 解析播放页。失败返回 null（不抛异常）。
  ///
  /// [episodeUrl] 播放页地址；[userAgent]/[referer] 播放请求头
  /// （与 WebView 会话一致的 UA 能减少源站的风控差异）。
  Future<VideoSource?> resolve(
    String episodeUrl, {
    String? userAgent,
    String? referer,
  }) async {
    if (episodeUrl.isEmpty) return null;
    final started = DateTime.now();
    try {
      final result = await _extractFromPage(
        episodeUrl,
        userAgent ?? _defaultUA,
        referer ?? episodeUrl,
        0,
      );
      if (result == null) return null;
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      MiruLogger().i(
          'FastResolver: resolved in ${elapsed}ms: ${result.$1.substring(0, result.$1.length.clamp(0, 90))}');
      return VideoSource(
        url: result.$1,
        offset: 0,
        type: VideoSourceType.online,
        format: _formatOf(result.$1),
        // 解析时源站要求的 referer 一并带回（播放头与解析头一致）
        playbackHeaders: {
          if (result.$2.isNotEmpty) 'referer': result.$2,
        },
      );
    } catch (e) {
      // 静默失败：调用方降级云端解析。这里只记调试日志。
      MiruLogger().d('FastResolver: failed for $episodeUrl', error: e);
      return null;
    }
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  // ---------------------------------------------------------------------------
  // 页面提取主流程
  // ---------------------------------------------------------------------------

  /// 返回 (直链, 源站要求的 referer)；失败返回 null。
  Future<(String, String)?> _extractFromPage(
      String pageUrl, String ua, String referer, int depth) async {
    final html = await _fetchText(pageUrl, ua, referer);
    if (html.isEmpty) return null;

    // 策略 1：player_aaaa（括号配平 + encrypt 解码）
    final playerUrl = _extractPlayerVar(html);
    if (playerUrl != null) {
      final resolved = _absolutize(playerUrl.$1, pageUrl);
      if (resolved != null && !isAdUrl(resolved)) {
        // 带扩展名的直链直接采用；无扩展名的完整 http 链接也接受
        // （部分源直链是 /play?token=... 形态，后续探测会验证）。
        return (resolved, playerUrl.$2);
      }
    }

    // 策略 2：正文/内联 JS 直链
    final direct = _extractDirectVideoUrl(html);
    if (direct != null) {
      final resolved = _absolutize(direct, pageUrl);
      if (resolved != null && !isAdUrl(resolved)) {
        return (resolved, referer);
      }
    }

    // 策略 3：iframe 二跳（限一层，防止深递归烧时间）
    if (depth < 1) {
      final iframeSrc = _extractIframeSrc(html);
      if (iframeSrc != null) {
        final iframeUrl = _absolutize(iframeSrc, pageUrl);
        if (iframeUrl != null && !isAdUrl(iframeUrl)) {
          try {
            final nested = await _extractFromPage(
              iframeUrl,
              ua,
              pageUrl,
              depth + 1,
            );
            if (nested != null) return nested;
          } catch (_) {
            // iframe 拉取失败继续走完
          }
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 提取器（纯函数，单测覆盖）
  // ---------------------------------------------------------------------------

  /// 括号配平提取 player_aaaa/player_data 等变量的 JSON，并解码 url。
  ///
  /// 返回 (解码后的 url, 源站 referer)；失败返回 null。
  static (String, String)? _extractPlayerVar(String html) {
    final varRe = RegExp(r'(?:var\s+)?(player_[a-z0-9]+)\s*=\s*\{');
    for (final m in varRe.allMatches(html)) {
      final raw = _balancedJsonAt(html, m.end - 1);
      if (raw == null) continue;
      final obj = _tryParseJson(raw);
      if (obj == null) continue;
      // url 为空串时回退 link 字段（与 Worker 端 `a.url || a.link` 对齐）
      final urlField = obj['url'];
      final url = (urlField is String && urlField.trim().isNotEmpty)
          ? urlField
          : obj['link'];
      if (url is! String || url.trim().isEmpty) continue;
      final decoded = _decodeMacUrl(url.trim(), obj['encrypt']);
      if (decoded == null || decoded.isEmpty) continue;
      // 形态约束：直链必须以 http(s)/协议相对/站内绝对路径开头。
      // 「ACG-xxx」这类第三方解析器 token 既不是直链也不是路径，
      // 拿去探测只会白白浪费一个 RTT（甚至被源站 200 误判）。
      if (!decoded.startsWith('http://') &&
          !decoded.startsWith('https://') &&
          !decoded.startsWith('//') &&
          !decoded.startsWith('/')) {
        continue;
      }
      // player 变量所在页面即播放器要求的 referer（站点把 referer 写成
      // 数字/对象时不要抛 TypeError 中止整层提取，降级为空即可）
      final referer =
          obj['referer'] is String ? obj['referer'] as String : '';
      return (decoded, referer);
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

  /// 从 HTML / 内联 JS 中提取 m3u8/mp4 直链（排除广告域）。
  static String? _extractDirectVideoUrl(String html) {
    final candidates = <String>[];
    for (final m in _urlRe.allMatches(html)) {
      var raw = m.group(0)!;
      // 内联 JS 中的转义斜杠还原
      raw = raw.replaceAll(r'\/', '/');
      if (!isAdUrl(raw) && _videoExtRe.hasMatch(_stripQuery(raw))) {
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

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  Future<String> _fetchText(String url, String ua, String referer) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const VideoSourceNotFoundException('invalid url');
    }
    final request = await _http.getUrl(uri).timeout(pageTimeout);
    request.headers.set(HttpHeaders.userAgentHeader, ua);
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set(HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,*/*;q=0.8');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
    final response = await request.close().timeout(pageTimeout);
    if (response.statusCode >= 400) {
      throw HttpException('page fetch failed: ${response.statusCode}');
    }
    // 页面通常 <256KB；封顶 1MB 防御异常大响应，且整段读取有总限时
    final bytes = await _readBodyLimited(response, 1024 * 1024, bodyTimeout);
    // 中文站绝大多数是 UTF-8；GBK 站点正则仍能命中 ASCII 直链
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 读取响应体（封顶 [maxBytes]）。总耗时超过 [timeout] 时取消订阅
  /// 并抛 TimeoutException——取消订阅即可释放连接，由 _http 的
  /// idleTimeout 兜底回收（B2：慢滴流源站不得挂死第 2 级漏斗）。
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

    /// 结束读取：先停表、再取消订阅（释放连接）、最后交付结果。
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
      // 触发总限时：取消订阅让连接回到池里，由 idleTimeout 回收
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

  static bool isAdUrl(String url) {
    final lower = url.toLowerCase();
    for (final hint in _adHostHints) {
      if (lower.contains(hint)) return true;
    }
    return false;
  }
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
