import 'dart:convert';

import 'package:miru/bean/dialog/announcement_dialog.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/announcement/announcement.dart';
import 'package:miru/request/clients/rules_repo_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/version.dart';

/// 远程公告服务：启动后异步拉取 announcement.json，
/// 命中需要展示的公告时弹出液态玻璃弹窗。
///
/// 三条铁律（与规则同步、启动更新检查的既有原则一致）：
/// 1. 绝不阻塞启动路径——全部异步，失败静默；
/// 2. 每次冷启动最多弹一次（频控 + 会话级去重双保险）；
/// 3. 任何解析/网络异常只记日志，绝不打扰用户。
class AnnouncementService {
  AnnouncementService._();

  static final AnnouncementService instance = AnnouncementService._();

  /// 会话级去重：热重启（不杀进程）不重复弹。
  bool _shownThisSession = false;

  /// 主界面就绪后延迟多久拉取。避开首帧渲染与页面转场，
  /// 也错开启动更新检查的请求高峰。
  static const Duration _startDelay = Duration(seconds: 2);

  /// 单源拉取超时。公告是运营内容，慢网时放弃即可。
  static const Duration _fetchTimeout = Duration(seconds: 5);

  static const List<String> _sources = [
    ApiEndpoints.announcementJsonMirror,
    ApiEndpoints.announcementJson,
  ];

  /// 入口：主界面就绪后调用（引导流程中不调用）。
  Future<void> maybeShowAnnouncement() async {
    if (_shownThisSession) return;
    _shownThisSession = true;

    await Future.delayed(_startDelay);

    final raw = await _fetch();
    if (raw == null) return;

    final feed = AnnouncementFeed.parse(raw);
    if (feed == null) {
      MiruLogger().w('Announcement: feed payload is malformed, skipped');
      return;
    }

    final dismissed = _loadDismissed();
    final now = DateTime.now();
    final selected = selectAnnouncement(
      feed: feed,
      appVersion: ApiEndpoints.version,
      now: now,
      dismissed: dismissed,
    );
    if (selected == null) return;

    MiruLogger().i('Announcement: showing "${selected.id}"');
    await MiruDialog.show(
      clickMaskDismiss: true,
      onDismiss: () => _recordDismissed(selected, now),
      builder: (context) => AnnouncementDialog(announcement: selected),
    );
  }

  /// 双源回退拉取（jsDelivr 主源 → raw 兜底），全部失败返回 null。
  Future<String?> _fetch() async {
    for (final source in _sources) {
      try {
        final text = await RulesRepoClient.instance
            .getText(source)
            .timeout(_fetchTimeout);
        if (text.trim().isNotEmpty) {
          return text;
        }
      } catch (e) {
        MiruLogger().w('Announcement: fetch failed for $source', error: e);
      }
    }
    return null;
  }

  // ---------- 展示判定（纯函数，供单测） ----------

  /// 判定链：enabled → 版本区间 → 时间窗 → 频控 → 取 priority 最高的一条。
  /// 多条命中只展示一条，避免弹窗轰炸。
  static Announcement? selectAnnouncement({
    required AnnouncementFeed feed,
    required String appVersion,
    required DateTime now,
    required Map<String, String> dismissed,
  }) {
    Announcement? best;
    for (final announcement in feed.announcements) {
      if (!_passesFilters(announcement, appVersion, now, dismissed)) {
        continue;
      }
      if (best == null || announcement.priority > best.priority) {
        best = announcement;
      }
    }
    return best;
  }

  static bool _passesFilters(
    Announcement announcement,
    String appVersion,
    DateTime now,
    Map<String, String> dismissed,
  ) {
    if (!announcement.enabled) return false;

    // 版本区间：minAppVersion <= 当前版本 <= maxAppVersion（空串不限制）。
    if (announcement.minAppVersion.isNotEmpty &&
        compareVersions(appVersion, announcement.minAppVersion) < 0) {
      return false;
    }
    if (announcement.maxAppVersion.isNotEmpty &&
        compareVersions(appVersion, announcement.maxAppVersion) > 0) {
      return false;
    }

    // 时间窗：过期/未开始的公告自动消失，发布方无需手动下线。
    if (announcement.startAt != null && now.isBefore(announcement.startAt!)) {
      return false;
    }
    if (announcement.endAt != null && now.isAfter(announcement.endAt!)) {
      return false;
    }

    // 频控：once = 关闭过即不再弹；daily = 同一天内不重复。
    final dismissedDate = dismissed[announcement.id];
    if (dismissedDate != null) {
      switch (announcement.frequency) {
        case AnnouncementFrequency.once:
          return false;
        case AnnouncementFrequency.daily:
          if (dismissedDate == _dayKey(now)) return false;
          break;
        case AnnouncementFrequency.everyLaunch:
          break;
      }
    }

    return true;
  }

  // ---------- 频控状态存取 ----------

  static String _dayKey(DateTime time) {
    String padded(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${padded(time.month)}-${padded(time.day)}';
  }

  static Map<String, String> _loadDismissed() {
    final raw = GStorage.getSetting(SettingsKeys.announcementDismissState);
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v is String ? v : ''));
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _recordDismissed(
      Announcement announcement, DateTime now) async {
    final state = _loadDismissed();
    state[announcement.id] = _dayKey(now);
    // 状态对象只增不减会无限增长；定期裁掉超过一年的记录。
    if (state.length > 50) {
      state.removeWhere((_, date) {
        final parsed = DateTime.tryParse(date);
        return parsed == null ||
            now.difference(parsed).inDays > 365;
      });
    }
    try {
      await GStorage.putSetting(
        SettingsKeys.announcementDismissState,
        jsonEncode(state),
      );
    } catch (e) {
      MiruLogger().w('Announcement: persist dismiss state failed', error: e);
    }
  }
}
