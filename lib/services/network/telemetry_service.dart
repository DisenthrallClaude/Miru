import 'dart:async';

import 'package:miru/request/clients/download_http_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';

/// 轻量匿名心跳：每天一次向云端解析层上报「这个设备今天活跃」。
///
/// 这是免费额度动态配额的输入端：
/// - Worker 端按当日活跃人数把解析预算均摊成每用户配额，
///   不活跃的用户不占额度，活跃的越多每人越少——总体动态伸缩；
/// - 只发一个随机匿名 ID（见 [CloudVideoSourceResolver.uid]），
///   不含任何个人信息，不与收藏/配置一起导出；
/// - 全部 fire-and-forget：失败静默，绝不影响启动与播放；
/// - 云端解析关闭时不发（用户明确 opt-out）。
class TelemetryService {
  TelemetryService._();

  static final TelemetryService instance = TelemetryService._();

  /// 进程内去重：一次启动最多发一次。
  bool _pingedThisSession = false;

  /// 每日心跳入口（main 初始化时调用）。
  ///
  /// 幂等：同一天多次调用只发一次（跨天回到前台会再发）。
  Future<void> dailyPing() async {
    if (_pingedThisSession) return;
    if (!GStorage.getSetting(SettingsKeys.cloudResolverEnable)) return;
    _pingedThisSession = true;

    try {
      final today = _todayKey();
      if (GStorage.getSetting(SettingsKeys.lastPingDay) == today) {
        return; // 今天已经发过
      }
      await GStorage.putSetting(SettingsKeys.lastPingDay, today);

      // 心跳跟随端点配置（B13）：用户配了自建 Worker 时打到自建端点
      // （否则自建端点的活跃统计永远失真，其动态配额算不准）；
      // 多端点取第一个有效端点（解析侧为全端点竞速，心跳只打一个
      // 即可满足单端点主流场景）。
      final custom = GStorage.getSetting(SettingsKeys.cloudResolverUrl);
      final source = custom.trim().isEmpty
          ? ApiEndpoints.cloudResolverOfficialEndpoint
          : custom.trim();
      // 端点归一化与 CloudVideoSourceResolver.endpoints 同一套（N6）：
      // 跳过空段（串以逗号/空格开头时首段为空，之前 .first 会取到
      // 空串让 base 变成 'https://' → 心跳静默失败）、补 https://、
      // 去尾斜杠与 /resolve 后缀（顺序同 resolver，兼容 /resolve/），
      // 再过 Uri.tryParse + scheme 校验，取第一个有效端点。
      String? base;
      for (final part in source.split(RegExp(r'[,\s]+'))) {
        var candidate = part.trim();
        if (candidate.isEmpty) continue;
        if (!candidate.startsWith('http://') &&
            !candidate.startsWith('https://')) {
          candidate = 'https://$candidate';
        }
        candidate = candidate.replaceAll(RegExp(r'/+$'), '');
        candidate = candidate.replaceAll(RegExp(r'/resolve$'), '');
        final uri = Uri.tryParse(candidate);
        if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
          base = candidate;
          break;
        }
      }
      if (base == null) {
        // 全部段都无效：本次不发，与解析请求「无可达端点即跳过」同兜底
        // （lastPingDay 已写，明天再试，失败静默语义不变）。
        return;
      }
      final uid = CloudVideoSourceResolver.instance.uid;
      await _requestPing('$base/ping?uid=$uid');
      MiruLogger().d('Telemetry: daily ping sent to $base');
    } catch (e) {
      // 心跳失败完全无所谓（明天再试）
      MiruLogger().d('Telemetry: daily ping failed', error: e);
    }
  }

  Future<void> _requestPing(String url) async {
    try {
      await DownloadHttpClient.instance.getPlain(
        url,
        receiveTimeout: const Duration(seconds: 6),
      );
    } catch (_) {
      // 静默
    }
  }

  /// 本地时区的自然日（用户在哪，哪天就算哪天）。
  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
