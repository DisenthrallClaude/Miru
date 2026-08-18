import 'dart:async';

import 'package:kazumi/services/storage/feed_cache.dart';
import 'package:kazumi/request/config/featured_bangumi.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
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

  @action
  /// 按季度拉取时间表。
  ///
  /// 不再走需要签名的 mirror 独有接口（/kazumi/v1/calendar/season），
  /// 统一使用官方搜索路径 —— 域名已由拦截器重写到公共反代。
  Future<void> getSchedulesBySeason({bool forceRefresh = false}) async {
    final season = AnimeSeason(selectedDate).toString();

    // 命中同季度的本地缓存就直接用，完全不联网。
    // 换季（season 变化）或用户主动刷新时才重新拉取。
    if (!forceRefresh && FeedCache.hasCalendarFor(season)) {
      bangumiCalendar.clear();
      bangumiCalendar.addAll(FeedCache.loadCalendar());
      isLoading = false;
      isTimeOut = bangumiCalendar.every((innerList) => innerList.isEmpty);
      if (!isTimeOut) {
        changeSortType(sortType);
        if (FeedCache.isCalendarStale) {
          unawaited(_refreshCalendarInBackground(season));
        }
        return;
      }
      // 缓存内容异常（全空）则回落到联网
    }

    isLoading = true;
    isTimeOut = false;
    bangumiCalendar.clear();
    final resBangumiCalendar = await _fetchSeasonCalendar();
    bangumiCalendar.addAll(resBangumiCalendar);
    isLoading = false;
    if (bangumiCalendar.isEmpty) {
      isTimeOut = true;
    } else {
      isTimeOut = bangumiCalendar.every((innerList) => innerList.isEmpty);
    }
    if (!isTimeOut) {
      changeSortType(sortType);
      // 排序后再落盘，恢复时顺序与当前一致
      await FeedCache.saveCalendar(
        bangumiCalendar.map((e) => e.toList()).toList(),
        season,
      );
    }
  }

  bool _backgroundRefreshing = false;

  /// 同季度缓存过期后的静默刷新：旧数据继续展示，新数据到了再替换。
  Future<void> _refreshCalendarInBackground(String season) async {
    if (_backgroundRefreshing) return;
    _backgroundRefreshing = true;
    try {
      final resBangumiCalendar = await _fetchSeasonCalendar();
      final empty =
          resBangumiCalendar.every((innerList) => innerList.isEmpty);
      if (empty) return;
      if (AnimeSeason(selectedDate).toString() != season) return;
      runInAction(() {
        bangumiCalendar
          ..clear()
          ..addAll(resBangumiCalendar);
      });
      changeSortType(sortType);
      await FeedCache.saveCalendar(
        bangumiCalendar.map((e) => e.toList()).toList(),
        season,
      );
    } finally {
      _backgroundRefreshing = false;
    }
  }

  /// 按页拉当季国漫，某一页空了就停，避免固定打满 4 次空请求。
  Future<List<List<BangumiItem>>> _fetchSeasonCalendar() async {
    const maxTime = 4;
    const limit = 20;
    final resBangumiCalendar = List.generate(7, (_) => <BangumiItem>[]);
    for (var time = 0; time < maxTime; time++) {
      final offset = time * limit;
      final newList = await BangumiApi.getCalendarBySearch(
        AnimeSeason(selectedDate).toSeasonStartAndEnd(),
        limit,
        offset,
      );
      var added = 0;
      for (var i = 0; i < resBangumiCalendar.length; ++i) {
        added += newList[i].length;
        resBangumiCalendar[i].addAll(newList[i]);
      }
      if (added == 0) break;
    }
    return resBangumiCalendar;
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
