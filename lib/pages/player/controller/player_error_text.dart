/// v1.8.1：把 mpv/ffmpeg 的原始错误翻译成用户能看懂、能行动的中文。
///
/// 之前 toast 直接展示「播放器内部错误 tcp: Connection to tcp://g.xlzyd.com:9999
/// failed: Connection tim…」（CI UI 巡检截图 ui_v2_09/12），既不可读也不可操作。
/// 原文仍完整记入日志，供诊断导出使用。
abstract final class PlayerErrorText {
  static String humanize(Object event) {
    final s = event.toString().toLowerCase();
    bool has(String k) => s.contains(k);
    final code = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(s)?.group(1);
    if (has('timed out') || has('timeout')) {
      return '视频服务器连接超时，正在重试；持续卡住可切换线路';
    }
    if (has('connection refused')) return '视频服务器拒绝连接，建议切换线路';
    if (has('crypto') || has('enc.key') || has('decrypt')) {
      return '加密分片读取失败，正在重试';
    }
    if (has('ssl') || has('tls') || has('handshake') || has('certificate')) {
      return '与视频服务器的安全连接失败，建议切换线路';
    }
    if (code == '403' || has('forbidden')) {
      return '视频服务器拒绝访问（403），建议切换线路';
    }
    if (code == '404' || has('not found')) return '视频地址已失效（404），建议切换线路';
    if (code != null && code.startsWith('5')) {
      return '视频服务器暂时异常（$code），可稍候重试或切换线路';
    }
    if (has('could not open codec') || has('decoder')) {
      return '解码出现问题，正在恢复；若花屏可在设置中切换硬件解码';
    }
    if (has('failed to open') || has('cannot open') || has('unrecognized file')) {
      return '视频无法打开，建议切换线路或视频来源';
    }
    if (has('network') || has('connection') || has('reset by peer')) {
      return '网络连接中断，正在重试';
    }
    return '播放遇到问题，可尝试切换线路';
  }
}
