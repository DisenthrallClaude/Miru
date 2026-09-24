import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:path_provider/path_provider.dart';

/// 视频直链解析结果的持久化缓存。
///
/// 秒开链路的第一层：同一集第二次播放（换设备回来、隔天二刷、切集再切回）
/// 直接命中本地缓存，完全跳过 WebView 嗅探（5~30s → 0ms）。
///
/// 存储形态：应用支持目录下单文件 JSON（`resolution_cache.json`），
/// 内存全量索引 + 防抖写盘（写入后 3 秒内合并落盘一次），
/// 最多保留 [maxEntries] 条（LRU 淘汰），单条 TTL 默认 30 分钟。
///
/// 直链大多带时效签名（token/exp 参数），TTL 过期后重新解析；
/// 播放失败（403/失效）时调用 [invalidate] 立即清除，避免反复撞死链。
class ResolutionResultCache {
  ResolutionResultCache._();

  static final ResolutionResultCache instance = ResolutionResultCache._();

  /// 正结果有效期：视频直链签名普遍 30~60 分钟，取保守值。
  static const Duration ttl = Duration(minutes: 30);

  /// 负缓存（解析失败标记）有效期：防止短时间内反复打失败的源。
  static const Duration negativeTtl = Duration(seconds: 60);

  /// host 级「提取失败」负缓存 TTL（阶段 0 / §1.3）：该站静态结构
  /// 解不了，同站所有集都跳过快解层。v1.6.7（P-6）：10 分钟 → 3 分钟
  /// ——一次误分类（改版/风控/瞬时 5xx）让整站 10 分钟进不了 fast 层，
  /// 配合 _shouldSkipLevel 的「换 URL 首查放行」，把误伤半径收到最小。
  static const Duration extractFailedTtl = Duration(minutes: 3);

  /// URL 级「探测判死」负缓存 TTL（阶段 0 / §1.3）：仅影响本集。
  static const Duration probeDeadTtl = Duration(minutes: 5);

  /// 最多保留的条目数（LRU 淘汰）。
  static const int maxEntries = 400;

  final Map<String, _CacheEntry> _entries = {};
  File? _file;
  bool _dirty = false;
  Timer? _flushTimer;

  /// v1.6.6 修复（B1-🟡2）：加载 future 记忆化（仿 RoadHealthTracker 的
  /// `_loadFuture ??= _load()`）。此前 `_loaded` 同步先置位、读盘完成前
  /// 并发的 get()（预取 ∥ 正式解析 ∥ 下载批量）直接读空 `_entries` ——
  /// 持久缓存被无视一整轮、整轮重解析。
  Future<void>? _loadFuture;

  Future<void> _ensureLoaded() => _loadFuture ??= _doLoad();

  Future<void> _doLoad() async {
    File? file;
    try {
      final dir = await getApplicationSupportDirectory();
      file = File('${dir.path}/resolution_cache.json');
      _file = file;
      if (await file.exists()) {
        final raw = await file.readAsString();
        final data = json.decode(raw);
        if (data is Map<String, dynamic>) {
          final now = DateTime.now();
          data.forEach((key, value) {
            if (value is Map<String, dynamic>) {
              final entry = _CacheEntry.fromJson(key, value);
              // 载入时顺手丢弃过期条目，文件不会无限膨胀
              if (entry != null && !entry.isExpired(now)) {
                _entries[key] = entry;
              }
            }
          });
        }
      }
    } on FormatException catch (e) {
      // v1.7.0（P2-6）：内容损坏（半个 JSON——旧 flush 直接 writeAsString
      // 被进程杀死时的产物）→ 改名 .corrupt 隔离。旧实现只置
      // _loadFuture=null，坏文件永远留在原地，之后每次 get() 都重读
      // 坏文件再失败，持久缓存被永久绕过。
      await _quarantineCorrupt(file);
      MiruLogger().w('ResolutionCache: corrupt file quarantined', error: e);
    } catch (e) {
      // 读盘失败（IO 错误，瞬时性）允许下次重试（不把失败钉死在
      // 记忆化 future 里）。
      _loadFuture = null;
      MiruLogger().w('ResolutionCache: load failed, starting empty', error: e);
    }
  }

  /// v1.7.0（P2-6）：坏文件隔离（重命名而非删除——保留现场供人工
  /// 排查；重命名失败静默，下次启动重试）。
  Future<void> _quarantineCorrupt(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.rename('${file.path}.corrupt');
      }
    } catch (_) {}
  }

  /// 查询未过期的解析结果。命中会顺带刷新 LRU 时间戳。
  /// 负缓存条目（解析失败标记）不是可用的解析结果，返回 null——
  /// 查询负标记请用 [isNegative]。
  Future<VideoSource?> get(String episodeUrl) async {
    await _ensureLoaded();
    final entry = _entries[episodeUrl];
    if (entry == null) return null;
    final now = DateTime.now();
    if (entry.isExpired(now)) {
      _entries.remove(episodeUrl);
      _scheduleFlush();
      return null;
    }
    if (entry.isNegative) return null;
    entry.lastUsedAt = now;
    _scheduleFlush();
    return entry.toVideoSource();
  }

  /// 该条目是否在 [maxAge] 内写入（热路径探测免验证用：
  /// 刚解析成功过的直链几乎不可能已失效，跳过可达性探测省一个 RTT）。
  Future<bool> isFresh(String episodeUrl, Duration maxAge) async {
    await _ensureLoaded();
    final entry = _entries[episodeUrl];
    if (entry == null || entry.isNegative) return false;
    return DateTime.now().difference(entry.cachedAt) <= maxAge;
  }

  /// v1.7.0（P0-4）：条目是否已验证（探测/首帧确认过可用）。
  /// 未验证条目（预取写入的首候选）不能免探测直用。
  Future<bool> isVerified(String episodeUrl) async {
    await _ensureLoaded();
    final entry = _entries[episodeUrl];
    if (entry == null || entry.isNegative) return false;
    return entry.verified;
  }

  /// v1.7.0（P0-4）：首帧确认后把条目升级为已验证——下次同集播放
  /// 直接免探测（KPI：同集二刷首帧 ≤ 1s）。幂等：已验证条目跳过。
  Future<void> markVerified(String episodeUrl) async {
    await _ensureLoaded();
    final entry = _entries[episodeUrl];
    if (entry == null || entry.isNegative || entry.verified) return;
    entry.verified = true;
    _scheduleFlush();
  }

  /// 查询负缓存标记（该 URL 近期解析失败过）。
  Future<bool> isNegative(String episodeUrl) async {
    await _ensureLoaded();
    final entry = _entries[episodeUrl];
    if (entry == null) return false;
    if (entry.isExpired(DateTime.now())) {
      _entries.remove(episodeUrl);
      _scheduleFlush();
      return false;
    }
    return entry.isNegative;
  }

  /// 写入解析成功结果。
  ///
  /// v1.6.9（P1-5）：[overwrite] 为 false 时（预取路径），未过期的
  /// 正条目拒绝覆盖——预取写入的是未探测的首候选，缓存里可能是刚
  /// 验证过可用性的播放结果，后台预取把它顶掉会让下次播放拿到更差
  /// /未验证的直链。正式解析路径保持默认覆盖（force 重解析、失效后
  /// 重写都依赖覆盖语义）。
  ///
  /// v1.7.0（P0-4）：[verified] 标记条目是否经过探测/首帧确认。
  /// 预取路径写 false，正式解析（快解/云端/WebView 探测通过）写 true。
  Future<void> put(String episodeUrl, VideoSource source,
      {Duration? ttl, bool overwrite = true, bool verified = true}) async {
    await _ensureLoaded();
    if (!overwrite) {
      final existing = _entries[episodeUrl];
      if (existing != null &&
          !existing.isNegative &&
          !existing.isExpired(DateTime.now())) {
        return;
      }
    }
    _entries[episodeUrl] = _CacheEntry(
      episodeUrl,
      videoUrl: source.url,
      offset: source.offset,
      format: source.format,
      negative: false,
      // 阶段 2 / §2.4：签名感知 TTL——带 exp 的 CDN 直链按 URL 里
      // 剩余寿命存（clamp 1min~6h），不带签名时缺省 30min。
      positiveTtl: ttl ?? ResolutionResultCache.ttl,
      // B10：解析层确认的播放头（防盗链 referer）一并持久化，
      // 二刷/换集回看/预解析后的播放走缓存时不再丢 referer。
      // v1.7.0（P0-6）：只持久化 referer/origin——cookie 落盘既是
      // 隐私问题（明文），也是过期问题（cf_clearance 过期后覆盖新
      // cookie 导致 403）。cookie 每次播放时从 PluginCookieManager
      // 实时取。
      playbackHeaders: _persistableHeaders(source.playbackHeaders),
      verified: verified,
      cachedAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
    );
    _evictIfNeeded();
    _scheduleFlush();
  }

  /// v1.7.0（P0-6）：可持久化的播放头白名单（referer/origin）。
  static Map<String, String> _persistableHeaders(
      Map<String, String> headers) {
    final result = <String, String>{};
    for (final key in const ['referer', 'origin']) {
      final value = headers[key];
      if (value != null && value.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  }

  /// 写入解析失败标记（负缓存）。
  /// [ttl]：分级 TTL（阶段 0 / §1.3）；缺省为通用 [negativeTtl]。
  /// 已有**未过期**条目时拒绝覆盖（成功结果不该被失败标记顶掉；
  /// 负条目重复标记同样跳过——TTL 从首次标记起算即可）。
  /// v1.7.0（P2-7）：已过期的旧条目（无论正负）视同不存在——旧实现
  /// 连过期条目也拒绝写入，负缓存永远刷新不了，只能等 LRU/重载清理。
  Future<void> putNegative(String episodeUrl, {Duration? ttl}) async {
    await _ensureLoaded();
    final existing = _entries[episodeUrl];
    if (existing != null && !existing.isExpired(DateTime.now())) return;
    _entries[episodeUrl] = _CacheEntry(
      episodeUrl,
      videoUrl: '',
      offset: 0,
      format: VideoSourceFormat.auto,
      negative: true,
      negativeTtl: ttl ?? negativeTtl,
      playbackHeaders: const {},
      cachedAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
    );
    _evictIfNeeded();
    _scheduleFlush();
  }

  /// 失效单条（播放打开失败时调用，防止缓存死链反复被用）。
  Future<void> invalidate(String episodeUrl) async {
    await _ensureLoaded();
    if (_entries.remove(episodeUrl) != null) {
      _scheduleFlush();
    }
  }

  /// 全量清空（设置页「清除播放加速缓存」）。
  Future<void> clear() async {
    await _ensureLoaded();
    _entries.clear();
    _scheduleFlush();
    await flush();
  }

  /// v1.7.0（P2-6 测试）：重置加载状态——生产代码的[_loadFuture]
  /// 记忆化不允许重置（单例一旦加载完成就常驻），仅供单测构造
  /// 「磁盘上已是某个文件」的初始状态。
  @visibleForTesting
  Future<void> debugResetForTest() async {
    _loadFuture = null;
    _file = null;
    _entries.clear();
    _dirty = false;
  }

  void _evictIfNeeded() {
    if (_entries.length <= maxEntries) return;
    final sorted = _entries.values.toList()
      ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    final victims = sorted.take(_entries.length - maxEntries);
    for (final victim in victims) {
      _entries.remove(victim.key);
    }
  }

  void _scheduleFlush() {
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 3), () {
      unawaited(flush());
    });
  }

  /// 立即落盘（进程退出前的最后机会由 Timer 兜底即可，不必强求）。
  ///
  /// v1.7.0（P2-6）：原子写——先写 .tmp 再 rename（与 road_health.dart
  /// 同款写法）。旧实现直接 writeAsString，进程被杀时可能写出半个
  /// JSON，下次启动解析失败后缓存被永久绕过。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty || _file == null) return;
    _dirty = false;
    try {
      final now = DateTime.now();
      // 落盘前剔除过期条目
      _entries.removeWhere((_, entry) => entry.isExpired(now));
      final payload = {
        for (final entry in _entries.values) entry.key: entry.toJson(),
      };
      final tmp = File('${_file!.path}.tmp');
      await tmp.writeAsString(json.encode(payload), flush: true);
      await tmp.rename(_file!.path);
    } catch (e) {
      // 写失败恢复脏标记，下一个防抖窗口重试。
      _dirty = true;
      MiruLogger().w('ResolutionCache: flush failed', error: e);
    }
  }
}

class _CacheEntry {
  _CacheEntry(
    this.key, {
    required this.videoUrl,
    required this.offset,
    required this.format,
    required this.negative,
    this.negativeTtl = ResolutionResultCache.negativeTtl,
    this.positiveTtl = ResolutionResultCache.ttl,
    this.playbackHeaders = const {},
    // v1.7.0（P0-4）：默认 true 兼容旧文件（旧正条目都来自探测通过
    // 或播放过的路径；预取路径显式传 false）。
    this.verified = true,
    required this.cachedAt,
    required this.lastUsedAt,
  });

  final String key;
  final String videoUrl;
  final int offset;
  final VideoSourceFormat format;
  final bool negative;

  /// 负条目的分级 TTL（阶段 0 / §1.3；正条目忽略本字段）。
  final Duration negativeTtl;

  /// 正条目的签名感知 TTL（阶段 2 / §2.4；负条目忽略本字段）。
  /// 旧缓存文件没有这个字段时反序列化为默认 30min（向后兼容）。
  final Duration positiveTtl;

  /// 解析层确认的播放请求头（v1.5.2 新增持久化，B10）。
  /// 旧缓存文件没有这个字段时反序列化为空表（向后兼容）。
  final Map<String, String> playbackHeaders;

  /// v1.7.0（P0-4）：条目是否经探测/首帧确认。未验证条目免探测直用
  /// 会把「预取的首候选（可能是 HTML 中转页）」直接交给 mpv。
  /// 可变：首帧确认后由 [ResolutionResultCache.markVerified] 回写。
  bool verified;

  final DateTime cachedAt;
  DateTime lastUsedAt;

  bool get isNegative => negative;

  bool isExpired(DateTime now) {
    final age = now.difference(cachedAt);
    return negative ? age > negativeTtl : age > positiveTtl;
  }

  VideoSource toVideoSource() {
    return VideoSource(
      url: videoUrl,
      offset: offset,
      type: VideoSourceType.online,
      format: format,
      playbackHeaders: playbackHeaders,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': videoUrl,
        'o': offset,
        'f': format.name,
        'n': negative ? 1 : 0,
        if (negative && negativeTtl != ResolutionResultCache.negativeTtl)
          'nt': negativeTtl.inSeconds,
        // §2.4：仅非缺省时写入正条目 TTL，旧条目体积不变。
        if (!negative && positiveTtl != ResolutionResultCache.ttl)
          'pt': positiveTtl.inSeconds,
        // 仅非空时写入，旧条目体积不变
        if (playbackHeaders.isNotEmpty) 'p': playbackHeaders,
        // v1.7.0（P0-4）：仅未验证时写入（false），旧条目体积不变。
        if (!negative && !verified) 'vf': 0,
        'c': cachedAt.millisecondsSinceEpoch,
        'u': lastUsedAt.millisecondsSinceEpoch,
      };

  static _CacheEntry? fromJson(String key, Map<String, dynamic> json) {
    final videoUrl = json['v'] as String?;
    if (videoUrl == null) return null;
    final negative = (json['n'] as num?)?.toInt() == 1;
    final rawNt = (json['nt'] as num?)?.toInt();
    final rawPt = (json['pt'] as num?)?.toInt();
    return _CacheEntry(
      key,
      videoUrl: videoUrl,
      offset: (json['o'] as num?)?.toInt() ?? 0,
      format: VideoSourceFormat.values.firstWhere(
        (f) => f.name == (json['f'] as String?),
        orElse: () => VideoSourceFormat.auto,
      ),
      negative: negative,
      negativeTtl: negative && rawNt != null && rawNt > 0
          ? Duration(seconds: rawNt)
          : ResolutionResultCache.negativeTtl,
      positiveTtl: !negative && rawPt != null && rawPt > 0
          ? Duration(seconds: rawPt)
          : ResolutionResultCache.ttl,
      playbackHeaders: _stringMap(json['p']),
      // v1.7.0（P0-6）：旧缓存文件里的 cookie 丢弃——过期 cf_clearance
      // 覆盖新 cookie 是 403 换源循环的直接根因；播放时实时重取。
      verified: !negative && (json['vf'] as num?)?.toInt() != 0,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['c'] as num?)?.toInt() ?? 0),
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['u'] as num?)?.toInt() ?? 0),
    );
  }

  /// 宽松字符串表反序列化（坏数据宽容处理，别让缓存文件弄崩启动）。
  /// v1.7.0（P0-6）：cookie 不再持久化，旧文件里的残余项在此丢弃。
  static Map<String, String> _stringMap(dynamic v) {
    if (v is! Map) return const {};
    final result = v.map((k, e) => MapEntry(k.toString(), e.toString()));
    result.removeWhere((_, e) => e.isEmpty);
    result.removeWhere((k, _) => k.toLowerCase() == 'cookie');
    return result;
  }
}
