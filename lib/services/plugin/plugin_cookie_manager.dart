import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// 规则 Cookie 管理器
///
/// 通过 [saveFromWebView] 将 WebView 捕获的 document.cookie 字符串解析后写入
/// 持久化的 [PersistCookieJar]（按域名分文件落盘），规则请求执行器按需读取并
/// 组装 Cookie 请求头。
/// 验证 Cookie 通常与 User-Agent 绑定，故同时记录 WebView 的 UA 并一并落盘，
/// 供后续 dio 请求对齐指纹；应用重启后无需重新验证。
class PluginCookieManager {
  PluginCookieManager._();
  static final PluginCookieManager instance = PluginCookieManager._();

  static const String _storageDirName = 'plugin_cookies';
  static const String _userAgentsFileName = 'user_agents.json';

  Future<CookieJar>? _jarFuture;
  final Map<String, String> _userAgents = {};
  Future<void>? _userAgentsLoadFuture;

  /// 初始化失败的 Future 不能被缓存，否则整个会话的 Cookie
  /// 功能都会瘫痪在同一个错误上；置空允许下次调用重试。
  Future<CookieJar> _getJar() {
    return _jarFuture ??= _createJar().catchError((Object e) {
      _jarFuture = null;
      throw e;
    });
  }

  Future<CookieJar> _createJar() async {
    final directory = await getApplicationSupportDirectory();
    final storagePath =
        '${directory.path}${Platform.pathSeparator}$_storageDirName';
    await Directory(storagePath).create(recursive: true);
    // 验证型 Cookie 多为无 expires 属性的会话 Cookie，
    // ignoreExpires 让它们跨重启保留，否则持久化形同虚设。
    return PersistCookieJar(
      storage: FileStorage(storagePath),
      ignoreExpires: true,
    );
  }

  Future<void> saveFromWebView(
      String pluginName, String pageUrl, String cookieString,
      {String? userAgent}) async {
    if (userAgent != null && userAgent.trim().isNotEmpty) {
      _userAgents[pluginName] = userAgent.trim();
      await _persistUserAgents();
    }
    if (cookieString.trim().isEmpty) return;
    final uri = Uri.tryParse(pageUrl);
    if (uri == null) return;

    final cookies = _parseCookieString(cookieString, uri);
    if (cookies.isEmpty) return;

    try {
      final jar = await _getJar();
      await jar.saveFromResponse(uri, cookies);
      MiruLogger().i(
          '[PluginCookieManager] Saved ${cookies.length} cookies for $pluginName');
    } catch (error, stackTrace) {
      MiruLogger().w(
          '[PluginCookieManager] Failed to persist cookies for $pluginName',
          error: error,
          stackTrace: stackTrace);
    }
  }

  /// 解析字符串为 [Cookie] 列表
  List<Cookie> _parseCookieString(String raw, Uri uri) {
    final cookies = <Cookie>[];
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex <= 0) continue;
      final name = trimmed.substring(0, eqIndex).trim();
      final value = trimmed.substring(eqIndex + 1).trim();
      try {
        final cookie = Cookie(name, value)
          ..domain = uri.host
          ..path = '/';
        cookies.add(cookie);
      } catch (_) {}
    }
    return cookies;
  }

  Future<List<Cookie>> loadForRequest(
    String pluginName,
    Uri uri,
  ) async {
    try {
      final jar = await _getJar();
      // await 确保反序列化异常能被下方 catch 捕获并降级为空列表。
      return await jar.loadForRequest(uri);
    } catch (error, stackTrace) {
      MiruLogger().w('[PluginCookieManager] Failed to load cookies',
          error: error, stackTrace: stackTrace);
      return <Cookie>[];
    }
  }

  /// 验证时 WebView 使用的 User-Agent；未验证过的规则返回 null
  Future<String?> userAgentFor(String pluginName) async {
    await _ensureUserAgentsLoaded();
    return _userAgents[pluginName];
  }

  /// 组装播放器可用的 Cookie 请求头。
  ///
  /// 播放链路（mpv）不经过 WebView，验证后下发的 clearance/token 类
  /// Cookie 必须显式透传，否则「浏览器能播、app 必 403」。
  /// [uri] 一般传规则站点首页地址。失败时返回空 Map，不阻塞播放。
  Future<Map<String, String>> cookieHeaderFor(
      String pluginName, Uri uri) async {
    try {
      final cookies = await loadForRequest(pluginName, uri);
      if (cookies.isEmpty) return const {};
      // 同名 Cookie 后写优先（PersistCookieJar 已按域/路径过滤过一轮）。
      final header = <String, String>{};
      for (final cookie in cookies) {
        final name = cookie.name.trim();
        final value = cookie.value.trim();
        if (name.isEmpty || value.isEmpty) continue;
        header[name] = value;
      }
      return header;
    } catch (error, stackTrace) {
      MiruLogger().w(
          '[PluginCookieManager] Failed to build cookie header for $pluginName',
          error: error,
          stackTrace: stackTrace);
      return const {};
    }
  }

  Future<void> _ensureUserAgentsLoaded() {
    return _userAgentsLoadFuture ??= _loadUserAgents();
  }

  Future<void> _loadUserAgents() async {
    try {
      final file = await _userAgentsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((key, value) {
        if (value is String) _userAgents[key] = value;
      });
    } catch (error, stackTrace) {
      MiruLogger()
          .w('[PluginCookieManager] Failed to load persisted user agents',
              error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _persistUserAgents() async {
    try {
      await _ensureUserAgentsLoaded();
      final file = await _userAgentsFile();
      await file.writeAsString(jsonEncode(_userAgents), flush: true);
    } catch (error, stackTrace) {
      MiruLogger()
          .w('[PluginCookieManager] Failed to persist user agents',
              error: error, stackTrace: stackTrace);
    }
  }

  Future<File> _userAgentsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
        '${directory.path}${Platform.pathSeparator}$_storageDirName${Platform.pathSeparator}$_userAgentsFileName');
  }
}
