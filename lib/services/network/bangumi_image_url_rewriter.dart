abstract final class BangumiImageUrlRewriter {
  static const _apiImageKinds = {'subjects', 'characters', 'persons'};

  /// next 反代（next.bangumi.lol）返回的封面挂在这个图床上。
  static const _nextProxyImageHost = 'lain.bangumi.lol';

  /// 搜索反代（bgmapi.anibt.net）返回的封面挂在这个图床上。
  /// 两者路径结构完全一致，可以直接换主机。
  static const _preferredImageHost = 'bgmimg.anibt.net';

  static String rewrite(String url, {required bool enabled}) {
    if (!enabled) return url;

    final uri = Uri.tryParse(url);
    if (uri == null || !_isHttp(uri)) return url;

    // 把 next 反代的图床归一到搜索反代的图床。
    //
    // 两条反代各自返回不同图床的封面，其中 lain.bangumi.lol 在部分网络下
    // 不可达，表现为「置顶的那批番剧没有封面，搜索出来的却有」。
    // 路径完全相同，换主机即可，无需经第三方图片代理。
    if (uri.host == _nextProxyImageHost) {
      return uri.replace(host: _preferredImageHost).toString();
    }

    if (!_isMirrorable(uri)) return url;

    final sourceUrl =
        uri.host + uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    return Uri.https('wsrv.nl', '/', {
      'url': sourceUrl,
      if (uri.path.toLowerCase().endsWith('.gif')) 'n': '-1',
    }).toString();
  }

  static bool _isHttp(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

  static bool _isMirrorable(Uri uri) =>
      uri.host == 'lain.bgm.tv' || _isApiImage(uri);

  static bool _isApiImage(Uri uri) {
    if (uri.host != 'api.bgm.tv') return false;

    final segments = uri.pathSegments;
    if (segments.length != 4 || segments[0] != 'v0' || segments[3] != 'image') {
      return false;
    }
    final id = int.tryParse(segments[2]);
    return _apiImageKinds.contains(segments[1]) && id != null && id > 0;
  }
}
