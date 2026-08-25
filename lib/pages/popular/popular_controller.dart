import 'package:miru/services/storage/feed_cache.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/request/config/featured_bangumi.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:mobx/mobx.dart';

part 'popular_controller.g.dart';

class PopularController = _PopularController with _$PopularController;

abstract class _PopularController with Store {
  /// 接口每页上限为 20，请求更大的 limit 也只会返回 20 条。
  static const int _trendPageSize = 20;

  int _trendOffset = 0;

  @observable
  String currentTag = '';

  @observable
  ObservableList<BangumiItem> bangumiList = ObservableList.of([]);

  @observable
  ObservableList<BangumiItem> trendList = ObservableList.of([]);

  double scrollOffset = 0.0;

  @observable
  bool isLoadingMore = false;

  @observable
  bool isTimeOut = false;


  void setCurrentTag(String s) {
    currentTag = s;
  }

  void clearBangumiList() {
    bangumiList.clear();
  }

  // Async actions commit each segment between awaits as one transaction,
  // batching the completion writes into a single notification.
  /// 置顶清单只需拉取一次，之后翻页复用。
  bool _featuredLoaded = false;

  /// 本次运行是否已尝试过读本地缓存。
  bool _cacheRestored = false;

  /// 从本地缓存恢复推荐页。
  ///
  /// 命中缓存时完全不联网 —— 这正是「加载一次之后不用每次重来」的关键。
  /// 只有缓存为空、或用户主动刷新（[refresh]）时才走网络。
  @action
  bool restoreFromCache() {
    if (_cacheRestored || trendList.isNotEmpty) return trendList.isNotEmpty;
    _cacheRestored = true;
    if (!FeedCache.hasPopular) return false;
    final cached = FeedCache.loadPopular();
    if (cached.isEmpty) return false;
    trendList.addAll(cached);
    _trendOffset = FeedCache.popularOffset;
    _featuredLoaded = true;
    isTimeOut = false;
    return true;
  }

  /// 用户主动刷新：丢弃缓存重新联网。
  @action
  Future<void> refresh() async {
    _cacheRestored = true;
    await queryBangumiByTrend(type: 'init');
  }

  @action
  Future<void> queryBangumiByTrend({String type = 'add'}) async {
    if (type == 'init') {
      trendList.clear();
      _trendOffset = 0;
      _featuredLoaded = false;
    }
    isLoadingMore = true;

    // 首屏先铺置顶清单：封面轮播取列表前几条，因此这里决定了「封面推荐」的内容。
    if (!_featuredLoaded) {
      _featuredLoaded = true;
      final featured =
          await BangumiApi.getBangumiListByIds(kFeaturedBangumiIds);
      final seen = trendList.map((e) => e.id).toSet();
      trendList.addAll(featured.where((e) => seen.add(e.id)));
    }

    // 置顶之后再接算法推荐（按热度的国漫），域名由拦截器重写到公共反代。
    final List<BangumiItem> result;
    try {
      result = await BangumiApi.getBangumiList(
        limit: _trendPageSize,
        offset: _trendOffset,
      );
    } catch (e) {
      isLoadingMore = false;
      isTimeOut = trendList.isEmpty;
      if (isTimeOut) {
        MiruDialog.showToast(message: '推荐加载失败，请检查网络后重试');
      }
      return;
    }
    // 必须按**实际返回条数**推进 offset。
    // 之前固定 += _trendPageSize，而接口返回数可能小于请求的 limit，
    // 会导致每翻一页跳过若干条目（内容凭空消失）。
    if (result.isNotEmpty) {
      _trendOffset += result.length;
    }
    final existingIds = trendList.map((item) => item.id).toSet();
    trendList.addAll(result.where((item) => existingIds.add(item.id)));
    // 落盘：下次启动直接读这份，不再联网
    await FeedCache.savePopular(trendList.toList(), offset: _trendOffset);
    isLoadingMore = false;
    isTimeOut = trendList.isEmpty;
  }

  @action
  Future<void> queryBangumiByTag({String type = 'add'}) async {
    if (type == 'init') {
      bangumiList.clear();
    }
    isLoadingMore = true;
    var tag = currentTag;
    // 分类浏览同样限定产地，并用 offset 翻页
    final List<BangumiItem> result;
    try {
      result = await BangumiApi.getBangumiList(
        tag: tag,
        offset: bangumiList.length,
      );
    } catch (e) {
      isLoadingMore = false;
      isTimeOut = bangumiList.isEmpty;
      if (isTimeOut) {
        MiruDialog.showToast(message: '分类加载失败，请检查网络后重试');
      }
      return;
    }
    final existingIds = bangumiList.map((item) => item.id).toSet();
    bangumiList.addAll(result.where((item) => existingIds.add(item.id)));
    isLoadingMore = false;
    isTimeOut = bangumiList.isEmpty;
  }
}
