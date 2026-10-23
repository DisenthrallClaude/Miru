import 'package:miru/utils/ad_url_filter.dart';

/// HLS 插播广告段剔除（清单级，v2 去广告）。
///
/// ## 为什么 FFmpeg 的 hls_ad_filter 不够
/// Kazumi 的 FFmpeg 补丁（hls_ad_filter）按「PTS 突然后跳 > 1s」识别广告：
/// 正片放到一半插进一段从 0 开始计时的广告，PTS 回跳 → 丢包直到 PTS 回到
/// 正片范围。它**天生识别不了片头广告**——播放器拿到的第一个包就是广告，
/// 广告的 PTS 被当成「正片基准」，后面真正的正片反而像是「向前跳」。
///
/// ## 实测到的插播特征（2026-10 资源站 CDN，fcdm / MXdm 线路）
/// ```
/// #EXT-X-DISCONTINUITY
/// /20261009/l7aBZIKL/10152kb/hls/vTIO9Ji0.ts   ← 广告：另一个日期/ID 目录、更高码率
/// ...（9 片，合计 17.6s，同一组 URL 在全片重复插入 5 次）
/// #EXT-X-DISCONTINUITY
/// /20230907/Mbq8hdmq/1500kb/hls/XnVLPb42.ts    ← 正片目录
/// ```
///
/// ## 判定（保守，宁可漏删不误伤正片）
/// 以 `#EXT-X-DISCONTINUITY` 切组，统计每个分片的「目录」（host + 去掉文件名
/// 的 path），按时长取**主目录**。一组被判为广告须同时满足：
/// 1. 组时长 ≤ [maxAdGroupSeconds]（单段插播通常 5~30s；片头/片尾曲 90s
///    以上，天然排除）；
/// 2. 组内分片**全部不在主目录**，或命中 [AdUrlFilter] 广告 URL 规则；
/// 并且整体安全阀：主目录时长占比 ≥ [minMainShare]，广告总时长 ≤
/// [maxAdShare]，否则视为「本来就是多文件拼接的正片」，一律不动。
///
/// 被删组如果自带 `#EXT-X-KEY`，紧随其后的正片组会补回删之前生效的
/// KEY 行，保证解密状态不被广告段的 KEY 污染。
class HlsAdStripResult {
  const HlsAdStripResult({
    required this.manifest,
    required this.removedGroups,
    required this.removedSeconds,
    required this.leadingRemoved,
  });

  /// 处理后的清单（未删任何段时与输入相同）。
  final String manifest;

  /// 被删的广告组数。
  final int removedGroups;

  /// 被删的总时长（秒）。
  final double removedSeconds;

  /// 是否删掉了片头广告（第一组）。
  final bool leadingRemoved;

  bool get changed => removedGroups > 0;
}

abstract final class HlsAdStripper {
  static const double maxAdGroupSeconds = 60;
  static const double minMainShare = 0.6;
  static const double maxAdShare = 0.25;

  /// [manifest] 必须是媒体清单（含 #EXTINF）；主清单原样返回。
  /// [baseUrl] 用于把相对 URI 归一成绝对地址后比较目录（输出不改写 URI）。
  static HlsAdStripResult strip(String manifest, String baseUrl) {
    HlsAdStripResult unchanged() => HlsAdStripResult(
          manifest: manifest,
          removedGroups: 0,
          removedSeconds: 0,
          leadingRemoved: false,
        );
    if (!manifest.contains('#EXTINF') ||
        !manifest.contains('#EXT-X-DISCONTINUITY') ||
        manifest.contains('#EXT-X-STREAM-INF')) {
      return unchanged();
    }
    final lines = manifest.split('\n');

    // 头部（第一个分片相关行之前的全局标签）与分组。
    final header = <String>[];
    final groups = <_Group>[];
    var current = _Group();
    var inBody = false;
    double? pendingDuration;
    for (final raw in lines) {
      final line = raw.trimRight();
      final t = line.trim();
      if (t.startsWith('#EXT-X-DISCONTINUITY') &&
          !t.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
        inBody = true;
        if (current.lines.isNotEmpty || current.segments.isNotEmpty) {
          groups.add(current);
        }
        current = _Group()..startsWithDiscontinuity = true;
        current.lines.add(line);
        continue;
      }
      if (!inBody) {
        final isSegmentTag = t.startsWith('#EXTINF') ||
            t.startsWith('#EXT-X-KEY') ||
            t.startsWith('#EXT-X-MAP') ||
            t.startsWith('#EXT-X-BYTERANGE') ||
            t.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
            (t.isNotEmpty && !t.startsWith('#'));
        if (!isSegmentTag) {
          header.add(line);
          continue;
        }
        inBody = true;
      }
      if (t == '#EXT-X-ENDLIST') {
        // 尾标签单独保留，不属于任何组。
        current.trailer.add(line);
        continue;
      }
      if (t.startsWith('#EXTINF')) {
        final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
        pendingDuration = m == null ? 0 : double.tryParse(m.group(1)!) ?? 0;
      } else if (t.startsWith('#EXT-X-KEY')) {
        current.keyLines.add(line);
      } else if (t.isNotEmpty && !t.startsWith('#')) {
        final abs = _absolutize(t, baseUrl);
        current.segments.add(_Seg(abs, pendingDuration ?? 0));
        pendingDuration = null;
      }
      current.lines.add(line);
    }
    if (current.lines.isNotEmpty ||
        current.segments.isNotEmpty ||
        current.trailer.isNotEmpty) {
      groups.add(current);
    }
    if (groups.length < 2) return unchanged();

    // 主目录 = 时长最长的目录。
    final dirSeconds = <String, double>{};
    double total = 0;
    for (final g in groups) {
      for (final s in g.segments) {
        dirSeconds[s.dir] = (dirSeconds[s.dir] ?? 0) + s.duration;
        total += s.duration;
      }
    }
    if (total <= 0 || dirSeconds.isEmpty) return unchanged();
    final mainDir =
        dirSeconds.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    if (dirSeconds[mainDir]! / total < minMainShare) return unchanged();

    final adIdx = <int>{};
    double adSeconds = 0;
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      if (g.segments.isEmpty) continue;
      final dur = g.duration;
      if (dur > maxAdGroupSeconds) continue;
      final foreign = g.segments.every((s) => s.dir != mainDir);
      final flagged = g.segments.any((s) => AdUrlFilter.isAd(s.url));
      if (foreign || flagged) {
        adIdx.add(i);
        adSeconds += dur;
      }
    }
    if (adIdx.isEmpty) return unchanged();
    if (adSeconds / total > maxAdShare) return unchanged();
    if (adIdx.length == groups.where((g) => g.segments.isNotEmpty).length) {
      return unchanged();
    }

    // 重建：保留头部 → 依次输出非广告组；被删组的 KEY 状态补回。
    final out = <String>[...header];
    String? effectiveKey; // 输出流上当前生效的 KEY 行
    String? sourceKey; // 原清单上当前生效的 KEY 行
    var emittedAny = false;
    final trailer = <String>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      trailer.addAll(g.trailer);
      final keyBefore = sourceKey;
      if (g.keyLines.isNotEmpty) sourceKey = g.keyLines.last;
      if (adIdx.contains(i)) continue;
      var body = g.lines;
      // 删掉片头广告后，第一段输出不再以 DISCONTINUITY 开头。
      if (!emittedAny && g.startsWithDiscontinuity) {
        body = body.sublist(1);
      }
      // 本组在第一个分片前是否自己声明了 KEY。
      var setsKeyFirst = false;
      for (final l in body) {
        final t = l.trim();
        if (t.startsWith('#EXT-X-KEY')) {
          setsKeyFirst = true;
          break;
        }
        if (t.startsWith('#EXTINF') || (t.isNotEmpty && !t.startsWith('#'))) {
          break;
        }
      }
      if (!setsKeyFirst && effectiveKey != keyBefore) {
        final restore = keyBefore ?? '#EXT-X-KEY:METHOD=NONE';
        final insertAt = (body.isNotEmpty &&
                body.first.trim().startsWith('#EXT-X-DISCONTINUITY'))
            ? 1
            : 0;
        body = [...body]..insert(insertAt, restore);
      }
      effectiveKey = g.keyLines.isNotEmpty ? g.keyLines.last : keyBefore;
      out.addAll(body);
      emittedAny = true;
    }
    // 去掉尾部多余空行后补 ENDLIST。
    while (out.isNotEmpty && out.last.trim().isEmpty) {
      out.removeLast();
    }
    out.addAll(trailer);
    return HlsAdStripResult(
      manifest: '${out.join('\n')}\n',
      removedGroups: adIdx.length,
      removedSeconds: adSeconds,
      leadingRemoved: adIdx.contains(
          groups.indexWhere((g) => g.segments.isNotEmpty)),
    );
  }

  static String _absolutize(String uri, String baseUrl) {
    try {
      return Uri.parse(baseUrl).resolve(uri).toString();
    } catch (_) {
      return uri;
    }
  }
}

class _Seg {
  _Seg(this.url, this.duration) : dir = _dirOf(url);
  final String url;
  final double duration;
  final String dir;

  static String _dirOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path;
    final cut = path.lastIndexOf('/');
    return '${uri.host}:${uri.hasPort ? uri.port : ''}'
        '${cut >= 0 ? path.substring(0, cut) : ''}';
  }
}

class _Group {
  final List<String> lines = [];
  final List<String> keyLines = [];
  final List<_Seg> segments = [];
  final List<String> trailer = [];
  bool startsWithDiscontinuity = false;

  double get duration => segments.fold(0.0, (s, e) => s + e.duration);
}
