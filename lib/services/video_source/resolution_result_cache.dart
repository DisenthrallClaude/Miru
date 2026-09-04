import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  /// 解不了，同站所有集都跳过快解层，10 分钟后重试（站点可能换结构）。
  static const Duration extractFailedTtl = Duration(minutes: 10);

  /// URL 级「探测判死」负缓存 TTL（阶段 0 / §1.3）：仅影响本集。
  static const Duration probeDeadTtl = Duration(minutes: 5);

  /// 最多保留的条目数（LRU 淘汰）。
  static const int maxEntries = 400;

  final Map<String, _CacheEntry> _entries = {};
  File? _file;
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushTimer;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/resolution_cache.json');
      if (await _file!.exists()) {
        final raw = await _file!.readAsString();
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
    } catch (e) {
      MiruLogger().w('ResolutionCache: load failed, starting empty', error: e);
    }
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
  Future<void> put(String episodeUrl, VideoSource source,
      {Duration? ttl}) async {
    await _ensureLoaded();
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
      playbackHeaders: Map.of(source.playbackHeaders),
      cachedAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
    );
    _evictIfNeeded();
    _scheduleFlush();
  }

  /// 写入解析失败标记（负缓存）。
  /// [ttl]：分级 TTL（阶段 0 / §1.3）；缺省为通用 [negativeTtl]。
  /// 已有**正条目**时拒绝覆盖（成功结果不该被失败标记顶掉；
  /// 负条目重复标记同样跳过——TTL 从首次标记起算即可）。
  Future<void> putNegative(String episodeUrl, {Duration? ttl}) async {
    await _ensureLoaded();
    final existing = _entries[episodeUrl];
    if (existing != null) return;
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
      await _file!.writeAsString(json.encode(payload), flush: false);
    } catch (e) {
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
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['c'] as num?)?.toInt() ?? 0),
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['u'] as num?)?.toInt() ?? 0),
    );
  }

  /// 宽松字符串表反序列化（坏数据宽容处理，别让缓存文件弄崩启动）。
  static Map<String, String> _stringMap(dynamic v) {
    if (v is! Map) return const {};
    final result = v.map((k, e) => MapEntry(k.toString(), e.toString()));
    result.removeWhere((_, e) => e.isEmpty);
    return result;
  }
}
