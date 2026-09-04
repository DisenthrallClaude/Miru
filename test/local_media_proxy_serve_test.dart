// LocalMediaProxy 服务层集成测试（真实回环 socket）。
//
// v1.5.1 修复的「无 Range GET + 磁盘缓存 → 上游剩余字节全量读入内存
// （OOM/卡死）」在这里用真实 HttpServer 验证：源站慢慢吐 8MB，代理必须
// 在源站发完之前就开始给客户端回数据（流式），且字节完全正确。
//
// 其余场景：纯磁盘命中 / 有界跨界（mpv 重连形态）/ 开放区间合并 /
// 源站不理睬 Range 的退化透传 / hasUsableCache 阈值。
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';

/// 造一段确定性数据（byte i = i % 251），任何区间都能独立校验。
Uint8List patternBytes(int start, int length) {
  return Uint8List.fromList(
    List.generate(length, (i) => (start + i) % 251),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return '/tmp/miru_proxy_test';
    }
    return null;
  });

  late HttpServer origin;
  /// 源站分片节奏：每发一个 chunk 睡多久（模拟慢源站）。
  var originChunkDelay = const Duration(milliseconds: 0);
  /// 源站是否支持 Range（false = 一律 200 全量）。
  var originSupportsRange = true;

  final totalSize = 8 * 1024 * 1024; // 8MB 假视频

  setUpAll(() async {
    await Hive.initFlutter('/tmp/miru_proxy_test/hive');
    await GStorage.init();
    await GStorage.putSetting<bool>(
        SettingsKeys.localMediaCacheEnable, true);

    // ---- 假源站：确定性 8MB「视频」，支持 Range ----
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final match =
          rangeHeader != null ? RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader) : null;
      final start = match != null ? int.parse(match.group(1)!) : 0;
      final end = match != null && (match.group(2) ?? '').isNotEmpty
          ? int.parse(match.group(2)!)
          : totalSize - 1;
      final useRange = originSupportsRange && match != null;
      if (useRange) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$totalSize');
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      final length = (useRange ? end : totalSize - 1) - start + 1;
      request.response.contentLength = length;
      // 慢慢发：64KB 一个 chunk
      const chunkSize = 64 * 1024;
      var sent = 0;
      while (sent < length) {
        final n = sent + chunkSize > length ? length - sent : chunkSize;
        request.response.add(patternBytes(start + sent, n));
        await request.response.flush();
        sent += n;
        if (originChunkDelay.inMilliseconds > 0) {
          await Future<void>.delayed(originChunkDelay);
        }
      }
      await request.response.close();
    });
  });

  String originUrl(String path) =>
      'http://127.0.0.1:${origin.port}$path';

  /// 读完整响应体。
  Future<(int, List<int>)> readBody(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (response.statusCode, builder.takeBytes());
  }

  test('开放区间+总长未知：不报假 total，透传学总长', () async {
    final url = originUrl('/stream-unknown-total.mp4');
    await LocalMediaProxy.instance
        .prefetch(url, isHls: false, headers: const {});
    // 删掉 meta 模拟「有缓存数据但总长未知」（prefetch 没跑成、
    // 只有 tee 写过盘的场景）。§2.2(c) 缓存目录随实现迁到
    // getApplicationSupportDirectory（上方 mock → /tmp/miru_proxy_test）。
    final cacheDir = Directory('/tmp/miru_proxy_test/media_cache');
    final metaFile = File('${cacheDir.path}/${fnvToken(url)}.meta');
    expect(await metaFile.exists(), isTrue,
        reason: 'prefetch 应已写入 meta');
    await metaFile.delete();

    final proxyUrl = (await LocalMediaProxy.instance
        .register(url, isHls: false, headers: const {}))!;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(proxyUrl));
      // 不带 Range：不允许出现「假 total」截断（v1.5.1 复查发现的问题）
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final (_, body) = await readBody(response);
      expect(body.length, totalSize);
      expect(body, equals(patternBytes(0, totalSize)));
    } finally {
      client.close(force: true);
    }
    // 透传应已把总长学回 meta（下一次就能走磁盘合并加速）
    expect(await metaFile.exists(), isTrue);
  });

  tearDownAll(() async {
    await origin.close(force: true);
    await LocalMediaProxy.instance.shutdown();
  });

  test('无 Range GET + 已有缓存：流式转发（不整段缓冲）', () async {
    originChunkDelay = const Duration(milliseconds: 12);
    final url = originUrl('/stream-oom.mp4');
    // 预取 4MB（同时落 cache 文件 + meta total）
    await LocalMediaProxy.instance
        .prefetch(url, isHls: false, headers: const {});
    final proxyUrl = await LocalMediaProxy.instance
        .register(url, isHls: false, headers: const {});
    expect(proxyUrl, isNotNull);

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(proxyUrl!));
      // 关键：不带 Range（mpv 首个 GET 的形态，v1.5.0 的 OOM 路径）
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final contentRange =
          response.headers.value(HttpHeaders.contentRangeHeader);
      expect(contentRange, 'bytes 0-${totalSize - 1}/$totalSize');

      // 边收边校验时间：源站 4MB 上游部分全发完需要 ~800ms+；
      // 首块必须在 700ms 内到达（旧实现会等全部上游字节收完才回第一个字节）
      var received = 0;
      final firstChunkAt = Stopwatch()..start();
      var firstChunkElapsedMs = -1;
      await for (final chunk in response) {
        if (firstChunkElapsedMs < 0) {
          firstChunkElapsedMs = firstChunkAt.elapsedMilliseconds;
        }
        // 逐段校验字节
        final expected = patternBytes(received, chunk.length);
        expect(chunk, equals(expected), reason: 'offset $received 处字节错误');
        received += chunk.length;
      }
      expect(firstChunkElapsedMs,
          greaterThanOrEqualTo(0), reason: '没有收到任何数据');
      expect(firstChunkElapsedMs,
          lessThan(700), reason: '首块延迟过高，疑似整段缓冲');
      expect(received, totalSize);
    } finally {
      client.close(force: true);
      originChunkDelay = const Duration(milliseconds: 0);
    }
  });

  test('有界区间整段命中缓存：源站宕机也能回磁盘数据', () async {
    final url = originUrl('/stream-diskhit.mp4');
    await LocalMediaProxy.instance
        .prefetch(url, isHls: false, headers: const {});
    final proxyUrl = (await LocalMediaProxy.instance
        .register(url, isHls: false, headers: const {}))!;

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(proxyUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=100-100199');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 100-100199/$totalSize');
      final (status, body) = await readBody(response);
      expect(status, HttpStatus.partialContent);
      expect(body.length, 100100);
      expect(body, equals(patternBytes(100, 100100)));
    } finally {
      client.close(force: true);
    }
  });

  test('有界区间越过缓存边界：只回磁盘部分（mpv 短读重连形态）', () async {
    final url = originUrl('/stream-crossing.mp4');
    await LocalMediaProxy.instance
        .prefetch(url, isHls: false, headers: const {});
    final proxyUrl = (await LocalMediaProxy.instance
        .register(url, isHls: false, headers: const {}))!;
    final cachedLen = LocalMediaProxy.mp4PrefetchBytes; // 4MB

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(proxyUrl));
      // 请求 0..7MB，但只有 4MB 在缓存里
      request.headers
          .set(HttpHeaders.rangeHeader, 'bytes=0-${totalSize - 1}');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      // 只回磁盘部分：0..cachedLen-1
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-${cachedLen - 1}/$totalSize');
      final (_, body) = await readBody(response);
      expect(body.length, cachedLen);
      expect(body, equals(patternBytes(0, cachedLen)));
    } finally {
      client.close(force: true);
    }
  });

  test('源站不理睬 Range（200 全量）：从 0 请求退化为透传', () async {
    originSupportsRange = false;
    try {
      final url = originUrl('/stream-norange.mp4');
      final proxyUrl = (await LocalMediaProxy.instance
          .register(url, isHls: false, headers: const {}))!;

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        // 无 Range 请求：透传 200 全量
        expect(response.statusCode, HttpStatus.ok);
        final (_, body) = await readBody(response);
        expect(body.length, totalSize);
        expect(body, equals(patternBytes(0, totalSize)));
      } finally {
        client.close(force: true);
      }
    } finally {
      originSupportsRange = true;
    }
  });

  test('hasUsableCache：MP4 阈值与未缓存判定', () async {
    final cached = originUrl('/usable-cached.mp4');
    final empty = originUrl('/usable-empty.mp4');
    await LocalMediaProxy.instance
        .prefetch(cached, isHls: false, headers: const {});

    expect(
        await LocalMediaProxy.instance
            .hasUsableCache(cached, isHls: false),
        isTrue);
    expect(
        await LocalMediaProxy.instance
            .hasUsableCache(empty, isHls: false),
        isFalse);
  });

  test('缓存外的顺序请求：透传 + tee 落盘', () async {
    final url = originUrl('/stream-tee.mp4');
    final proxyUrl = (await LocalMediaProxy.instance
        .register(url, isHls: false, headers: const {}))!;

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(proxyUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final (_, body) = await readBody(response);
      expect(body, equals(patternBytes(0, totalSize)));
    } finally {
      client.close(force: true);
    }
    // tee 之后缓存文件应该有开头 4MB
    expect(
        await LocalMediaProxy.instance.hasUsableCache(url, isHls: false),
        isTrue);
  });
}

/// 与 LocalMediaProxy._tokenFor 相同的 sha1 前 10 字节 hex（§2.2(b)，
/// 测试用镜像；旧 FNV 已随碰撞风险升级而替换）。
String fnvToken(String url) {
  final digest = sha1.convert(utf8.encode(url));
  return digest.bytes
      .take(10)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}
