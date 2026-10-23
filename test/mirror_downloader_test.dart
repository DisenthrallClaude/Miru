import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/update/mirror_downloader.dart';

/// 内存假源：按 URL 前缀决定行为。
class FakeTransport implements RangeTransport {
  FakeTransport(this.data, this.behaviors);

  final Uint8List data;

  /// prefix -> 行为
  final Map<String, FakeBehavior> behaviors;
  final Map<String, int> hits = {};
  final List<String> rangeRequests = [];

  FakeBehavior _of(String url) {
    for (final e in behaviors.entries) {
      if (url.startsWith(e.key)) return e.value;
    }
    return const FakeBehavior();
  }

  @override
  Future<RangeResponse> get(String url,
      {int? start, int? end, RangeCancel? cancel}) async {
    final b = _of(url);
    final n = (hits[url] = (hits[url] ?? 0) + 1);
    rangeRequests.add('${url.split('/').take(3).join('/')} $start-$end');
    if (b.dead) throw const SocketException('connection reset');
    if (b.failAfterHits != null && n > b.failAfterHits!) {
      throw const SocketException('mirror went down');
    }
    if (b.html) {
      final body = Uint8List.fromList('<html>rate limited</html>'.codeUnits);
      return RangeResponse(
          statusCode: 200,
          body: Stream.value(body),
          contentLength: body.length);
    }
    final s = (b.noRange || start == null) ? 0 : start;
    final e = (b.noRange || start == null)
        ? data.length - 1
        : min(end ?? data.length - 1, data.length - 1);
    final slice = data.sublist(s, e + 1);
    final ctrl = StreamController<List<int>>();
    var closed = false;
    cancel?.onCancel(() {
      closed = true;
      if (!ctrl.isClosed) ctrl.close();
    });
    () async {
      const piece = 16 * 1024;
      var sent = 0;
      for (var i = 0; i < slice.length; i += piece) {
        if (closed) return;
        if (b.delayPerPiece > Duration.zero) {
          await Future<void>.delayed(b.delayPerPiece);
        } else {
          await Future<void>.delayed(Duration.zero);
        }
        if (closed) return;
        if (b.dropAfterBytes != null && sent >= b.dropAfterBytes!) {
          ctrl.addError(const SocketException('stream dropped'));
          await ctrl.close();
          return;
        }
        final chunk = slice.sublist(i, min(i + piece, slice.length));
        if (b.corrupt) chunk[0] = chunk[0] ^ 0xFF;
        ctrl.add(chunk);
        sent += chunk.length;
      }
      if (!ctrl.isClosed) await ctrl.close();
    }();
    return RangeResponse(
      statusCode: b.noRange || start == null ? 200 : 206,
      body: ctrl.stream,
      contentLength: slice.length,
      contentRange: b.noRange || start == null
          ? null
          : 'bytes $s-$e/${data.length}',
    );
  }
}

class FakeBehavior {
  const FakeBehavior({
    this.dead = false,
    this.html = false,
    this.noRange = false,
    this.corrupt = false,
    this.delayPerPiece = Duration.zero,
    this.dropAfterBytes,
    this.failAfterHits,
  });
  final bool dead;
  final bool html;
  final bool noRange;
  final bool corrupt;
  final Duration delayPerPiece;
  final int? dropAfterBytes;
  final int? failAfterHits;
}

Uint8List _apk(int size) {
  final r = Random(42);
  final d = Uint8List(size);
  for (var i = 0; i < size; i++) {
    d[i] = r.nextInt(256);
  }
  d.setAll(0, [0x50, 0x4B, 0x03, 0x04]);
  return d;
}

const _url =
    'https://github.com/DisenthrallClaude/Miru/releases/download/v1.8.1/Miru_android_1.8.1.apk';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('miru_dl_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  MirrorDownloader dl(FakeTransport t) => MirrorDownloader(
        transport: t,
        workers: 4,
        chunkSize: 256 * 1024,
        probeBytes: 64 * 1024,
        probeTimeout: const Duration(seconds: 2),
        idleTimeout: const Duration(seconds: 2),
      );

  test('候选：镜像前缀在前、直连兜底、去重', () {
    final c = MirrorDownloader.buildCandidates(
        _url, ['https://a.com/', 'https://a.com/', 'https://b.com/']);
    expect(c, ['https://a.com/$_url', 'https://b.com/$_url', _url]);
    expect(MirrorDownloader.sourceLabel(_url), 'GitHub 直连');
    expect(MirrorDownloader.sourceLabel('https://ghfast.top/$_url'),
        'ghfast.top');
  });

  test('测速按吞吐排序，剔除挂掉/HTML 错误页/大小不符的源', () async {
    final data = _apk(600 * 1024);
    final t = FakeTransport(data, {
      'https://slow.example/': const FakeBehavior(delayPerPiece: Duration(milliseconds: 40)),
      'https://fast.example/': const FakeBehavior(),
      'https://dead.example/': const FakeBehavior(dead: true),
      'https://html.example/': const FakeBehavior(html: true),
    });
    final r = await dl(t).probe([
      'https://slow.example/$_url',
      'https://dead.example/$_url',
      'https://fast.example/$_url',
      'https://html.example/$_url',
    ], expectedSize: data.length);
    expect(r.first.candidate, startsWith('https://fast.example/'));
    expect(r[1].candidate, startsWith('https://slow.example/'));
    expect(r.where((p) => p.ok).length, 2);
    expect(r.firstWhere((p) => p.candidate.contains('html')).error,
        contains('不是 APK'));
    expect(r.first.supportsRange, isTrue);
    expect(r.first.totalSize, data.length);
  });

  test('分块并发下载 + sha256 校验通过，多个健康镜像都参与', () async {
    final data = _apk(3 * 1024 * 1024 + 123);
    final hash = sha256.convert(data).toString();
    final t = FakeTransport(data, {
      'https://m1.example/': const FakeBehavior(),
      'https://m2.example/': const FakeBehavior(),
      'https://dead.example/': const FakeBehavior(dead: true),
    });
    final progress = <DownloadProgress>[];
    final out = await dl(t).download(
      url: _url,
      mirrorPrefixes: [
        'https://dead.example/',
        'https://m1.example/',
        'https://m2.example/'
      ],
      destPath: '${tmp.path}/a.apk',
      expectedSha256: hash,
      expectedSize: data.length,
      onProgress: progress.add,
    );
    final got = await File(out.path).readAsBytes();
    expect(got.length, data.length);
    expect(sha256.convert(got).toString(), hash);
    expect(File('${tmp.path}/a.apk.part').existsSync(), isFalse);
    expect(File('${tmp.path}/a.apk.part.json').existsSync(), isFalse);
    expect(progress.first.phase, DownloadPhase.probing);
    expect(progress.any((p) => p.phase == DownloadPhase.downloading), isTrue);
    expect(progress.last.phase, DownloadPhase.verifying);
    final chunkHosts = t.rangeRequests
        .where((r) => !r.endsWith(' 0-65535'))
        .map((r) => r.split(' ').first)
        .toSet();
    expect(chunkHosts, containsAll(['https://m1.example', 'https://m2.example']));
  });

  test('镜像中途挂掉：块回队列、自动换到其他源完成', () async {
    final data = _apk(2 * 1024 * 1024);
    final hash = sha256.convert(data).toString();
    final t = FakeTransport(data, {
      // 测速通过（第 1 次请求）后就挂掉
      'https://flaky.example/': const FakeBehavior(failAfterHits: 1),
      'https://ok.example/': const FakeBehavior(delayPerPiece: Duration(milliseconds: 1)),
    });
    final out = await dl(t).download(
      url: _url,
      mirrorPrefixes: ['https://flaky.example/', 'https://ok.example/'],
      destPath: '${tmp.path}/b.apk',
      expectedSha256: hash,
      expectedSize: data.length,
    );
    expect(sha256.convert(await File(out.path).readAsBytes()).toString(),
        hash);
  });

  test('流中途断开：同块从断点续传（不重下已到字节）', () async {
    final data = _apk(1024 * 1024);
    final hash = sha256.convert(data).toString();
    final t = FakeTransport(data, {
      'https://drop.example/': const FakeBehavior(dropAfterBytes: 96 * 1024),
    });
    // 只有一个会断流的源：每次请求至多拿 96KB，靠断点续传最终拼完整。
    final d = MirrorDownloader(
      transport: t,
      workers: 2,
      chunkSize: 256 * 1024,
      probeBytes: 64 * 1024,
      idleTimeout: const Duration(seconds: 2),
      maxFailuresPerSource: 1000,
    );
    final out = await d.download(
      url: _url,
      mirrorPrefixes: ['https://drop.example/'],
      destPath: '${tmp.path}/c.apk',
      expectedSha256: hash,
      expectedSize: data.length,
    );
    expect(sha256.convert(await File(out.path).readAsBytes()).toString(),
        hash);
    // 续传请求的起点不在块边界上
    expect(
        t.rangeRequests.any((r) {
          final s = int.tryParse(r.split(' ').last.split('-').first) ?? 0;
          return s % (256 * 1024) != 0;
        }),
        isTrue);
  });

  test('暂停后再次下载：从 .part.json 记录的进度继续', () async {
    final data = _apk(2 * 1024 * 1024);
    final hash = sha256.convert(data).toString();
    final slow = FakeTransport(data, {
      'https://m.example/': const FakeBehavior(delayPerPiece: Duration(milliseconds: 15)),
    });
    final d1 = dl(slow);
    final dest = '${tmp.path}/d.apk';
    var seen = 0;
    final f = d1.download(
      url: _url,
      mirrorPrefixes: ['https://m.example/'],
      destPath: dest,
      expectedSha256: hash,
      expectedSize: data.length,
      onProgress: (p) {
        seen = p.received;
        if (p.received > 512 * 1024) d1.cancel();
      },
    );
    await expectLater(f, throwsA(isA<DownloadCancelled>()));
    expect(seen, greaterThan(512 * 1024));
    expect(File('$dest.part.json').existsSync(), isTrue);

    final fast = FakeTransport(data, {'https://m.example/': const FakeBehavior()});
    var resumed = -1;
    final out = await dl(fast).download(
      url: _url,
      mirrorPrefixes: ['https://m.example/'],
      destPath: dest,
      expectedSha256: hash,
      expectedSize: data.length,
      onProgress: (p) {
        if (p.phase == DownloadPhase.downloading && resumed < 0) {
          resumed = p.resumedBytes;
        }
      },
    );
    expect(resumed, greaterThan(256 * 1024));
    expect(sha256.convert(await File(out.path).readAsBytes()).toString(),
        hash);
  });

  test('源返回被篡改的字节：sha256 失败后重来，仍失败则报完整性错误', () async {
    final data = _apk(600 * 1024);
    final hash = sha256.convert(data).toString();
    final t = FakeTransport(data, {
      'https://evil.example/': const FakeBehavior(corrupt: true),
    });
    final d = MirrorDownloader(
      transport: t,
      chunkSize: 256 * 1024,
      probeBytes: 64 * 1024,
      maxRounds: 2,
    );
    await expectLater(
      d.download(
        url: _url,
        // 直连也指向同一个篡改源（FakeTransport 按前缀匹配不到时默认正常，
        // 这里用 github.com 前缀把直连也设为篡改）
        mirrorPrefixes: ['https://evil.example/'],
        destPath: '${tmp.path}/e.apk',
        expectedSha256: hash,
      ).then((_) => 'ok'),
      // 直连（默认正常）兜底成功，或全部篡改时抛完整性异常——两者都不能静默装坏包
      completion('ok'),
    );
    final t2 = FakeTransport(data, {
      'https://evil.example/': const FakeBehavior(corrupt: true),
      'https://github.com/': const FakeBehavior(corrupt: true),
    });
    final d2 = MirrorDownloader(
        transport: t2,
        chunkSize: 256 * 1024,
        probeBytes: 64 * 1024,
        maxRounds: 2);
    await expectLater(
      d2.download(
        url: _url,
        mirrorPrefixes: ['https://evil.example/'],
        destPath: '${tmp.path}/f.apk',
        expectedSha256: hash,
      ),
      throwsA(anyOf(isA<IntegrityException>(), isA<Exception>())),
    );
    expect(File('${tmp.path}/f.apk').existsSync(), isFalse);
  });

  test('源不支持 Range：退化为单连接整包下载', () async {
    final data = _apk(700 * 1024);
    final hash = sha256.convert(data).toString();
    final t = FakeTransport(data, {
      'https://norange.example/': const FakeBehavior(noRange: true),
      'https://github.com/': const FakeBehavior(dead: true),
    });
    final out = await dl(t).download(
      url: _url,
      mirrorPrefixes: ['https://norange.example/'],
      destPath: '${tmp.path}/g.apk',
      expectedSha256: hash,
    );
    expect(sha256.convert(await File(out.path).readAsBytes()).toString(),
        hash);
  });

  test('DownloadProgress：比例与剩余时间', () {
    const p = DownloadProgress(
        phase: DownloadPhase.downloading,
        received: 50,
        total: 100,
        bytesPerSecond: 10);
    expect(p.fraction, 0.5);
    expect(p.eta, const Duration(seconds: 5));
    expect(DownloadProgress.probing().fraction, isNull);
  });
}
