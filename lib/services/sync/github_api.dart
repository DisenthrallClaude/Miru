import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/request/core/network_error_mapper.dart';
import 'package:miru/request/core/network_exception.dart';
import 'package:miru/services/logging/logger.dart';

/// GitHub REST API 客户端（v3，Personal Access Token 认证）。
///
/// 仅覆盖云同步所需的最小接口面：
/// - 身份验证（GET /user）
/// - 仓库探测与创建（GET/POST /repos、/user/repos）
/// - 文件读写（Contents API，PUT 携带 sha 做乐观锁）
///
/// 认证边界（如实告知用户）：GitHub 自 2020/2021 年起废弃了第三方
/// 「账号 + 密码」直登通道，本客户端因此只接受 Personal Access Token，
/// 不做任何模拟登录表单的尝试。
class GithubApi {
  GithubApi({required this.token}) : _dio = _createDio(token);

  static const String _baseUrl = 'https://api.github.com';

  final String token;
  final Dio _dio;

  /// 走统一网络工厂（F10）：此前自建 Dio 绕过了用户代理设置，
  /// 国内直连 api.github.com 基本不可达（GitHub 同步在目标用户群
  /// 大概率不可用），且无重试、无统一错误映射。
  /// 现在：读用户代理设置（手动代理/Windows 系统代理）、统一超时、
  /// 幂等 GET 单次自动重试；4xx 仍正常返回供语义分流。
  static Dio _createDio(String token) {
    return DioFactory.createDio(
      baseUrl: _baseUrl,
      defaultHeaders: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        // GitHub 强制要求 User-Agent，否则 403。
        'User-Agent': 'Miru-App',
      },
      validateStatus: (status) => status != null && status < 500,
    );
  }

  /// 网络层异常统一映射（F10）：连接/超时/5xx → NetworkException
  /// （含中文文案）；GitHub 语义异常（401/404/409/422）在业务层抛出，
  /// 不经过这里。
  Future<Response<T>> _get<T>(String path, {Options? options}) async {
    try {
      return await _dio.get<T>(path, options: options);
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<Response<T>> _post<T>(String path, {Object? data}) async {
    try {
      return await _dio.post<T>(path, data: data);
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<Response<T>> _put<T>(String path, {Object? data}) async {
    try {
      return await _dio.put<T>(path, data: data);
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<Response<T>> _delete<T>(String path, {Object? data}) async {
    try {
      return await _dio.delete<T>(path, data: data);
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  GithubApi._withDio(this.token, this._dio);

  /// 测试专用：允许注入自定义 Dio。
  factory GithubApi.forTesting({
    required String token,
    required Dio dio,
  }) {
    return GithubApi._withDio(token, dio);
  }

  /// 读取远端文件内容。文件不存在返回 null。
  /// 使用 raw Accept 头直接拿原始字节，绕开 Contents API 的 1MB base64 限制。
  Future<GithubRemoteFile?> readFile({
    required String owner,
    required String repo,
    required String path,
  }) async {
    final response = await _get<String>(
      '/repos/$owner/$repo/contents/$path',
      options: Options(
        headers: {'Accept': 'application/vnd.github.raw'},
        responseType: ResponseType.plain,
      ),
    );
    if (response.statusCode == 404) {
      return null;
    }
    _throwIfFailed(response, '读取文件 $path');
    return GithubRemoteFile(
      content: utf8.encode(response.data ?? ''),
      // raw 响应不带 sha；需要 sha 的写路径会单独走 headFile()。
      sha: null,
    );
  }

  /// 获取文件的元信息（sha、大小）。文件不存在返回 null。
  Future<GithubFileMeta?> headFile({
    required String owner,
    required String repo,
    required String path,
  }) async {
    final response = await _get<dynamic>(
      '/repos/$owner/$repo/contents/$path',
    );
    if (response.statusCode == 404) {
      return null;
    }
    _throwIfFailed(response, '获取文件信息 $path');
    final data = (response.data is Map)
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    return GithubFileMeta(
      sha: data['sha'] as String?,
      size: (data['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 列出目录下的文件名。目录不存在（GitHub 对空/缺失目录一律 404）
  /// 视为空目录，返回空列表。
  Future<List<GithubFileMeta>> listDir({
    required String owner,
    required String repo,
    required String path,
  }) async {
    final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final response = await _get<dynamic>(
      '/repos/$owner/$repo/contents/$normalized',
    );
    if (response.statusCode == 404) {
      return const [];
    }
    _throwIfFailed(response, '列出目录 $normalized');
    final data = response.data;
    if (data is! List) {
      // 路径指向单个文件时返回对象而非数组。
      return const [];
    }
    return data
        .map((entry) => GithubFileMeta(
              sha: (entry as Map)['sha'] as String?,
              name: entry['name'] as String?,
              size: (entry['size'] as num?)?.toInt() ?? 0,
            ))
        .where((entry) => entry.name != null)
        .toList();
  }

  /// 写入文件（创建或覆盖）。
  /// [sha] 为已存在文件的 sha（更新时必须携带）；省略时为创建。
  /// 返回提交后的新 sha。
  Future<String> putFile({
    required String owner,
    required String repo,
    required String path,
    required String message,
    required List<int> bytes,
    String? sha,
  }) async {
    final body = <String, dynamic>{
      'message': message,
      'content': base64Encode(bytes),
    };
    if (sha != null) {
      body['sha'] = sha;
    }
    final response = await _put<dynamic>(
      '/repos/$owner/$repo/contents/$path',
      data: body,
    );
    if (response.statusCode == 422 || response.statusCode == 409) {
      throw GithubConflictException(
        '文件 $path 写入冲突（sha 过期或仓库状态变化）',
      );
    }
    _throwIfFailed(response, '写入文件 $path');
    final data = (response.data is Map)
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    final content = data['content'];
    if (content is Map) {
      return content['sha'] as String? ?? '';
    }
    return '';
  }

  /// 带一次重试的写入：409/422 冲突时重新取 sha 再提交一次。
  Future<String> putFileWithRetry({
    required String owner,
    required String repo,
    required String path,
    required String message,
    required List<int> bytes,
  }) async {
    final meta = await headFile(owner: owner, repo: repo, path: path);
    try {
      return await putFile(
        owner: owner,
        repo: repo,
        path: path,
        message: message,
        bytes: bytes,
        sha: meta?.sha,
      );
    } on GithubConflictException {
      final fresh = await headFile(owner: owner, repo: repo, path: path);
      return await putFile(
        owner: owner,
        repo: repo,
        path: path,
        message: message,
        bytes: bytes,
        sha: fresh?.sha,
      );
    }
  }

  /// 删除文件。文件不存在时静默成功（幂等）。
  Future<void> deleteFile({
    required String owner,
    required String repo,
    required String path,
    required String message,
  }) async {
    final meta = await headFile(owner: owner, repo: repo, path: path);
    if (meta == null) {
      return;
    }
    final response = await _delete<dynamic>(
      '/repos/$owner/$repo/contents/$path',
      data: {'message': message, 'sha': meta.sha},
    );
    if (response.statusCode == 404) {
      return;
    }
    _throwIfFailed(response, '删除文件 $path');
  }

  /// 获取当前 Token 持有者信息。Token 无效抛 [GithubAuthException]。
  Future<GithubUser> getUser() async {
    final response = await _get<dynamic>('/user');
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GithubAuthException('Token 无效或已过期');
    }
    _throwIfFailed(response, '获取用户信息');
    final data = Map<String, dynamic>.from(response.data as Map);
    return GithubUser(
      login: data['login'] as String? ?? '',
      avatarUrl: data['avatar_url'] as String? ?? '',
      htmlUrl: data['html_url'] as String? ?? '',
    );
  }

  /// 探测仓库是否可访问（对私有仓库同样有效）。
  Future<GithubRepoInfo?> getRepo({
    required String owner,
    required String repo,
  }) async {
    final response = await _get<dynamic>('/repos/$owner/$repo');
    if (response.statusCode == 404) {
      return null;
    }
    _throwIfFailed(response, '获取仓库信息');
    final data = Map<String, dynamic>.from(response.data as Map);
    return GithubRepoInfo(
      fullName: data['full_name'] as String? ?? '',
      isPrivate: data['private'] as bool? ?? false,
      htmlUrl: data['html_url'] as String? ?? '',
    );
  }

  /// 在当前账号下创建私有仓库。
  /// 注意：fine-grained PAT 若未授予 Administration 写权限会失败，
  /// 失败时引导用户手动在网页上创建。
  Future<GithubRepoInfo> createPrivateRepo({required String name}) async {
    final response = await _post<dynamic>(
      '/user/repos',
      data: {
        'name': name,
        'private': true,
        'description': 'Miru 云同步数据（自动创建）',
        'auto_init': false,
      },
    );
    if (response.statusCode == 422) {
      throw GithubConflictException('仓库 $name 已存在或名称不合法');
    }
    _throwIfFailed(response, '创建仓库 $name');
    final data = Map<String, dynamic>.from(response.data as Map);
    return GithubRepoInfo(
      fullName: data['full_name'] as String? ?? '',
      isPrivate: data['private'] as bool? ?? false,
      htmlUrl: data['html_url'] as String? ?? '',
    );
  }

  void _throwIfFailed(Response response, String action) {
    if (response.statusCode == null || response.statusCode! >= 400) {
      final code = response.statusCode;
      if (code == 401) {
        throw GithubAuthException('Token 无效或已过期（$action）');
      }
      if (code == 403) {
        // 403 既可能是权限不足也可能是限流，从响应体里尽量区分。
        final message = _extractMessage(response.data);
        throw GithubAuthException('GitHub 拒绝访问（$action）：$message');
      }
      if (code == 404) {
        throw GithubNotFoundException('GitHub 资源不存在（$action）');
      }
      throw GithubApiException('GitHub API 失败（$action）HTTP $code：'
          '${_extractMessage(response.data)}');
    }
  }

  String _extractMessage(Object? data) {
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return data?.toString() ?? '';
  }

  void dispose() {
    _dio.close();
  }
}

class GithubUser {
  const GithubUser({
    required this.login,
    required this.avatarUrl,
    required this.htmlUrl,
  });

  final String login;
  final String avatarUrl;
  final String htmlUrl;
}

class GithubRepoInfo {
  const GithubRepoInfo({
    required this.fullName,
    required this.isPrivate,
    required this.htmlUrl,
  });

  final String fullName;
  final bool isPrivate;
  final String htmlUrl;
}

class GithubRemoteFile {
  GithubRemoteFile({required this.content, this.sha});

  final Uint8List content;
  final String? sha;
}

class GithubFileMeta {
  GithubFileMeta({this.sha, this.name, this.size = 0});

  final String? sha;
  final String? name;
  final int size;
}

/// Token 无效/权限不足/限流。
class GithubAuthException implements Exception {
  GithubAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 乐观锁冲突（sha 过期）。
class GithubConflictException implements Exception {
  GithubConflictException(this.message);
  final String message;

  @override
  String toString() => message;
}

class GithubNotFoundException implements Exception {
  GithubNotFoundException(this.message);
  final String message;

  @override
  String toString() => message;
}

class GithubApiException implements IOException {
  GithubApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 日志辅助：统一异常文案。
String describeGithubError(Object error) {
  if (error is NetworkException) {
    // F10：网络层异常已统一映射，直接用友好文案。
    return error.message;
  }
  if (error is GithubAuthException) {
    return error.message;
  }
  if (error is GithubConflictException) {
    return '${error.message}，请稍后重试';
  }
  if (error is GithubNotFoundException) {
    return error.message;
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return '网络连接失败，请检查网络后重试';
    }
  }
  MiruLogger().w('GithubApi: unexpected error', error: error);
  return '同步失败：$error';
}
