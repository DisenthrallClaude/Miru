import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/history/history_module.dart';
import 'package:miru/repositories/history_repository.dart';
import 'package:mobx/mobx.dart';

part 'history_controller.g.dart';

class HistoryController = _HistoryController with _$HistoryController;

abstract class _HistoryController with Store {
  _HistoryController(this._historyRepository);

  final IHistoryRepository _historyRepository;

  @observable
  ObservableList<History> histories = ObservableList<History>();

  void init() {
    final temp = _historyRepository.getAllHistories();
    histories.clear();
    histories.addAll(temp);
  }

  Future<void> updateHistory(
    PlaybackHistoryIdentity identity,
    Duration progress, {
    Duration duration = Duration.zero,
  }) async {
    await _historyRepository.updateHistory(
      identity: identity,
      progress: progress,
      duration: duration,
    );
    // 播放期间每秒都会走到这里：绝不能 init() 全量重建列表
    // （那是整表扫描 + O(n) 重建）。按 key 单条取回后就地替换，
    // ObservableList 只通知这一项的变化。
    final updated = _historyRepository.getHistory(
      identity.pluginName,
      identity.bangumiItem,
      entryKind: identity.entryKind,
    );
    if (updated == null) {
      return;
    }
    final index = histories.indexWhere(
      (h) =>
          h.key == updated.key ||
          (h.adapterName == identity.pluginName &&
              h.bangumiItem.id == identity.bangumiItem.id &&
              HistoryEntryKind.normalize(h.entryKind) ==
                  HistoryEntryKind.normalize(identity.entryKind)),
    );
    if (index == -1) {
      // 首次观看产生的新记录：插入到列表头部（历史页按时间倒序）。
      histories.insert(0, updated);
      return;
    }
    histories[index] = updated;
  }

  Progress? lastWatching(
    BangumiItem bangumiItem,
    String adapterName, {
    String entryKind = HistoryEntryKind.online,
  }) {
    return _historyRepository.getLastWatchingProgress(
      bangumiItem,
      adapterName,
      entryKind: entryKind,
    );
  }

  Progress? findProgress(
    BangumiItem bangumiItem,
    String adapterName,
    int episode, {
    String entryKind = HistoryEntryKind.online,
  }) {
    return _historyRepository.findProgress(
      bangumiItem,
      adapterName,
      episode,
      entryKind: entryKind,
    );
  }

  Future<void> deleteHistory(History history) async {
    await _historyRepository.deleteHistory(history);
    init();
  }

  Future<void> clearAll() async {
    await _historyRepository.clearAllHistories();
    histories.clear();
  }
}
