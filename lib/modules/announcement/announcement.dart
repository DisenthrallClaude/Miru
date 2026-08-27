import 'dart:convert';

/// 远程公告的数据模型。
///
/// 公告源是一个托管在仓库 main 分支根目录的 `announcement.json`：
/// 发布方通过管理页面改这个文件即可向全体用户推送弹窗公告，
/// 无需发版。所有展示判定（开关/版本区间/时间窗/频控）都在客户端执行，
/// 服务端只给数据。解析遵循「单条损坏跳过」的容错原则，与规则目录一致。
class AnnouncementFeed {
  const AnnouncementFeed({required this.announcements});

  final List<Announcement> announcements;

  /// 解析整个公告源。整体结构损坏（非 JSON / 非对象 / 无 announcements
  /// 数组）时返回 null，调用方静默放弃本次展示；单条损坏只跳过该条。
  static AnnouncementFeed? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final list = decoded['announcements'];
      if (list is! List) return null;
      final items = <Announcement>[];
      for (final item in list) {
        if (item is! Map) continue;
        final announcement = Announcement.fromJson(item);
        if (announcement != null) items.add(announcement);
      }
      return AnnouncementFeed(announcements: items);
    } catch (_) {
      return null;
    }
  }
}

/// 公告按钮动作。`type` 为 `url` 时拉起外部浏览器打开 `value`，
/// 为 `clipboard` 时把 `value` 复制到剪贴板；未知类型渲染为普通链接按钮，
/// 点击复制 value，保证管理页新增类型时旧客户端不至于丢失信息。
class AnnouncementAction {
  const AnnouncementAction({
    required this.label,
    required this.type,
    required this.value,
  });

  final String label;
  final String type;
  final String value;

  bool get isUrl => type == 'url';

  static AnnouncementAction? fromJson(Map<dynamic, dynamic> json) {
    final label = json['label'];
    final value = json['value'];
    if (label is! String || label.trim().isEmpty) return null;
    if (value is! String || value.trim().isEmpty) return null;
    return AnnouncementAction(
      label: label.trim(),
      type: json['type'] is String ? json['type'] as String : 'url',
      value: value.trim(),
    );
  }
}

enum AnnouncementFrequency {
  /// 看过一次就不再弹（默认，最不打扰）。
  once,

  /// 每天最多弹一次（适合持续数天的活动）。
  daily,

  /// 每次冷启动都弹（慎用）。
  everyLaunch;

  static AnnouncementFrequency fromName(String? name) {
    switch (name) {
      case 'daily':
        return AnnouncementFrequency.daily;
      case 'everyLaunch':
        return AnnouncementFrequency.everyLaunch;
      default:
        return AnnouncementFrequency.once;
    }
  }
}

class Announcement {
  const Announcement({
    required this.id,
    required this.enabled,
    required this.priority,
    required this.title,
    required this.body,
    required this.coverImage,
    required this.actions,
    required this.minAppVersion,
    required this.maxAppVersion,
    required this.startAt,
    required this.endAt,
    required this.frequency,
  });

  final String id;
  final bool enabled;
  final int priority;
  final String title;
  final String body;

  /// 可选封面图（16:9 展示）。空串表示无图。
  final String coverImage;
  final List<AnnouncementAction> actions;

  /// 版本区间过滤：空串表示不限制。
  final String minAppVersion;
  final String maxAppVersion;

  /// 活动有效期（ISO 8601）。null 表示不限制。
  final DateTime? startAt;
  final DateTime? endAt;

  final AnnouncementFrequency frequency;

  static Announcement? fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || id.trim().isEmpty) return null;
    if (title is! String || title.trim().isEmpty) return null;

    final actions = <AnnouncementAction>[];
    final rawActions = json['actions'];
    if (rawActions is List) {
      for (final action in rawActions) {
        if (action is! Map) continue;
        final parsed = AnnouncementAction.fromJson(action);
        if (parsed != null) actions.add(parsed);
      }
    }

    return Announcement(
      id: id.trim(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      priority: json['priority'] is int ? json['priority'] as int : 0,
      title: title.trim(),
      body: json['body'] is String ? json['body'] as String : '',
      coverImage:
          json['coverImage'] is String ? json['coverImage'] as String : '',
      actions: actions,
      minAppVersion:
          json['minAppVersion'] is String ? json['minAppVersion'] as String : '',
      maxAppVersion:
          json['maxAppVersion'] is String ? json['maxAppVersion'] as String : '',
      startAt: _parseDate(json['startAt']),
      endAt: _parseDate(json['endAt']),
      frequency: AnnouncementFrequency.fromName(
        json['showFrequency'] is String ? json['showFrequency'] as String : null,
      ),
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim());
  }
}
