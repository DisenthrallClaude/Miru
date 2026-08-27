import 'dart:convert';

import 'package:miru/bean/dialog/announcement_dialog.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/announcement/announcement.dart';
import 'package:miru/request/clients/rules_repo_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/core/network_exception.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/version.dart';

/// 远程公告服务：启动后异步拉取 announcement.json，
/// 命中需要展示的公告时弹出液态玻璃弹窗。
///
/// 对接规格要点（除原有三条铁律外）：
/// 1. 拉取失败/解析失败 → 沿用上次成功数据（本地缓存整体覆盖式更新）；
/// 2. 所有源都明确 404/空体 → 当前无公告，不展示也不走缓存；
/// 3. 删除语义：announcements 数组是唯一事实来源，展示只看当前数组；
///    成功拉取后同步清理不在数组中（含墓碑）id 的频控记录，
///    被删除的公告重新发布后会当作新公告重新弹。
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
    ApiEndpoints.announcementJsonCdn,
    ApiEndpoints.announcementJsonMirror,
    ApiEndpoints.announcementJson,
  ];

  /// 入口：主界面就绪后调用（引导流程中不调用）。
  Future<void> maybeShowAnnouncement() async {
    if (_shownThisSession) return;
    _shownThisSession = true;

    await Future.delayed(_startDelay);

    final result = await _fetch();

    // 所有可达源都明确表态「无公告」（404/空体）：本次不展示。
    // 注意与网络故障区分：后者要沿用缓存。
    if (result.definitiveNoAnnouncements) return;

    AnnouncementFeed? feed;
    if (result.raw != null) {
      feed = AnnouncementFeed.parse(result.raw!);
      if (feed != null) {
        // 缓存整体覆盖（携带删除语义），并同步清理已删除 id 的频控记录。
        await _saveCache(result.raw!);
        await _pruneDismissState(feed);
      } else {
        MiruLogger()
            .w('Announcement: feed payload is malformed, fall back to cache');
      }
    }

    // 拉取失败或解析失败 → 沿用上次成功数据（对接规格）。
    feed ??= _loadCachedFeed();
    if (feed == null) return;

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
      clickMaskDismiss: false,
      onDismiss: () => _recordDismissed(selected, now),
      builder: (context) => AnnouncementDialog(announcement: selected),
    );
  }

  /// 多源回退拉取。无法拿到新数据时 raw 为 null，并通过
  /// [FetchResult.definitiveNoAnnouncements] 区分「服务端明确说没有」
  /// （404/空体）与「网络故障拿不到」。
  Future<FetchResult> _fetch() async {
    int definitiveAbsence = 0;
    for (final source in _sources) {
      try {
        final text = await RulesRepoClient.instance
            .getText(source)
            .timeout(_fetchTimeout);
        if (text.trim().isNotEmpty) {
          return FetchResult(raw: text);
        }
        // 200 但空体：与「无公告」同语义。
        definitiveAbsence++;
      } on NetworkException catch (e) {
        if (e.statusCode == 404) {
          definitiveAbsence++;
          continue;
        }
        MiruLogger().w('Announcement: fetch failed for $source', error: e);
      } catch (e) {
        MiruLogger().w('Announcement: fetch failed for $source', error: e);
      }
    }
    return FetchResult(
      raw: null,
      // 只有全部源都明确表态无公告才认定「无公告」；
      // 只要有一个源是网络故障，就走缓存兜底。
      definitiveNoAnnouncements: definitiveAbsence == _sources.length,
    );
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

  /// 删除语义落地：成功拉取后，把不在当前数组中的 id（含墓碑指定
  /// 的 id）的频控记录一并清除。这样被删除的公告若重新发布，
  /// 会当作新公告重新弹出（规格：该 id 被删除时记录一并清除）。
  static Future<void> _pruneDismissState(AnnouncementFeed feed) async {
    try {
      final state = _loadDismissed();
      if (state.isEmpty) return;
      final live = feed.liveIds;
      state.removeWhere((id, _) => !live.contains(id));
      await GStorage.putSetting(
        SettingsKeys.announcementDismissState,
        jsonEncode(state),
      );
    } catch (e) {
      MiruLogger().w('Announcement: prune dismiss state failed', error: e);
    }
  }

  static Future<void> _saveCache(String raw) async {
    try {
      await GStorage.putSetting(SettingsKeys.announcementCache, raw);
    } catch (e) {
      MiruLogger().w('Announcement: persist cache failed', error: e);
    }
  }

  static AnnouncementFeed? _loadCachedFeed() {
    final raw = GStorage.getSetting(SettingsKeys.announcementCache);
    if (raw.isEmpty) return null;
    return AnnouncementFeed.parse(raw);
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

/// 单次拉取的结果。
class FetchResult {
  const FetchResult({this.raw, this.definitiveNoAnnouncements = false});

  /// 拉取到的公告源原文；null 表示本次没拿到新数据。
  final String? raw;

  /// 所有源都明确表态无公告（HTTP 404 / 空响应体）。
  /// 与网络故障不同：这种情况不适用缓存兑底，直接不展示。
  final bool definitiveNoAnnouncements;
}
