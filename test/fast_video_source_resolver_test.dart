import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';

/// 本地快速静态解析器提取逻辑单测。
///
/// 覆盖 v1.5.2 的三个核心修复点：
/// 1. player_aaaa **括号配平**（嵌套 vod_data 不再截断——blbl/lblb/
///    淘片等 MacCMS 站旧正则全挂的根因）；
/// 2. MacCMS 官方 **encrypt 编码解码**（1=escape，2=base64(escape)）；
/// 3. Artplayer 内联直链 / iframe 二跳 / 广告域过滤。
///
/// 网络部分（resolve 的 HTTP fetch）不做单测——纯函数全量覆盖。
void main() {
  group('extractPlayerVar（括号配平 + encrypt 解码）', () {
    test('嵌套 vod_data 对象不再截断（淘片形态）', () {
      final html = '''
<script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,
"link":"","link_next":"","link_pre":"",
"url":"https://sd8.example.com/HD/2022-12-01/30/abc/playlist.m3u8",
"url_next":"","from":"taopian","server":"no","note":"","id":2716,"sid":1,
"nid":1,"vod_data":{"vod_name":"完美世界","vod_actor":"锦鲤,阎瞒,赵双"}};
</script>''';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      expect(result!.$1,
          'https://sd8.example.com/HD/2022-12-01/30/abc/playlist.m3u8');
    });

    test('encrypt=2：base64(escape()) 双重编码解码', () {
      // escape('https://vip.example.com/index.m3u8') 全 ASCII → 原文
      // base64('https://vip.example.com/index.m3u8')
      const b64 = 'aHR0cHM6Ly92aXAuZXhhbXBsZS5jb20vaW5kZXgubTN1OA==';
      final html =
          '<script>var player_aaaa={"flag":"play","encrypt":2,"url":"$b64",'
          '"from":"ffm3u8","vod_data":{"vod_name":"测试"}};</script>';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      expect(result!.$1, 'https://vip.example.com/index.m3u8');
    });

    test('encrypt=1：escape() 编码解码（含 %uXXXX 中文码位）', () {
      const escaped =
          'https%3A%2F%2Fvip.example.com%2F%u4E2D%u6587%2Findex.m3u8';
      final html =
          '<script>var player_data={"encrypt":1,"url":"$escaped",'
          '"from":"lz","vod_data":{"a":1}};</script>';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      expect(result!.$1, 'https://vip.example.com/中文/index.m3u8');
    });

    test('encrypt=0：encodeURIComponent 包装解码兜底', () {
      const wrapped =
          'https%3A%2F%2Fplay.example.com%2Findex.m3u8%3Fsign%3Dabc';
      final html =
          '<script>var player_aaaa={"encrypt":0,"url":"$wrapped",'
          '"from":"dm","vod_data":{"n":1}};</script>';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      expect(result!.$1, 'https://play.example.com/index.m3u8?sign=abc');
    });

    test('字符串字面量里的花括号不影响配平', () {
      final html = '''
<script>var player_aaaa={"encrypt":0,"url":"https://a.com/{weird}/v.m3u8",
"note":"} 截断 trick","vod_data":{"n":1}};</script>''';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      expect(result!.$1, 'https://a.com/{weird}/v.m3u8');
    });

    test('第三方解析器 token（非 http 开头）返回 null（降级 WebView）', () {
      final html =
          '<script>var player_aaaa={"flag":"play","encrypt":0,"url":'
          '"ACG-43a311b473bc51884a9c7353d9e5bad8","from":"ACG",'
          '"vod_data":{"n":1}};</script>';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNull);
    });

    test('转义引号在 JSON 字符串内正确跳过', () {
      final html = r'''
<script>var player_aaaa={"encrypt":0,"url":"https:\/\/cdn.example.com\/v.m3u8","note":"say \"}\" ok","vod_data":{"n":1}};</script>''';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNotNull);
      // 转义斜杠在提取阶段保留原样（absolutize/播放均兼容 \/ 形态前先还原）
      expect(result!.$1, contains('v.m3u8'));
    });
  });

  group('extractDirectVideoUrl（Artplayer 内联 / 广告过滤）', () {
    test('Artplayer 内联 url 提取（MXdm 形态）', () {
      final html = """
<script>var art = new Artplayer({
    container: '.MacPlayer',
    url: 'https://yzzy.play-cdn2.com/20220408/8953_8c6f0de5/index.m3u8',
    type: 'm3u8',
});</script>""";
      final url = FastVideoSourceResolverPlayerVarProbe.extractDirect(html);
      expect(url,
          'https://yzzy.play-cdn2.com/20220408/8953_8c6f0de5/index.m3u8');
    });

    test('m3u8 优先于 mp4', () {
      final html =
          '<script src="https://a.com/b.mp4"></script> <a href="https://c.com/d.m3u8">x</a>';
      final url = FastVideoSourceResolverPlayerVarProbe.extractDirect(html);
      expect(url, 'https://c.com/d.m3u8');
    });

    test('广告域被过滤', () {
      final html =
          '<a href="https://googleads.g.doubleclick.net/v.m3u8">ad</a>';
      final url = FastVideoSourceResolverPlayerVarProbe.extractDirect(html);
      expect(url, isNull);
    });

    test('带签名 query 的直链不被截断', () {
      final html =
          "<script>var u='https://cdn.example.com/v.m3u8?sign=aBc123%2Fx&tm=999';</script>";
      final url = FastVideoSourceResolverPlayerVarProbe.extractDirect(html);
      expect(url, startsWith('https://cdn.example.com/v.m3u8?sign='));
    });

    test('无视频直链返回 null', () {
      final url = FastVideoSourceResolverPlayerVarProbe
          .extractDirect('<div>普通页面</div>');
      expect(url, isNull);
    });
  });

  group('extractIframeSrc', () {
    test('提取第一个非广告 iframe', () {
      final html = '''
<iframe src="about:blank"></iframe>
<iframe src="https://googleads.example.com/x.html"></iframe>
<iframe src="/static/player/dm.html?url=https%3A%2F%2Fv.m3u8"></iframe>''';
      final src = FastVideoSourceResolverPlayerVarProbe.extractIframe(html);
      expect(src, '/static/player/dm.html?url=https%3A%2F%2Fv.m3u8');
    });

    test('无 iframe 返回 null', () {
      final src =
          FastVideoSourceResolverPlayerVarProbe.extractIframe('<div></div>');
      expect(src, isNull);
    });
  });

  group('macUnescape', () {
    test('UTF-16 码位与百分号编码混合', () {
      const s = '%u4E16%u754C%20hello';
      final decoded = FastVideoSourceResolverPlayerVarProbe.macUnescape(s);
      expect(decoded, '世界 hello');
    });
  });
}
