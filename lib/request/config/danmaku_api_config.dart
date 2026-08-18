import 'package:kazumi/request/config/api_endpoints.dart';

/// 弹幕接口基址解析。
///
/// 自建包没有弹弹play 签名密钥，官方 `api.dandanplay.net` 会 401。
/// 用户可以在设置里填一个兼容弹弹play `/api/v2` 协议的服务
///（例如自建 [danmu_api](https://github.com/huangxd-/danmu_api)），
/// 填了之后请求不再附带空签名头。
abstract final class DanmakuApiConfig {
  static const officialHost = 'api.dandanplay.net';

  /// 把用户输入整理成可拼接 `/api/v2/...` 的基址。
  ///
  /// 空字符串回落到官方域名。兼容用户写成
  /// `host`、`https://host/`、`https://host/token`、`https://host/token/api/v2`。
  static String resolveBaseUrl(String custom) {
    var value = custom.trim();
    if (value.isEmpty) {
      return ApiEndpoints.dandanAPIDomain;
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    const apiSuffix = '/api/v2';
    if (value.toLowerCase().endsWith(apiSuffix)) {
      value = value.substring(0, value.length - apiSuffix.length);
    }
    return value;
  }

  /// 只有打官方弹弹play 时才需要 X-AppId / X-Signature。
  static bool shouldSignRequest(String url) {
    final host = Uri.tryParse(url)?.host;
    return host == officialHost;
  }
}
