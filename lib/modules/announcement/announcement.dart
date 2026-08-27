import 'dart:convert';

/// 远程公告的数据模型。
///
/// 公告源是一个托管在仓库 main 分支根目录的 `announcement.json`：
/// 发布方通过管理页面改这个文件即可向全体用户推送弹窗公告，
/// 无需发版。所有展示判定（开关/版本区间/时间窗/频控）都在客户端执行，
/// 服务端只给数据。解析遵循「单条损坏跳过」的容错原则，与规则目录一致。
class AnnouncementFeed {
  const AnnouncementFeed({
    required this.announcements,
    this.deletedIds = const [],
  });

  final List<Announcement> announcements;

  /// 删除墓碑（顶层 deletedIds 数组中的 id 集合）。
  ///
  /// 删除语义：`announcements` 数组是唯一事实来源，不在数组中的 id
  /// 一律视为已删除；墓碑用于即时作废老客户端的本地残留数据
  /// （已读记录等）。展示侧永远只看当前数组，两者合力保证：
  /// 已删除的公告在任何设备、任何频控状态下都绝不再弹。
  final List<String> deletedIds;

  /// 当前数组中存活的公告 id（含 enabled=false 的条目——它们只是
  /// 暂时下线，记录应保留）。
  Set<String> get liveIds => announcements.map((e) => e.id).toSet();

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
      // 删除墓碑：[{id, deletedAt}]，结构损坏时静默忽略。
      final tombstones = <String>[];
      final rawDeleted = decoded['deletedIds'];
      if (rawDeleted is List) {
        for (final entry in rawDeleted) {
          if (entry is Map && entry['id'] is String) {
            final id = (entry['id'] as String).trim();
            if (id.isNotEmpty) tombstones.add(id);
          }
        }
      }
      return AnnouncementFeed(
        announcements: items,
        deletedIds: tombstones,
      );
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

/// 公告正文字体映射。
///
/// 管理端 font 字段是 Web 端视角的 CSS 字体名；App 侧映射到
/// Android 平台字体族 + 内置回退：
/// - 黑体类（sans/notoSans/显示类）→ 应用默认字体
/// - 衬线类（serif/xiaoWei/playfair/garamond）→ 系统衬线 +
///   内置 Noto Serif SC 兜底（App 自带该字体，任何设备都可读）
/// - 楷体/手写类（kai/longCang/zhiMang/liuJian/maShang）→
///   系统手写体（部分厂商有楷体，无则回退衬线）
/// - mono → 系统等宽
/// 未识别的值一律回退默认字体，绝不报错（规格要求）。
class AnnouncementFont {
  const AnnouncementFont({this.fontFamily, this.fallback});

  /// 平台字体族名；null 表示应用默认字体。
  final String? fontFamily;

  /// 字形级回退链，覆盖平台字体缺失的中文字形。
  final List<String>? fallback;

  static const AnnouncementFont _defaultFont = AnnouncementFont();
  static const AnnouncementFont _serifFont = AnnouncementFont(
    fontFamily: 'serif',
    fallback: ['Noto_Serif_SC'],
  );
  static const AnnouncementFont _handwritingFont = AnnouncementFont(
    fontFamily: 'cursive',
    fallback: ['Noto_Serif_SC'],
  );
  static const AnnouncementFont _monoFont = AnnouncementFont(
    fontFamily: 'monospace',
    fallback: ['Noto_Serif_SC'],
  );

  /// 默认字体（font 为空或未识别时）。
  static const AnnouncementFont defaultFont = _defaultFont;

  static AnnouncementFont fromName(String? name) {
    switch (name) {
      case 'serif':
      case 'xiaoWei':
      case 'playfair':
      case 'garamond':
        return _serifFont;
      case 'kai':
      case 'longCang':
      case 'zhiMang':
      case 'liuJian':
      case 'maShan':
        return _handwritingFont;
      case 'mono':
        return _monoFont;
      default:
        // ''/sans/notoSans/huangYou/kuaiLe 及一切未知值 → 默认字体。
        return _defaultFont;
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
    this.font = '',
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

  /// 管理端指定的展示字体（见 [AnnouncementFont.fromName]）。
  final String font;

  /// 解析后的字体规格，供弹窗标题与正文使用。
  AnnouncementFont get resolvedFont => AnnouncementFont.fromName(font);

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
      // 规格约定 minAppVersion 默认 1.3.0（公告功能自该版本起存在）。
      // 缺字段或空串都落到默认值；所有实际用户版本均 >= 1.3.0，
      // 因此默认值与「不限」在效果上等价，但严格遵循规格语义。
      minAppVersion: json['minAppVersion'] is String &&
              (json['minAppVersion'] as String).trim().isNotEmpty
          ? (json['minAppVersion'] as String).trim()
          : '1.3.0',
      maxAppVersion:
          json['maxAppVersion'] is String ? json['maxAppVersion'] as String : '',
      startAt: _parseDate(json['startAt']),
      endAt: _parseDate(json['endAt']),
      frequency: AnnouncementFrequency.fromName(
        json['showFrequency'] is String ? json['showFrequency'] as String : null,
      ),
      font: json['font'] is String ? json['font'] as String : '',
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim());
  }
}
