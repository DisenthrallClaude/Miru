import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/sync/github_api.dart';

/// 用内存 HttpClientAdapter 模拟 GitHub REST API，
/// 覆盖云同步客户端的关键分支：认证、404 语义、乐观锁冲突重试。
class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }
}

ResponseBody _json(Object body, int status) {
  return ResponseBody.fromString(
    body is String ? body : jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  group('GithubApi.getUser', () {
    test('有效 Token 返回用户信息', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({
          'login': 'alice',
          'avatar_url': 'https://example.com/a.png',
          'html_url': 'https://github.com/alice',
        }, 200);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final user = await api.getUser();
      expect(user.login, 'alice');
      expect(user.avatarUrl, 'https://example.com/a.png');
    });

    test('401 抛认证异常', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({'message': 'Bad credentials'}, 401);
      });
      final api = GithubApi.forTesting(token: 'bad', dio: dio);
      await expectLater(
        api.getUser(),
        throwsA(isA<GithubAuthException>()),
      );
    });
  });

  group('GithubApi 404 语义', () {
    test('readFile 404 返回 null（文件不存在是正常态）', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({'message': 'Not Found'}, 404);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final file = await api.readFile(
        owner: 'alice',
        repo: 'miru-sync',
        path: 'data/history/snapshot.json',
      );
      expect(file, isNull);
    });

    test('listDir 404 返回空列表（空目录与缺失目录同义）', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({'message': 'Not Found'}, 404);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final entries = await api.listDir(
        owner: 'alice',
        repo: 'miru-sync',
        path: 'data/history/changes',
      );
      expect(entries, isEmpty);
    });

    test('getRepo 404 返回 null（仓库不存在时引导创建）', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({'message': 'Not Found'}, 404);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final repo = await api.getRepo(owner: 'alice', repo: 'miru-sync');
      expect(repo, isNull);
    });
  });

  group('GithubApi.putFileWithRetry', () {
    test('sha 过期触发一次重试后成功', () async {
      var putCalls = 0;
      var headCalls = 0;
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.method == 'GET') {
          headCalls++;
          return _json({
            'sha': 'sha-$headCalls',
            'size': 10,
            'name': 'snapshot.json',
          }, 200);
        }
        putCalls++;
        if (putCalls == 1) {
          // 第一次 PUT 用过期 sha → 422 冲突。
          return _json({
            'message': 'sha does not match current file state',
          }, 422);
        }
        return _json({
          'content': {'sha': 'new-sha'},
        }, 200);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final sha = await api.putFileWithRetry(
        owner: 'alice',
        repo: 'miru-sync',
        path: 'data/history/snapshot.json',
        message: 'miru: history snapshot',
        bytes: [1, 2, 3],
      );
      expect(sha, 'new-sha');
      expect(putCalls, 2, reason: '冲突后应重试一次');
      expect(headCalls, 2, reason: '重试前应重新获取 sha');
    });

    test('无冲突时单次写入成功', () async {
      var putCalls = 0;
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.method == 'GET') {
          return _json({'sha': 'base-sha', 'size': 10}, 200);
        }
        putCalls++;
        return _json({
          'content': {'sha': 'ok-sha'},
        }, 200);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      final sha = await api.putFileWithRetry(
        owner: 'alice',
        repo: 'miru-sync',
        path: 'data/collectibles.tmp',
        message: 'miru: collectibles backup',
        bytes: [9, 9],
      );
      expect(sha, 'ok-sha');
      expect(putCalls, 1);
    });
  });

  group('GithubApi.deleteFile', () {
    test('文件不存在时幂等成功', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.github.com',
        // 与 GithubApi._createDio 保持一致: 4xx 不在 dio 层抛出,
        // 留给客户端代码按语义分流(404=不存在, 401=认证失败, 422=冲突)。
        validateStatus: (status) => status != null && status < 500,
      ));
      dio.httpClientAdapter = _MockAdapter((options) async {
        return _json({'message': 'Not Found'}, 404);
      });
      final api = GithubApi.forTesting(token: 't', dio: dio);
      await api.deleteFile(
        owner: 'alice',
        repo: 'miru-sync',
        path: 'data/history/changes/dev1.jsonl',
        message: 'miru: cleanup',
      );
    });
  });

  group('describeGithubError', () {
    test('网络异常转成友好文案', () {
      final message = describeGithubError(
        DioException.connectionTimeout(
          requestOptions: RequestOptions(path: '/x'),
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(message, contains('网络'));
    });

    test('认证异常原样透出', () {
      final message =
          describeGithubError(GithubAuthException('Token 无效或已过期'));
      expect(message, 'Token 无效或已过期');
    });
  });
}
