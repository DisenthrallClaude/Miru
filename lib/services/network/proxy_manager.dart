import 'package:cached_network_image/cached_network_image.dart';
import 'package:miru/request/clients/plugin_site_client.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/proxy_aware_image_cache_manager.dart';

/// 代理管理器
/// 统一管理 Dio HTTP 请求和 cached_network_image 的代理设置
/// 注意：WebView 代理在各平台 controller 初始化时单独处理
class ProxyManager {
  ProxyManager._();

  /// 应用代理设置
  static void applyProxy() {
    DioFactory.reset();
    _applyImageCacheManager();
    // v1.6.9（P1-10）：出口基线已变——粘性 UA 缓存失效 + 提示指纹
    // 需重新建立；验证过的 clearance Cookie 也可能失效（IP 绑定型），
    // 打日志说明基线变化，用户遇 403 时知道先重试验证而非报 bug。
    PluginSiteClient.instance.invalidateStickyUserAgents();
    MiruLogger().i(
        'Proxy: 网络客户端配置已刷新（指纹基线已重置，已验证 Cookie 可能需要重新验证）');
  }

  /// 清除代理设置
  static void clearProxy() {
    DioFactory.reset();
    _applyImageCacheManager();
    PluginSiteClient.instance.invalidateStickyUserAgents();
    MiruLogger().i(
        'Proxy: 网络客户端代理已清除（指纹基线已重置，已验证 Cookie 可能需要重新验证）');
  }

  static void _applyImageCacheManager() {
    CachedNetworkImageProvider.defaultCacheManager =
        ProxyAwareImageCacheManager.instance;
  }
}
