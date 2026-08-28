import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';

/// 本地媒体代理：秒开链路的「数据层」。
///
/// 在 127.0.0.1 起一个迷你 HTTP 服务，mpv 不再直连源站，而是播放
/// `http://127.0.0.1:<port>/<secret>/...`。代理负责：
///
/// 1. **MP4 直链（Range 代理）**：透传 Range 请求；回源响应的前
///    [mp4PrefetchBytes] 边转发给 mpv 边落盘。第二次观看同一集时开头
///    数据全部从磁盘秒回，首帧近乎瞬时。
/// 2. **HLS（m3u8 清单改写 + 分片缓存）**：拉取源清单（多码率自动
///    选第一条），把分片 URL 改写为指向代理的 `/seg/`；前
///    [hlsPrefetchSegments] 个分片全量落盘。二次观看清单内前几片秒回。
/// 3. **prefetch（预取）**：解析出直链但还没点播放时，后台先把开头
///    数据拉到本地；点播放时 mpv 的首个请求直接命中磁盘。
///
/// 可靠性设计：
/// - 回源失败/源站 403 → 代理返回 502，mpv 侧表现为普通打开失败，
///   由混合解析服务的「直连兜底」用原始 URL 重开，不影响可播放性；
/// - 代理全程 try-catch，任何内部异常都降级为 502，绝不崩溃；
/// - 磁盘缓存带条目 LRU + 总量上限，自动清理旧番剧；
/// - 计量网络（移动数据）下预取自动跳过，不偷跑流量。
class LocalMediaProxy {
  LocalMediaProxy._();

  static final LocalMediaProxy instance = LocalMediaProxy._();

  /// MP4 开头缓存上限：4MB 足够覆盖 moov + 前几十秒视频。
  static const int mp4PrefetchBytes = 4 * 1024 * 1024;

  /// HLS 预取分片数：约 1~2 分钟内容，起播 + 快进回看都够用。
  static const int hlsPrefetchSegments = 6;

  /// 磁盘缓存条目上限（一个条目 ≈ 一集）。
  static const int maxEntries = 10;

  /// 磁盘缓存总大小上限（含分片）。
  static const int maxTotalBytes = 160 * 1024 * 1024;

  /// [hasUsableCache] 的 MP4 判定阈值：缓存开头至少这么多字节才值得走代理。
  static const int usableMp4Bytes = 1024 * 1024;

  /// [hasUsableCache] 的 HLS 判定阈值：至少这么多分片已落盘。
  static const int usableHlsSegments = 2;

  /// 回源连接超时（B4）：黑洞源站（SYN 被丢）不得把 mpv 的代理请求
  /// 无限期挂住——mpv 侧表现为「一直转圈」。
  static const Duration originConnectTimeout = Duration(seconds: 8);

  /// 回源响应头超时（B4）：连接建立后源站必须在这个时间内开始回包。
  static const Duration originHeaderTimeout = Duration(seconds: 15);

  /// 回源数据流 chunks 间隔超时（B4）：流式播放中连续这么久没有新数据
  /// 视为源站死掉，断开让 mpv 走直连兜底/重连。
  static const Duration originChunkTimeout = Duration(seconds: 30);

  /// 计量网络检查钩子：由外部接线（避免本文件依赖平台插件，便于单测）。
  static bool Function() isMeteredCheck = () => false;

  HttpServer? _server;
  String _secret = '';
  Directory? _cacheDir;

  /// 会话内注册表：token → 源地址 + 播放用请求头。
  /// 播放请求（mpv → 代理）会透传 Referer/UA，这里主要供预取使用。
  final Map<String, _ProxyRegistration> _registrations = {};

  /// token → 改写后的 m3u8 清单（会话内复用，避免重复拉取+改写）。
  final Map<String, String> _rewrittenManifests = {};

  /// 每个 token 的写盘互斥（避免并发 tee 写坏文件）。
  final Set<String> _writing = {};

  bool get isEnabled =>
      GStorage.getSetting(SettingsKeys.localMediaCacheEnable);

  int? get port => _server?.port;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _cacheDir ??= await _createCacheDir();
    _secret = _randomSecret();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handleRequest, onError: (Object e) {
      MiruLogger().w('LocalMediaProxy: server error', error: e);
    });
    _server = server;
    MiruLogger().i('LocalMediaProxy: listening on 127.0.0.1:${server.port}');
  }

  Future<Directory> _createCacheDir() async {
    final dir = Directory('${Directory.systemTemp.path}/miru_media_proxy');
    await dir.create(recursive: true);
    return dir;
  }

  String _randomSecret() {
    // 加密随机（旧版时间戳异或可预测；回环+随机端口已缓解，这里再加固）
    final rnd = Random.secure();
    return List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// 回源 HTTP 客户端：连接阶段有硬超时（B4）。
  HttpClient _originClient() =>
      HttpClient()..connectionTimeout = originConnectTimeout;

  Future<void> shutdown() async {
    final server = _server;
    _server = null;
    _registrations.clear();
    _rewrittenManifests.clear();
    await server?.close(force: true);
  }

  /// 判断该直链是否已有「可用的」磁盘缓存：
  /// - MP4：开头数据 ≥ [usableMp4Bytes]（覆盖 moov + 前几十秒）；
  /// - HLS：至少 [usableHlsSegments] 个分片已落盘。
  ///
  /// 智能代理模式（v1.5.1）用它决定是否走代理：
  /// 有数据才代理（首帧从磁盘秒出），没数据直连（v1.3.2 行为，
  /// 代理从必经之路退化成纯加速器，绝不给首播引入额外风险）。
  Future<bool> hasUsableCache(String videoUrl,
      {required bool isHls}) async {
    if (!videoUrl.startsWith('http')) return false;
    try {
      final token = _tokenFor(videoUrl);
      final meta = await _readMeta(token);
      if (meta == null) return false;
      if (!isHls) {
        final f = File('${_cacheDir!.path}/$token.bin');
        return await f.exists() && await f.length() >= usableMp4Bytes;
      }
      var present = 0;
      for (final segToken in meta.segTokens) {
        final f = File('${_cacheDir!.path}/seg_$segToken.bin');
        if (await f.exists() && await f.length() > 0) {
          present++;
          if (present >= usableHlsSegments) return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 注册与预取
  // ---------------------------------------------------------------------------

  /// 注册一个直链，返回代理播放地址。isHls 决定走清单改写还是 Range 代理。
  /// 返回 null 表示代理不可用（未启用/启动失败），调用方直接用原始 URL。
  Future<String?> register(
    String videoUrl, {
    required bool isHls,
    Map<String, String> headers = const {},
  }) async {
    if (!isEnabled || !videoUrl.startsWith('http')) return null;
    try {
      await _ensureStarted();
      final token = _tokenFor(videoUrl);
      _registrations[token] = _ProxyRegistration(
        url: videoUrl,
        headers: Map.of(headers),
        isHls: isHls,
      );
      unawaited(_evictIfNeeded());
      final kind = isHls ? 'm3u8' : 'media';
      return 'http://127.0.0.1:$port/$_secret/$kind/$token'
          '?u=${Uri.encodeComponent(videoUrl)}';
    } catch (e) {
      MiruLogger().w('LocalMediaProxy: register failed', error: e);
      return null;
    }
  }

  /// 后台预取开头数据。任何失败静默放弃（点播放时走正常回源）。
  Future<void> prefetch(String videoUrl,
      {required bool isHls, Map<String, String> headers = const {}}) async {
    if (!isEnabled || !videoUrl.startsWith('http')) return;
    if (isMeteredCheck()) {
      MiruLogger().d('LocalMediaProxy: skip prefetch on metered network');
      return;
    }
    try {
      await _ensureStarted();
      if (isHls) {
        await _prefetchHls(videoUrl, headers);
      } else {
        await _prefetchMp4(videoUrl, headers);
      }
    } catch (e) {
      MiruLogger().w('LocalMediaProxy: prefetch failed', error: e);
    }
  }

  Future<void> _prefetchMp4(String url, Map<String, String> headers) async {
    final token = _tokenFor(url);
    final file = File('${_cacheDir!.path}/$token.bin');
    if (await file.exists() && await file.length() >= mp4PrefetchBytes) {
      return; // 已预取过
    }
    // 写盘全程持锁（B5）：与播放 tee 互斥，防止并发截断/追加写坏缓存。
    // 持锁期间 mpv 的 tee 会自动放弃写盘（正常转发不受影响），预取
    // 完成后释放。拿不到锁说明 tee 正在填缓存，让它写即可。
    if (!_writing.add(token)) {
      return;
    }
    final client = _originClient();
    try {
      // 从已有缓存的末尾续拉（追加语义），已有部分不重复下载
      final existing =
          (await file.exists()) ? await file.length() : 0;
      if (existing >= mp4PrefetchBytes) return;
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(originConnectTimeout);
      headers.forEach(request.headers.set);
      request.headers
          .set(HttpHeaders.rangeHeader, 'bytes=$existing-${mp4PrefetchBytes - 1}');
      final response =
          await request.close().timeout(originHeaderTimeout);
      FileMode writeMode;
      int writeOffset;
      if (response.statusCode == HttpStatus.partialContent) {
        // 206：必须确实从 existing 开始（Content-Range 可解析且匹配），
        // 否则字节错位，放弃（B12 同款校验）
        final start = _contentRangeStart(response);
        if (start == null || start != existing) return;
        writeMode = existing > 0 ? FileMode.append : FileMode.write;
        writeOffset = existing;
      } else if (response.statusCode == HttpStatus.ok) {
        // 200 全量：从 0 开始重写（截断模式，仍持写锁，无并发风险）
        writeMode = FileMode.write;
        writeOffset = 0;
      } else {
        return;
      }
      final total =
          _totalFromContentRange(response) ?? _totalFromContentLength(response);
      await _writeStreamLimited(
        file,
        response.timeout(originChunkTimeout),
        mp4PrefetchBytes - writeOffset,
        mode: writeMode,
      );
      await _writeMeta(token, url, headers, isHls: false, total: total);
    } finally {
      _writing.remove(token);
      client.close(force: true);
    }
  }

  Future<void> _prefetchHls(String url, Map<String, String> headers) async {
    final built = await _buildManifest(url, headers);
    if (built == null) return;
    _rewrittenManifests[_tokenFor(url)] = built.manifest;
    final segments =
        built.segmentUrls.take(hlsPrefetchSegments).toList(growable: false);
    final segTokens = <String>[];
    for (final segmentUrl in segments) {
      await _fetchSegmentToCache(segmentUrl, headers);
      segTokens.add(_tokenFor(segmentUrl));
    }
    await _writeMeta(_tokenFor(url), url, headers, isHls: true,
        total: null, segTokens: segTokens);
  }

  // ---------------------------------------------------------------------------
  // 请求处理
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.pathSegments;
      // /<secret>/<kind>/<token>
      if (path.length < 3 || path[0] != _secret) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final kind = path[1];
      final token = path[2];
      switch (kind) {
        case 'm3u8':
          await _serveManifest(request, token);
          break;
        case 'media':
          await _serveMediaRange(request, token);
          break;
        case 'seg':
          await _serveSegment(request, token);
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    } catch (e) {
      MiruLogger().w(
          'LocalMediaProxy: request failed for ${request.uri}', error: e);
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// HLS 清单：优先用会话缓存的改写结果，否则拉源→（多码率选拉子清单）→改写。
  Future<void> _serveManifest(HttpRequest request, String token) async {
    final registration = _registrations[token];
    final srcUrl = registration?.url ?? _srcFromQuery(request);
    if (srcUrl == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    var text = _rewrittenManifests[token];
    if (text == null) {
      final headers = _forwardHeaders(request, registration);
      final built = await _buildManifest(srcUrl, headers);
      if (built == null) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }
      text = built.manifest;
      _rewrittenManifests[token] = text;
      // 首次播放：后台把前几片补进缓存（与 mpv 的分片请求并行，互不阻塞）
      unawaited(_prefetchSegmentsQuietly(built.segmentUrls, headers));
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    request.response.add(utf8.encode(text));
    await request.response.close();
  }

  Future<void> _prefetchSegmentsQuietly(
      List<String> segmentUrls, Map<String, String> headers) async {
    if (isMeteredCheck()) return;
    for (final url in segmentUrls.take(hlsPrefetchSegments)) {
      await _fetchSegmentToCache(url, headers);
    }
  }

  Future<void> _fetchSegmentToCache(
      String url, Map<String, String> headers) async {
    final segToken = _tokenFor(url);
    final segFile = File('${_cacheDir!.path}/seg_$segToken.bin');
    if (await segFile.exists()) return;
    if (_writing.contains(segToken)) return; // tee 正在写同一分片
    final client = _originClient();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(originConnectTimeout);
      headers.forEach(request.headers.set);
      final response =
          await request.close().timeout(originHeaderTimeout);
      if (response.statusCode != 200) return;
      // 写盘前拿互斥锁（B5）：tee 可能刚好开始写同一分片；拿到锁后
      // 再复查一次文件存在性（tee 可能已写完）。
      if (!_writing.add(segToken)) return;
      try {
        if (await segFile.exists()) return;
        await _writeStreamLimited(
            segFile, response.timeout(originChunkTimeout), 32 * 1024 * 1024);
      } catch (_) {
        // 写了一半的分片不能当完整缓存用：删掉
        try {
          if (await segFile.exists()) await segFile.delete();
        } catch (_) {}
        rethrow;
      } finally {
        _writing.remove(segToken);
      }
    } catch (_) {
      // 单片失败不影响其它片
    } finally {
      client.close(force: true);
    }
  }

  /// HLS 分片：磁盘命中直接回；否则回源全量透传并落盘。
  Future<void> _serveSegment(HttpRequest request, String token) async {
    final registration = _registrations[token];
    final srcUrl = registration?.url ?? _srcFromQuery(request);
    if (srcUrl == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final segFile = File('${_cacheDir!.path}/seg_$token.bin');
    if (await segFile.exists()) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('video', 'mp2t');
      await request.response.addStream(segFile.openRead());
      await request.response.close();
      return;
    }

    final client = _originClient();
    IOSink? sink;
    // 是否由本次请求持有写锁：finally 只释放自己持有的，
    // 避免误释放并发预取的锁（预取写盘期间也注册 _writing）。
    var holdingWriteLock = false;
    try {
      final upstream = await client
          .getUrl(Uri.parse(srcUrl))
          .timeout(originConnectTimeout);
      _forwardHeaders(request, registration).forEach(upstream.headers.set);
      final response =
          await upstream.close().timeout(originHeaderTimeout);
      if (response.statusCode != 200) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('video', 'mp2t');
      // 分片小（几 MB），边转发边落盘；已被别人在写时只透传
      holdingWriteLock = _writing.add(token);
      if (holdingWriteLock) {
        sink = segFile.openWrite();
      }
      await for (final chunk in response.timeout(originChunkTimeout)) {
        request.response.add(chunk);
        sink?.add(chunk);
      }
      await request.response.close();
      await sink?.close();
      sink = null;
    } catch (_) {
      await sink?.close().catchError((_) {});
      if (holdingWriteLock) {
        // 半截分片不能当完整缓存用：删掉，下次请求重新回源
        try {
          if (await segFile.exists()) await segFile.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (holdingWriteLock) _writing.remove(token);
      client.close(force: true);
    }
  }

  /// MP4 Range 代理：磁盘命中区间直接回，缺口流式回源，响应流 tee 落盘。
  ///
  /// mpv 的典型请求形态是「bytes=0-」开放区间 + 顺序大块读；seek 时是
  /// 「bytes=X-Y」。处理矩阵（v1.5.1 全面重写为流式，绝不把上游响应
  /// 整段读入内存——旧实现遇到「无 Range 的 GET + 已有磁盘缓存」会把
  /// 视频剩余全部字节缓冲进内存，大文件直接 OOM/卡死，是「有时很难
  /// 加载进去」的第一元凶）：
  /// - 区间整段在磁盘缓存内 → 纯磁盘 206 响应；
  /// - 有界区间越过缓存边界 → 只回磁盘部分（206 bytes X-diskEnd/total），
  ///   mpv 短读后会带新 Range 重连补齐（本地回环，几乎零开销）；
  /// - 开放区间且总长已知 → 磁盘部分 + 上游流式拼接为一个连续 206
  ///   （上游请求 bytes=cachedLen-，正好接在缓存末尾，可边转发边 tee）；
  /// - 开放区间且总长未知 → 只回磁盘部分，mpv 重连后走透传路径补齐；
  /// - 区间在缓存外 → 回源透传；顺序读且正好接在缓存末尾时 tee。
  Future<void> _serveMediaRange(HttpRequest request, String token) async {
    final registration = _registrations[token];
    final srcUrl = registration?.url ?? _srcFromQuery(request);
    if (srcUrl == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final forwardHeaders = _forwardHeaders(request, registration);
    final meta = await _readMeta(token);
    final cacheFile = File('${_cacheDir!.path}/$token.bin');
    final cachedLen =
        await cacheFile.exists() ? await cacheFile.length() : 0;

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    // null = 客户端没发 Range（或格式非法）：透传时不强加 Range，
    // 避免给无 Range 请求回 206 的语义违规。
    final range = _parseRange(rangeHeader ?? '');
    final requestedStart = range?.start ?? 0;
    final requestedEnd = range?.end; // null = 开放区间（到文件尾）

    final client = _originClient();
    IOSink? teeSink;
    // 本次请求是否持有写锁：只释放自己持有的（见 _serveSegment）
    var holdingWriteLock = false;
    try {
      if (cachedLen > 0 && requestedStart < cachedLen) {
        // ---- 区间与磁盘缓存有交集 ----
        final diskEnd =
            requestedEnd == null || requestedEnd >= cachedLen - 1
                ? cachedLen - 1
                : requestedEnd;

        // 1) 有界且整段在磁盘内：纯磁盘响应，不碰上游
        if (requestedEnd != null && requestedEnd <= diskEnd) {
          final total = meta?.total ?? diskEnd + 1;
          await _respondDiskRange(
              request, cacheFile, requestedStart, diskEnd, total);
          return;
        }

        // 2) 有界但越过缓存边界：只回磁盘部分，mpv 会重连补齐
        if (requestedEnd != null) {
          final total = meta?.total ?? diskEnd + 1;
          await _respondDiskRange(
              request, cacheFile, requestedStart, diskEnd, total);
          return;
        }

        // 3) 开放区间且总长未知：不能回磁盘部分——Content-Range 里的
        //    假 total 会让 mpv 以为文件只有缓存这么大，播到边界就停。
        //    直接走透传（顺带从源站学到总长写进 meta，下次就能合并了）。
        if (meta?.total == null) {
          await _passthroughUpstream(request, client, srcUrl, forwardHeaders,
              cacheFile, token, meta, range, requestedStart, cachedLen);
          return;
        }
        final total = meta!.total!;

        // 4) 开放区间且总长已知：磁盘 + 上游流式拼接为一个连续 206
        final upstream = await client
            .getUrl(Uri.parse(srcUrl))
            .timeout(originConnectTimeout);
        forwardHeaders.forEach(upstream.headers.set);
        upstream.headers
            .set(HttpHeaders.rangeHeader, 'bytes=$cachedLen-');
        final response =
            await upstream.close().timeout(originHeaderTimeout);
        if (response.statusCode != HttpStatus.partialContent) {
          // 上游不接受 Range（返回 200 全量）。
          // 请求从 0 开始时可以退化为 200 透传（字节对齐）；
          // 否则无法与磁盘拼接，502 让 mpv 走直连兑底。
          await response.drain<void>().catchError((_) {});
          if (requestedStart == 0) {
            await _passthroughFresh(
                request, client, srcUrl, forwardHeaders, cacheFile, token);
            return;
          }
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
          return;
        }

        final servedEnd = total - 1;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $requestedStart-$servedEnd/$total');
        request.response.contentLength = servedEnd - requestedStart + 1;
        // 磁盘部分（流式，不占大内存）
        await request.response
            .addStream(cacheFile.openRead(requestedStart, diskEnd + 1));
        // 上游部分：从 cachedLen 开始正好接在缓存末尾，可 tee
        holdingWriteLock = cachedLen < mp4PrefetchBytes && _writing.add(token);
        if (holdingWriteLock) {
          teeSink = cacheFile.openWrite(mode: FileMode.append);
        }
        await for (final chunk in response.timeout(originChunkTimeout)) {
          request.response.add(chunk);
          if (teeSink != null) {
            if (await cacheFile.length() + chunk.length <= mp4PrefetchBytes) {
              teeSink.add(chunk);
            } else {
              await teeSink.close();
              teeSink = null;
              holdingWriteLock = false;
              _writing.remove(token);
            }
          }
        }
        await request.response.close();
        await teeSink?.close();
        teeSink = null;
        return;
      }

      // ---- 区间在缓存之外：透传回源 ----
      await _passthroughUpstream(request, client, srcUrl, forwardHeaders,
          cacheFile, token, meta, range, requestedStart, cachedLen);
    } catch (_) {
      await teeSink?.close().catchError((_) {});
      rethrow;
    } finally {
      if (holdingWriteLock) _writing.remove(token);
      client.close(force: true);
    }
  }

  /// 回源透传：转发 Range，回传状态/Content-Range/Content-Length，
  /// 顺带把学到的总长写进 meta；顺序读且接续缓存末尾时 tee 落盘。
  Future<void> _passthroughUpstream(
    HttpRequest request,
    HttpClient client,
    String srcUrl,
    Map<String, String> forwardHeaders,
    File cacheFile,
    String token,
    _ProxyMeta? meta,
    ({int start, int? end})? range,
    int requestedStart,
    int cachedLen,
  ) async {
    IOSink? teeSink;
    // 本次请求是否持有写锁：只释放自己持有的（见 _serveSegment）
    var holdingWriteLock = false;
    try {
      final upstream = await client
          .getUrl(Uri.parse(srcUrl))
          .timeout(originConnectTimeout);
      forwardHeaders.forEach(upstream.headers.set);
      if (range != null) {
        upstream.headers.set(
            HttpHeaders.rangeHeader, 'bytes=$requestedStart-${range.end ?? ''}');
      }
      final response =
          await upstream.close().timeout(originHeaderTimeout);
      if (response.statusCode != 206 && response.statusCode != 200) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }
      final total = _totalFromContentRange(response) ??
          _totalFromContentLength(response) ??
          meta?.total;
      if (total != null && meta?.total != total) {
        await _writeMeta(token, srcUrl, forwardHeaders,
            isHls: false, total: total);
      }
      request.response.statusCode = response.statusCode;
      final contentRange =
          response.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null) {
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, contentRange);
      }
      final contentLength =
          response.headers.value(HttpHeaders.contentLengthHeader);
      if (contentLength != null) {
        request.response.headers
            .set(HttpHeaders.contentLengthHeader, contentLength);
      }
      // 只在「正好接在缓存末尾的顺序读」时 tee 写盘（保证字节连续）。
      // B12：上游必须确实回 206 且从 requestedStart 开始——上游忽略
      // Range 回 200 全量时，从字节 0 开始的整个 body 会被追加到
      // cachedLen 处，直接污染缓存（不 tee 只是丢一次缓存机会，
      // tee 错了是永久损坏）。
      final upstreamStart = _contentRangeStart(response);
      final canTee = response.statusCode == HttpStatus.partialContent &&
          upstreamStart == requestedStart &&
          requestedStart == cachedLen &&
          cachedLen < mp4PrefetchBytes &&
          _writing.add(token);
      if (canTee) {
        teeSink = cacheFile.openWrite(mode: FileMode.append);
        holdingWriteLock = true;
      }
      await for (final chunk in response.timeout(originChunkTimeout)) {
        request.response.add(chunk);
        if (teeSink != null) {
          if (await cacheFile.length() + chunk.length <= mp4PrefetchBytes) {
            teeSink.add(chunk);
          } else {
            await teeSink.close();
            teeSink = null;
            holdingWriteLock = false;
            _writing.remove(token);
          }
        }
      }
      await request.response.close();
      await teeSink?.close();
      teeSink = null;
    } catch (_) {
      await teeSink?.close().catchError((_) {});
      rethrow;
    } finally {
      if (holdingWriteLock) _writing.remove(token);
    }
  }

  /// 纯磁盘区间响应（206 + Content-Range + 流式文件读取）。
  Future<void> _respondDiskRange(
    HttpRequest request,
    File file,
    int start,
    int end,
    int total,
  ) async {
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
        HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    request.response.contentLength = end - start + 1;
    await request.response.addStream(file.openRead(start, end + 1));
    await request.response.close();
  }

  /// 上游不接受 Range 时的退化路径：从 0 开始全量透传（可 tee 落盘）。
  Future<void> _passthroughFresh(
    HttpRequest request,
    HttpClient client,
    String srcUrl,
    Map<String, String> forwardHeaders,
    File cacheFile,
    String token,
  ) async {
    final upstream = await client
        .getUrl(Uri.parse(srcUrl))
        .timeout(originConnectTimeout);
    forwardHeaders.forEach(upstream.headers.set);
    final response =
        await upstream.close().timeout(originHeaderTimeout);
    if (response.statusCode != 200 && response.statusCode != 206) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    IOSink? teeSink;
    // 本次请求是否持有写锁：只释放自己持有的（见 _serveSegment）
    var holdingWriteLock = false;
    try {
      holdingWriteLock = cacheFile.lengthSync() == 0 && _writing.add(token);
      if (holdingWriteLock) {
        teeSink = cacheFile.openWrite();
      }
      await for (final chunk in response.timeout(originChunkTimeout)) {
        request.response.add(chunk);
        if (teeSink != null) {
          if (await cacheFile.length() + chunk.length <= mp4PrefetchBytes) {
            teeSink.add(chunk);
          } else {
            await teeSink.close();
            teeSink = null;
            holdingWriteLock = false;
            _writing.remove(token);
          }
        }
      }
      await request.response.close();
      await teeSink?.close();
    } catch (_) {
      await teeSink?.close().catchError((_) {});
      rethrow;
    } finally {
      if (holdingWriteLock) _writing.remove(token);
    }
  }

  // ---------------------------------------------------------------------------
  // HLS 清单：拉取 / 选子清单 / 改写
  // ---------------------------------------------------------------------------

  /// 拉源清单 →（多码率选拉第一条子清单）→ 改写分片 URL 指向代理。
  /// 返回 null 表示任何一步失败。
  Future<_BuiltManifest?> _buildManifest(
      String url, Map<String, String> headers) async {
    final raw = await _fetchPlaylistText(url, headers);
    if (raw == null) return null;
    final resolved = await _resolveToPlayableManifest(url, raw, headers);
    if (resolved == null) return null;
    final segmentUrls = extractSegmentUrls(resolved.manifest, resolved.baseUrl);
    final rewritten = rewriteManifest(
      resolved.manifest,
      resolved.baseUrl,
      _segmentProxyUrlFor,
    );
    return _BuiltManifest(manifest: rewritten, segmentUrls: segmentUrls);
  }

  String _segmentProxyUrlFor(String absSegmentUrl) {
    final token = _tokenFor(absSegmentUrl);
    return 'http://127.0.0.1:$port/$_secret/seg/$token'
        '?u=${Uri.encodeComponent(absSegmentUrl)}';
  }

  /// 拉取清单文本。
  Future<String?> _fetchPlaylistText(
      String url, Map<String, String> headers) async {
    final client = _originClient();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(originConnectTimeout);
      headers.forEach(request.headers.set);
      final response =
          await request.close().timeout(originHeaderTimeout);
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      // 清单只有几 KB，但同样要有停表：慢滴流源站不得挂死清单请求
      await for (final chunk in response.timeout(originChunkTimeout)) {
        builder.add(chunk);
        if (builder.length > 2 * 1024 * 1024) break; // 防御异常大响应
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 若是主清单（多码率），跟进第一条子清单；返回可直接改写的清单与其 baseUrl。
  Future<_ResolvedManifest?> _resolveToPlayableManifest(
      String url, String manifest, Map<String, String> headers) async {
    final lines = manifest.split('\n');
    if (!lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'))) {
      return _ResolvedManifest(manifest: manifest, baseUrl: url);
    }
    String? childUriLine;
    for (var i = 0; i < lines.length && childUriLine == null; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final l = lines[j].trim();
        if (l.isNotEmpty && !l.startsWith('#')) {
          childUriLine = l;
          break;
        }
      }
    }
    if (childUriLine == null) return null;
    final childUrl = absolutizeUrl(childUriLine, url);
    if (childUrl == null) return null;
    final child = await _fetchPlaylistText(childUrl, headers);
    if (child == null) return null;
    return _ResolvedManifest(manifest: child, baseUrl: childUrl);
  }

  /// 改写清单：分片 → 代理 /seg/；KEY/MAP 的 URI → 绝对地址（mpv 直连）。
  String rewriteManifest(
    String manifest,
    String baseUrl,
    String Function(String absSegmentUrl) segmentUrlFor,
  ) {
    final out = <String>[];
    for (final rawLine in manifest.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        out.add('');
        continue;
      }
      if (line.startsWith('#')) {
        out.add(rewriteAttributeUris(line, baseUrl));
        continue;
      }
      final abs = absolutizeUrl(line, baseUrl);
      out.add(abs == null ? line : segmentUrlFor(abs));
    }
    return out.join('\n');
  }

  /// 清单中的分片绝对地址列表（预取用）。
  List<String> extractSegmentUrls(String manifest, String baseUrl) {
    final urls = <String>[];
    for (final rawLine in manifest.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final abs = absolutizeUrl(line, baseUrl);
      if (abs != null) urls.add(abs);
    }
    return urls;
  }

  /// EXT-X-KEY / EXT-X-MAP 行里的 URI 属性改为绝对地址。
  String rewriteAttributeUris(String line, String baseUrl) {
    if (!line.contains('URI="')) return line;
    return line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
      final abs = absolutizeUrl(m.group(1)!, baseUrl);
      return 'URI="${abs ?? m.group(1)}"';
    });
  }

  // ---------------------------------------------------------------------------
  // 元数据与缓存管理
  // ---------------------------------------------------------------------------

  Future<void> _writeMeta(String token, String url,
      Map<String, String> headers,
      {required bool isHls, int? total, List<String>? segTokens}) async {
    try {
      final meta = {
        'u': url,
        'h': headers,
        'hls': isHls ? 1 : 0,
        if (total != null) 't': total,
        if (segTokens != null && segTokens.isNotEmpty) 's': segTokens,
        'at': DateTime.now().millisecondsSinceEpoch,
      };
      await File('${_cacheDir!.path}/$token.meta')
          .writeAsString(json.encode(meta));
    } catch (_) {}
  }

  Future<_ProxyMeta?> _readMeta(String token) async {
    try {
      final file = File('${_cacheDir!.path}/$token.meta');
      if (!await file.exists()) return null;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return null;
      return _ProxyMeta(
        url: data['u'] as String? ?? '',
        total: (data['t'] as num?)?.toInt(),
        segTokens: (data['s'] as List?)
                ?.map((e) => e.toString())
                .toList(growable: false) ??
            const [],
      );
    } catch (_) {
      return null;
    }
  }

  /// LRU 清理：meta 条目数超限删最旧条目；目录总大小超限删最旧文件。
  Future<void> _evictIfNeeded() async {
    try {
      final dir = _cacheDir;
      if (dir == null) return;
      final metas = <_CacheEntryInfo>[];
      final allFiles = <_CacheEntryInfo>[];
      var totalBytes = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final stat = await entity.stat();
        totalBytes += stat.size;
        allFiles.add(_CacheEntryInfo(
            path: entity.path, lastAccess: stat.modified, size: stat.size));
        if (name.endsWith('.meta')) {
          metas.add(_CacheEntryInfo(
              path: entity.path,
              lastAccess: stat.modified,
              size: stat.size,
              token: name.substring(0, name.length - 5)));
        }
      }
      // 条目数超限：删最旧条目的 meta+bin
      if (metas.length > maxEntries) {
        metas.sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
        for (final victim
            in metas.take(metas.length - maxEntries)) {
          final token = victim.token!;
          for (final suffix in ['.meta', '.bin']) {
            final f = File('${dir.path}/$token$suffix');
            if (await f.exists()) {
              totalBytes -= f.lengthSync();
              await f.delete();
            }
          }
        }
      }
      // 总大小超限：从最旧文件开始删（保留 .meta 让条目仍可回源）
      if (totalBytes > maxTotalBytes) {
        allFiles.sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
        for (final victim in allFiles) {
          if (totalBytes <= maxTotalBytes) break;
          if (victim.path.endsWith('.meta')) continue;
          final f = File(victim.path);
          if (await f.exists()) {
            totalBytes -= victim.size;
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// 清空全部代理缓存（设置页入口）。
  Future<void> clearAll() async {
    try {
      final dir = _cacheDir;
      if (dir == null) return;
      await for (final entity in dir.list()) {
        await entity.delete(recursive: true);
      }
      _rewrittenManifests.clear();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  String? _srcFromQuery(HttpRequest request) {
    final raw = request.uri.queryParameters['u'];
    if (raw == null || raw.isEmpty) return null;
    return Uri.decodeComponent(raw);
  }

  /// 回源请求头：注册表里的源站头（Range 除外）为基底，
  /// mpv 请求带来的 UA / Referer 优先（与播放会话一致）。
  Map<String, String> _forwardHeaders(
      HttpRequest request, _ProxyRegistration? registration) {
    final headers = <String, String>{};
    registration?.headers.forEach((k, v) {
      if (k.toLowerCase() != 'range') headers[k] = v;
    });
    final ua = request.headers.value(HttpHeaders.userAgentHeader);
    if (ua != null && ua.isNotEmpty) headers['user-agent'] = ua;
    final referer = request.headers.value(HttpHeaders.refererHeader);
    if (referer != null && referer.isNotEmpty) {
      headers['referer'] = referer;
    }
    return headers;
  }

  ({int start, int? end})? _parseRange(String header) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final endStr = match.group(2);
    return (
      start: start,
      end: endStr == null || endStr.isEmpty ? null : int.parse(endStr)
    );
  }

  int? _totalFromContentRange(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final match = RegExp(r'/(\d+)\s*$').firstMatch(value);
    return match == null ? null : int.parse(match.group(1)!);
  }

  int? _totalFromContentLength(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentLengthHeader);
    if (value == null) return null;
    return int.tryParse(value);
  }

  /// 解析 Content-Range 的起始字节（"bytes N-M/T" 里的 N）。
  /// tee/追加写盘前用它校验上游确实从请求的偏移开始（B12）。
  int? _contentRangeStart(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-').firstMatch(value.trim());
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// 写入流到文件（封顶 [limit] 字节）。[mode] 默认截断；预取续拉
  /// 已有部分缓存时传 [FileMode.append]（B5：模式必须与请求的
  /// Range 起点匹配，否则追加语义错位会写坏缓存）。
  Future<void> _writeStreamLimited(
      File file, Stream<List<int>> stream, int limit,
      {FileMode mode = FileMode.write}) async {
    final sink = file.openWrite(mode: mode);
    var written = 0;
    try {
      await for (final chunk in stream) {
        if (written + chunk.length > limit) {
          final remaining = limit - written;
          if (remaining > 0) sink.add(chunk.sublist(0, remaining));
          break;
        }
        sink.add(chunk);
        written += chunk.length;
      }
      await sink.close();
    } catch (_) {
      await sink.close().catchError((_) {});
      rethrow;
    }
  }

  String _tokenFor(String url) {
    var h = 0x811c9dc5;
    for (var i = 0; i < url.length; i++) {
      h ^= url.codeUnitAt(i);
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }
}

/// 相对地址补全（对齐 Worker 端逻辑，抽成顶层函数便于单测）。
String? absolutizeUrl(String url, String base) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  try {
    return Uri.parse(base).resolve(trimmed).toString();
  } catch (_) {
    return null;
  }
}

class _ProxyRegistration {
  _ProxyRegistration({
    required this.url,
    required this.headers,
    required this.isHls,
  });

  final String url;
  final Map<String, String> headers;
  final bool isHls;
}

class _ProxyMeta {
  _ProxyMeta({required this.url, this.total, this.segTokens = const []});

  final String url;
  final int? total;

  /// HLS：已预取分片的 token 列表（判断缓存是否可用）。
  final List<String> segTokens;
}

class _ResolvedManifest {
  _ResolvedManifest({required this.manifest, required this.baseUrl});

  final String manifest;
  final String baseUrl;
}

class _BuiltManifest {
  _BuiltManifest({required this.manifest, required this.segmentUrls});

  final String manifest;
  final List<String> segmentUrls;
}

class _CacheEntryInfo {
  _CacheEntryInfo({
    required this.path,
    required this.lastAccess,
    required this.size,
    this.token,
  });

  final String path;
  final DateTime lastAccess;
  final int size;
  final String? token;
}
