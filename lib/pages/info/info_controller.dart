import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/bangumi/bangumi_interest.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/bangumi/bangumi_relation.dart';
import 'package:miru/pages/collect/collect_controller.dart';
import 'package:miru/modules/search/plugin_search_module.dart';
import 'package:miru/pages/info/rating_review_dialog.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:mobx/mobx.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/modules/comments/comment_item.dart';
import 'package:miru/modules/characters/character_item.dart';
import 'package:miru/modules/staff/staff_item.dart';

part 'info_controller.g.dart';

class InfoController = _InfoController with _$InfoController;

abstract class _InfoController with Store {
  _InfoController(this.collectController);

  final CollectController collectController;
  late BangumiItem bangumiItem;

  @observable
  bool isLoading = false;

  @observable
  var pluginSearchResponseList = ObservableList<PluginSearchResponse>();

  @observable
  var pluginSearchStatus = ObservableMap<String, PluginSearchStatus>();

  @observable
  var commentsList = ObservableList<CommentItem>();

  @observable
  var characterList = ObservableList<CharacterItem>();

  @observable
  var staffList = ObservableList<StaffFullItem>();

  @observable
  var relationList = ObservableList<BangumiRelation>();

  @observable
  bool relationsIsLoading = false;

  @observable
  bool relationsQueryTimeout = false;

  @observable
  bool relationsHasLoaded = false;

  int _relationRequestGeneration = 0;

  bool _isFillingInterestUserProfile = false;

  int _commentsOffset = 0;

  void clearComments() {
    commentsList.clear();
    _commentsOffset = 0;
  }

  Future<bool> fillInterestUserProfileIfNeeded() async {
    final interest = bangumiItem.interest;
    if (interest == null || interest.hasUserProfile) {
      return false;
    }
    if (_isFillingInterestUserProfile) {
      return false;
    }
    _isFillingInterestUserProfile = true;
    try {
      final user = await BangumiApi.getCurrentUser();
      if (user == null) {
        return false;
      }
      bangumiItem.interest = interest.copyWithUser(user: user);
      await collectController.updateLocalCollect(bangumiItem);
      return true;
    } catch (e) {
      MiruLogger()
          .e('InfoController: failed to fill interest user profile', error: e);
      return false;
    } finally {
      _isFillingInterestUserProfile = false;
    }
  }

  void _removeCurrentUserFromPublicComments() {
    final interest = bangumiItem.interest;
    if (interest == null) return;
    final userId = interest.user?.id;
    if (userId == null) return;
    commentsList.removeWhere((item) => item.user.id == userId);
  }

  Future<void> queryBangumiInfoByID(int id, {String type = "init"}) async {
    isLoading = true;
    try {
      await _updateBangumiInfoByID(id, type: type);
    } finally {
      isLoading = false;
    }
  }

  Future<void> refreshBangumiInfoByID(int id) async {
    await _updateBangumiInfoByID(id, type: "update");
  }

  Future<void> _updateBangumiInfoByID(int id, {required String type}) async {
    final value = await BangumiApi.getBangumiInfoByID(id);
    if (value == null) {
      return;
    }
    if (type == "init") {
      bangumiItem = value;
    } else {
      bangumiItem.summary = value.summary;
      bangumiItem.tags = value.tags;
      bangumiItem.rank = value.rank;
      bangumiItem.airDate = value.airDate;
      bangumiItem.airWeekday = value.airWeekday;
      bangumiItem.alias = value.alias;
      bangumiItem.ratingScore = value.ratingScore;
      bangumiItem.votes = value.votes;
      bangumiItem.votesCount = value.votesCount;
      final incomingInterest = value.interest;
      final previousInterest = bangumiItem.interest;
      if (incomingInterest == null) {
        bangumiItem.interest = null;
      } else if (previousInterest == null || !previousInterest.hasUserProfile) {
        bangumiItem.interest = incomingInterest;
      } else {
        bangumiItem.interest =
            incomingInterest.copyWithUser(user: previousInterest.user);
      }
    }
    await collectController.updateLocalCollect(bangumiItem);
  }

  Future<void> queryBangumiCommentsByID(int id, {bool refresh = true}) async {
    await _updateBangumiCommentsByID(
      id,
      refresh: refresh,
      clearBeforeFetch: true,
    );
  }

  Future<void> _updateBangumiCommentsByID(
    int id, {
    required bool refresh,
    required bool clearBeforeFetch,
  }) async {
    if (refresh) {
      if (clearBeforeFetch) {
        clearComments();
      }
    }
    final offset = refresh ? 0 : _commentsOffset;
    await BangumiApi.getBangumiCommentsByID(id, offset: offset).then((value) {
      if (refresh && !clearBeforeFetch) {
        commentsList = ObservableList<CommentItem>.of(value.commentList);
      } else {
        commentsList.addAll(value.commentList);
      }
      _commentsOffset = refresh
          ? value.commentList.length
          : _commentsOffset + value.commentList.length;
      _removeCurrentUserFromPublicComments();
    });
    MiruLogger().i(
        'InfoController: loaded comments list length ${commentsList.length}, offset $_commentsOffset');
  }

  Future<void> refreshBangumiCommentsSilently(int id) async {
    if (commentsList.isEmpty) {
      return;
    }
    await _updateBangumiCommentsByID(
      id,
      refresh: true,
      clearBeforeFetch: false,
    );
  }

  /// 角色/制作人员请求的代际计数：详情页可被快速进出，
  /// 旧条目的迟到响应不允许写回新条目刚清空的列表（与关联的同款守卫）。
  int _characterRequestGeneration = 0;
  int _staffRequestGeneration = 0;

  Future<void> queryBangumiCharactersByID(int id) async {
    final requestGeneration = ++_characterRequestGeneration;
    characterList.clear();
    final value = await BangumiApi.getCharatersByBangumiID(id);
    if (requestGeneration != _characterRequestGeneration) {
      return; // 过期响应：期间条目已切换，静默丢弃。
    }
    characterList.addAll(value.charactersList);
    Map<String, int> relationValue = {
      '主角': 1,
      '配角': 2,
      '客串': 3,
    };

    try {
      characterList.sort((a, b) {
        int valueA = relationValue[a.relation] ?? 4;
        int valueB = relationValue[b.relation] ?? 4;
        return valueA.compareTo(valueB);
      });
    } catch (e) {
      // 排序失败不影响展示（保留原顺序），不把原始异常直接抛给用户
      MiruLogger().w('InfoController: sort characters failed', error: e);
      MiruDialog.showToast(message: '角色列表排序失败，已按默认顺序展示');
    }
    MiruLogger().i(
        'InfoController: loaded character list length ${characterList.length}');
  }

  Future<void> queryBangumiStaffsByID(int id) async {
    final requestGeneration = ++_staffRequestGeneration;
    staffList.clear();
    final value = await BangumiApi.getBangumiStaffByID(id);
    if (requestGeneration != _staffRequestGeneration) {
      return; // 过期响应：期间条目已切换，静默丢弃。
    }
    staffList.addAll(value.data);
    MiruLogger()
        .i('InfoController: loaded staff list length ${staffList.length}');
  }

  @action
  void clearRelations() {
    _relationRequestGeneration++;
    relationList = ObservableList<BangumiRelation>();
    relationsIsLoading = false;
    relationsQueryTimeout = false;
    relationsHasLoaded = false;
  }

  /// 条目切换/页面销毁时失效在途的角色与制作人员请求。
  /// info_page 直接 clear 列表的同时必须调用本方法，
  /// 否则旧条目的迟到响应会写进新条目刚清空的列表。
  @action
  void invalidateAncillaryRequests() {
    _characterRequestGeneration++;
    _staffRequestGeneration++;
  }

  bool get canLoadRelations =>
      !relationsHasLoaded && !relationsIsLoading && !relationsQueryTimeout;

  @action
  Future<void> queryBangumiRelationsByID(int id) async {
    if (relationsIsLoading) return;

    final requestGeneration = ++_relationRequestGeneration;
    relationsIsLoading = true;
    relationsQueryTimeout = false;
    relationsHasLoaded = false;
    try {
      final relations = await resolveRelatedAnimeChain(
        currentSubjectId: id,
        fetchRelations: BangumiApi.getBangumiRelationsByID,
      );
      if (!_isCurrentRelationRequest(requestGeneration, id)) {
        return;
      }
      relationList = ObservableList<BangumiRelation>.of(relations);
      relationsHasLoaded = true;
      MiruLogger().i(
        'InfoController: loaded related anime list length ${relationList.length}',
      );
    } catch (_) {
      if (_isCurrentRelationRequest(requestGeneration, id)) {
        relationsQueryTimeout = true;
        rethrow;
      }
    } finally {
      if (_isCurrentRelationRequest(requestGeneration, id)) {
        relationsIsLoading = false;
      }
    }
  }

  bool _isCurrentRelationRequest(int requestGeneration, int subjectId) =>
      requestGeneration == _relationRequestGeneration &&
      bangumiItem.id == subjectId;

  Future<bool> rateBangumi(RatingReviewResult data,
      {required int localType}) async {
    final trimmedComment = data.comment.trim();
    if (await BangumiApi.addOrUpdateBangumiEvaluationBySubjectID(
      bangumiItem.id,
      localType,
      comment: trimmedComment.isNotEmpty ? trimmedComment : null,
      rate: data.score > 0 ? data.score : 0,
      tags: data.tags.isNotEmpty ? data.tags : null,
    )) {
      bangumiItem.interest = BangumiInterest.mergeLocalSubmission(
        previous: bangumiItem.interest,
        rate: data.score,
        comment: trimmedComment,
        tags: data.tags,
      );
      await collectController.updateLocalCollect(bangumiItem);
      await fillInterestUserProfileIfNeeded();
      _removeCurrentUserFromPublicComments();
      await refreshBangumiCommentsSilently(bangumiItem.id);
      await refreshBangumiInfoByID(bangumiItem.id);
      return true;
    }
    return false;
  }
}
