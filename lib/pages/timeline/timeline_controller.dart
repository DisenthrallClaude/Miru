import 'package:miru/services/storage/feed_cache.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/request/config/featured_bangumi.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:miru/utils/anime_season.dart';
import 'package:miru/repositories/collect_repository.dart';
import 'package:miru/modules/collect/collect_type.dart';
import 'package:flutter/foundation.dart';
import 'package:miru/request/apis/season_schedule.dart';
import 'package:mobx/mobx.dart';

part 'timeline_controller.g.dart';

class TimelineController = _TimelineController with _$TimelineController;

abstract class _TimelineController with Store {
  _TimelineController(this._collectRepository);

  final ICollectRepository _collectRepository;

  @observable
  ObservableList<List<BangumiItem>> bangumiCalendar =
      ObservableList<List<BangumiItem>>();

  @observable
  String seasonString = '';

  @observable
  bool isLoading = false;

  @observable
  bool isTimeOut = false;

  @observable
  late bool notShowAbandonedBangumis =
      _collectRepository.getTimelineNotShowAbandonedBangumis();

  @observable
  late bool notShowWatchedBangumis =
      _collectRepository.getTimelineNotShowWatchedBangumis();

  @observable
  late bool onlyShowWatchingBangumis =
      _collectRepository.getTimelineOnlyShowWatchingBangumis();

  int _sortType = 3;
  int get sortType => _sortType;

  late DateTime _selectedDate;
  DateTime get selectedDate => _selectedDate;


  void init() {
    _selectedDate = DateTime.now();
    seasonString = AnimeSeason(_selectedDate).toString();
    getSchedules();
  }

  // Async actions commit each segment between awaits as one transaction, so
  // clear+addAll never shows observers an intermediate empty list.
  @action
  /// 每日放送。
  ///
  /// 原先走 `BangumiApi.getCalendar()`（官方每日放送表），该接口不支持产地过滤，
  /// 返回的几乎全是日番。改为按当前季度做带产地标签的搜索，
  /// 再由 `getCalendarBySearch` 按 airWeekday 分组，从而只出国漫。
  Future<void> getSchedules() async {
    await getSchedulesBySeason();
  }

  /// v1.8.1：后台刷新中（已展示缓存，同时在联网更新）。非 mobx 字段，
  /// 页面用 ValueListenableBuilder 显示顶部细进度条，不需要重跑 codegen。
  final ValueNotifier<bool> refreshing = ValueNotifier(false);

  /// 缓存超过这个时长就在展示后后台刷新（放送表一天内会有改档/新番补录）。
  static const Duration cacheTtl = Duration(hours: 3);

  /// 当前请求代次：切季度/重复刷新时丢弃过期结果，避免旧季度数据覆盖新季度。
  int _generation = 0;

  @action
  /// 按季度拉取时间表（v1.8.1：先展示缓存、后台刷新；并发分页；更新日按
  /// 放送星期/官方放送表判定，见 BangumiApi.getSeasonSchedule）。
  Future<void> getSchedulesBySeason({bool forceRefresh = false}) async {
    final generation = ++_generation;
    final seasonObj = AnimeSeason(selectedDate);
    final season = seasonObj.toString();
    final isCurrent = AnimeSeason(DateTime.now()).toString() == season;

    var showingCache = false;
    if (FeedCache.hasCalendarFor(season)) {
      final cached = FeedCache.loadCalendar();
      if (cached.any((d) => d.isNotEmpty)) {
        bangumiCalendar
          ..clear()
          ..addAll(cached);
        isLoading = false;
        isTimeOut = false;
        changeSortType(sortType);
        showingCache = true;
        final savedAt = FeedCache.calendarSavedAt;
        final fresh = FeedCache.calendarHasLayout &&
            savedAt != null &&
            DateTime.now().difference(savedAt) < cacheTtl;
        if (fresh && !forceRefresh) return;
      }
    }

    if (showingCache) {
      refreshing.value = true;
    } else {
      isLoading = true;
      isTimeOut = false;
      bangumiCalendar.clear();
    }

    final ScheduleBuild build;
    try {
      build = await BangumiApi.getSeasonSchedule(
        seasonObj.toSeasonStartAndEnd(),
        includeContinuing: isCurrent,
      );
    } catch (e) {
      if (generation != _generation) return;
      isLoading = false;
      refreshing.value = false;
      if (showingCache) {
        if (forceRefresh) {
          MiruDialog.showToast(message: '刷新失败，当前显示的是本地缓存');
        }
        return;
      }
      isTimeOut = true;
      MiruDialog.showToast(message: '时间表加载失败，请检查网络后重试');
      return;
    }
    if (generation != _generation) return;
    isLoading = false;
    refreshing.value = false;
    final empty = build.days.every((d) => d.isEmpty);
    if (empty && showingCache) return; // 网络给了空表：保留缓存
    bangumiCalendar
      ..clear()
      ..addAll(build.days);
    isTimeOut = empty;
    if (!empty) {
      changeSortType(sortType);
      // 只缓存当季（打开 App 默认看的就是当季）；翻看往季不覆盖当季缓存。
      if (isCurrent) {
        await FeedCache.saveCalendar(
          bangumiCalendar.map((e) => e.toList()).toList(),
          season,
        );
      }
    }
  }


  /// 条目在置顶清单中的次序：先按 id 精确匹配，
  /// 匹配不到再按中文名包含匹配（覆盖续作/分季命名差异）。
  int _featuredRank(BangumiItem item) {
    final byId = featuredRankOfId(item.id);
    if (byId != -1) return byId;
    final name = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    return featuredRankOfName(name);
  }

  void tryEnterSeason(DateTime date) {
    _selectedDate = date;
    seasonString = "加载中 ٩(◦`꒳´◦)۶";
  }

  /// Sort type: 1 = default (id), 2 = score, 3 = heat (votes).
  @action
  void changeSortType(int type) {
    if (type < 1 || type > 3) {
      return;
    }
    _sortType = type;
    var resBangumiCalendar = bangumiCalendar.toList();

    // 单次复合比较：先看是否在置顶清单（清单顺序优先），
    // 不在清单的再按用户选择的排序方式。
    // 不能拆成两次 sort —— Dart 的 List.sort 不保证稳定，
    // 第二次排序会打乱第一次的结果。
    int compare(BangumiItem a, BangumiItem b) {
      final ra = _featuredRank(a);
      final rb = _featuredRank(b);
      if (ra != -1 || rb != -1) {
        if (ra == -1) return 1;
        if (rb == -1) return -1;
        if (ra != rb) return ra.compareTo(rb);
      }
      switch (_sortType) {
        case 1:
          return a.id.compareTo(b.id);
        case 2:
          return b.ratingScore.compareTo(a.ratingScore);
        case 3:
          return b.votes.compareTo(a.votes);
        default:
          return 0;
      }
    }

    for (var dayList in resBangumiCalendar) {
      dayList.sort(compare);
    }
    bangumiCalendar.clear();
    bangumiCalendar.addAll(resBangumiCalendar);
  }

  @action
  Future<void> setNotShowAbandonedBangumis(bool value) async {
    notShowAbandonedBangumis = value;
    await _collectRepository.updateTimelineNotShowAbandonedBangumis(value);
  }

  @action
  Future<void> setNotShowWatchedBangumis(bool value) async {
    notShowWatchedBangumis = value;
    await _collectRepository.updateTimelineNotShowWatchedBangumis(value);
  }

  Set<int> loadAbandonedBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.abandoned);
  }

  Set<int> loadWatchedBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.watched);
  }

  @action
  Future<void> setOnlyShowWatchingBangumis(bool value) async {
    onlyShowWatchingBangumis = value;
    await _collectRepository.updateTimelineOnlyShowWatchingBangumis(value);
  }

  Set<int> loadWatchingBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.watching);
  }
}
