import 'dart:io';

import 'package:mobx/mobx.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/collect/collect_type.dart';
import 'package:miru/modules/search/image_search_module.dart';
import 'package:miru/modules/search/search_history_module.dart';
import 'package:miru/repositories/collect_repository.dart';
import 'package:miru/repositories/search_history_repository.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:miru/request/apis/trace_api.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/utils/search_parser.dart';

part 'search_controller.g.dart';

class SearchPageController = _SearchPageController with _$SearchPageController;

abstract class _SearchPageController with Store {
  static const int _searchPageSize = 20;
  static const int _maxPagesPerSearch = 3;

  _SearchPageController(
    this._collectRepository,
    this._searchHistoryRepository,
  );

  final ICollectRepository _collectRepository;
  final ISearchHistoryRepository _searchHistoryRepository;

  int _searchOffset = 0;

  bool hasMoreSearchResults = true;

  /// 最近一次搜索是否因网络异常失败（与「无结果」分开渲染）。
  ///
  /// 非 observable：与 isTimeOut / isLoading 在同一个 action 事务内写入，
  /// Observer 由后两者的通知触发重建，重建时即可读到最新值，
  /// 这样可以不动 mobx 注解成员、避免重新跑 build_runner。
  bool searchNetworkError = false;

  /// 列表非空时「加载更多」失败：页面据此在底部显示重试入口。
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
  bool isLoading = false;

  @observable
  bool isTimeOut = false;

  @observable
  bool notShowWatchedBangumis = false;

  @observable
  bool notShowAbandonedBangumis = false;

  @observable
  ObservableList<BangumiItem> bangumiList = ObservableList.of([]);

  @observable
  ObservableList<SearchHistory> searchHistories = ObservableList.of([]);

  @observable
  bool isImageSearching = false;

  @observable
  String imageSearchError = '';

  @observable
  ObservableList<ResultItem> imageSearchResults = ObservableList.of([]);

  @action
  void loadSearchHistories() {
    final histories = _searchHistoryRepository.getAllHistories();
    searchHistories.clear();
    searchHistories.addAll(histories);
  }

  @action
  Future<void> searchBangumi(String input, {String type = 'add'}) async {
    if (type != 'add') {
      bangumiList.clear();
      _searchOffset = 0;
      hasMoreSearchResults = true;
      bool privateMode = _collectRepository.getPrivateMode();
      if (!privateMode) {
        // 检查是否已满，删除最旧的记录
        if (_searchHistoryRepository.isHistoryFull(10)) {
          await _searchHistoryRepository.deleteOldest();
        }
        // 删除重复的历史记录
        await _searchHistoryRepository.deleteDuplicates(input);
        // 保存新的搜索历史
        await _searchHistoryRepository.saveHistory(input);
        // 重新加载历史记录
        loadSearchHistories();
      }
    }
    isLoading = true;
    isTimeOut = false;
    searchNetworkError = false;
    loadMoreFailed = false;
    SearchParser parser = SearchParser(input);
    final filterState = parser.toFilterState();
    String? idString = filterState.id.isEmpty ? null : filterState.id;
    if (idString != null) {
      final id = int.tryParse(idString);
      if (id != null) {
        final BangumiItem? item = await BangumiApi.getBangumiInfoByID(id);
        if (item != null) {
          bangumiList.add(item);
        }
        hasMoreSearchResults = false;
        isLoading = false;
        isTimeOut = bangumiList.isEmpty;
        return;
      }
    }
    var addedVisibleItems = false;
    var fetchedAnyPage = false;
    var pagesFetched = 0;
    var networkFailed = false;
    do {
      // 双契约兼容：FIX-F 落地后网络异常会直接抛出（catch 兜底转错误态）；
      // 落地前异常被吞成 null（同样按网络错误处理，而不是误判成「无结果」）。
      BangumiSearchPage? page;
      try {
        page = await BangumiApi.bangumiSearch(filterState.keyword,
            tags: filterState.tags,
            limit: _searchPageSize,
            offset: _searchOffset,
            sort: filterState.sort,
            dateRange: filterState.effectiveDateRange,
            rankRange: filterState.rankRange,
            scoreRange: filterState.scoreRange,
            weekdays: filterState.weekdays);
      } catch (e) {
        MiruLogger().w('Search: bangumiSearch failed', error: e);
        networkFailed = true;
        break;
      }
      if (page == null) {
        networkFailed = true;
        break;
      }
      fetchedAnyPage = true;
      pagesFetched++;
      _searchOffset += page.rawCount;
      hasMoreSearchResults = page.rawCount == _searchPageSize;
      final existingIds = bangumiList.map((item) => item.id).toSet();
      final newItems =
          page.items.where((item) => existingIds.add(item.id)).toList();
      if (newItems.isNotEmpty) {
        bangumiList.addAll(newItems);
        addedVisibleItems = true;
      }
    } while (!addedVisibleItems &&
        hasMoreSearchResults &&
        pagesFetched < _maxPagesPerSearch);
    isLoading = false;
    if (networkFailed) {
      if (bangumiList.isEmpty) {
        // 首屏即失败：渲染独立的「网络异常」错误态（与无结果区分）
        searchNetworkError = true;
      } else {
        // 翻页失败：列表已有内容，提示 + 底部重试入口（toast 节流见 N3）
        loadMoreFailed = true;
        _toastLoadMoreFailed();
      }
      return;
    }
    // 成功后重置节流窗：下次失败（哪怕在 5s 内）仍会提示。
    _lastLoadMoreFailedToastAt = null;
    isTimeOut =
        bangumiList.isEmpty && (!fetchedAnyPage || !hasMoreSearchResults);
  }

  @action
  Future<void> deleteSearchHistory(SearchHistory history) async {
    await _searchHistoryRepository.deleteHistory(history);
    loadSearchHistories();
  }

  @action
  Future<void> clearSearchHistory() async {
    await _searchHistoryRepository.clearAllHistories();
    loadSearchHistories();
  }

  @action
  void clearImageSearchState() {
    isImageSearching = false;
    imageSearchError = '';
    imageSearchResults.clear();
  }

  @action
  Future<void> searchImageByFile(File imageFile) async {
    isImageSearching = true;
    imageSearchError = '';
    imageSearchResults.clear();
    try {
      final result = await TraceApi.searchAnimeByImageFile(imageFile);
      imageSearchResults.addAll(result.result ?? []);
      if (result.error != null && result.error!.isNotEmpty) {
        imageSearchError = result.error!;
      } else if (imageSearchResults.isEmpty) {
        imageSearchError = '未找到匹配结果';
      }
    } catch (e) {
      imageSearchError = '图片搜索失败，请稍后重试';
    } finally {
      isImageSearching = false;
    }
  }

  @action
  Future<void> searchImageByUrl(String imageUrl) async {
    isImageSearching = true;
    imageSearchError = '';
    imageSearchResults.clear();
    try {
      final result = await TraceApi.searchAnimeByImageUrl(imageUrl);
      imageSearchResults.addAll(result.result ?? []);
      if (result.error != null && result.error!.isNotEmpty) {
        imageSearchError = result.error!;
      } else if (imageSearchResults.isEmpty) {
        imageSearchError = '未找到匹配结果';
      }
    } catch (e) {
      imageSearchError = '图片搜索失败，请检查图片地址或稍后重试';
    } finally {
      isImageSearching = false;
    }
  }

  @action
  Future<void> setNotShowWatchedBangumis(bool value) async {
    notShowWatchedBangumis = value;
  }

  @action
  Future<void> setNotShowAbandonedBangumis(bool value) async {
    notShowAbandonedBangumis = value;
  }

  Set<int> loadWatchedBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.watched);
  }

  Set<int> loadAbandonedBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.abandoned);
  }
}
