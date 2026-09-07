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

  /// 分类浏览的累计已请求条数（服务器侧游标）。
  /// 不能用去重后的列表长度：存在重复项时游标不前进会原地循环。
  int _tagOffset = 0;

  /// 列表非空时最近一次「加载更多」是否失败（页面据此显示重试入口）。
  ///
  /// 非 observable：与 isLoadingMore 在同一个 action 事务内写入，
  /// Observer 由 isLoadingMore 的通知触发重建，重建时即可读到最新值，
  /// 避免改动 mobx 注解成员、不需要重新跑 build_runner。
  bool loadMoreFailed = false;

  /// 最近一次「加载更多失败」 toast 的时间（N3）：死网下滚动监听
  /// 会反复触发翻页失败请求，5s 窗口内只提示一次，避免 toast 刷屏。
  DateTime? _lastLoadMoreFailedToastAt;

  void _toastLoadMoreFailed() {
    final now = DateTime.now();
    final last = _lastLoadMoreFailedToastAt;
    if (last != null &&
        now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastLoadMoreFailedToastAt = now;
    MiruDialog.showToast(message: '加载更多失败，请检查网络后重试');
  }

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
    // C1/C2：'init'（主动刷新/切回热门）不再先清空列表——请求期间
    // 旧内容继续展示，先取到局部 sink 里，成功后一次性替换，
    // 避免「列表被抽掉」的闪空；失败时旧内容原样保留。
    final isInit = type == 'init';
    if (isInit) {
      _trendOffset = 0;
      _featuredLoaded = false;
    }
    isLoadingMore = true;
    loadMoreFailed = false;
    final sink = isInit ? <BangumiItem>[] : trendList;

    // 首屏先铺置顶清单：封面轮播取列表前几条，因此这里决定了「封面推荐」的内容。
    if (!_featuredLoaded) {
      _featuredLoaded = true;
      final featured =
          await BangumiApi.getBangumiListByIds(kFeaturedBangumiIds);
      final seen = sink.map((e) => e.id).toSet();
      sink.addAll(featured.where((e) => seen.add(e.id)));
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
      } else {
        // 列表已有内容：翻页失败不再静默，给出提示与底部重试入口
        // （toast 节流见 N3）
        loadMoreFailed = true;
        _toastLoadMoreFailed();
      }
      return;
    }
    // 必须按**实际返回条数**推进 offset。
    // 之前固定 += _trendPageSize，而接口返回数可能小于请求的 limit，
    // 会导致每翻一页跳过若干条目（内容凭空消失）。
    if (result.isNotEmpty) {
      _trendOffset += result.length;
    }
    final existingIds = sink.map((item) => item.id).toSet();
    sink.addAll(result.where((item) => existingIds.add(item.id)));
    if (isInit) {
      // 一次性替换：clear+addAll 在同一同步段内完成，
      // 观察者不会看到中间的空列表（见 C1/C2）。
      trendList
        ..clear()
        ..addAll(sink);
    }
    // 落盘：下次启动直接读这份，不再联网
    await FeedCache.savePopular(trendList.toList(), offset: _trendOffset);
    // 成功后重置 toast 节流窗：下次失败（哪怕在 5s 内）仍会提示。
    _lastLoadMoreFailedToastAt = null;
    isLoadingMore = false;
    isTimeOut = trendList.isEmpty;
  }

  @action
  Future<void> queryBangumiByTag({String type = 'add'}) async {
    // C1：切 tag 同样不在请求前清空——首切进空分类时页面铺骨架，
    // 非空时保留旧内容直到替换；失败则清空回到错误态，避免
    // 「新标签标题 + 旧标签内容」的错位残留。
    final isInit = type == 'init';
    if (isInit) {
      _tagOffset = 0;
    }
    isLoadingMore = true;
    loadMoreFailed = false;
    var tag = currentTag;
    final sink = isInit ? <BangumiItem>[] : bangumiList;
    // 分类浏览同样限定产地，并用 offset 翻页。
    // offset 用累计已请求条数（服务器侧游标），而非去重后的列表长度：
    // 返回重复项时列表长度不前进，旧写法会一直重拉同一页。
    final List<BangumiItem> result;
    try {
      result = await BangumiApi.getBangumiList(
        tag: tag,
        offset: _tagOffset,
      );
    } catch (e) {
      isLoadingMore = false;
      if (isInit) bangumiList.clear();
      isTimeOut = bangumiList.isEmpty;
      if (isTimeOut) {
        MiruDialog.showToast(message: '分类加载失败，请检查网络后重试');
      } else {
        // 列表已有内容：翻页失败不再静默，给出提示与底部重试入口
        // （toast 节流见 N3）
        loadMoreFailed = true;
        _toastLoadMoreFailed();
      }
      return;
    }
    // 与推荐流一致：按实际返回条数推进服务器侧游标
    if (result.isNotEmpty) {
      _tagOffset += result.length;
    }
    final existingIds = sink.map((item) => item.id).toSet();
    sink.addAll(result.where((item) => existingIds.add(item.id)));
    if (isInit) {
      // 一次性替换：clear+addAll 在同一同步段内完成（见 C1）。
      bangumiList
        ..clear()
        ..addAll(sink);
    }
    // 成功后重置 toast 节流窗：下次失败（哪怕在 5s 内）仍会提示。
    _lastLoadMoreFailedToastAt = null;
    isLoadingMore = false;
    isTimeOut = bangumiList.isEmpty;
  }
}
