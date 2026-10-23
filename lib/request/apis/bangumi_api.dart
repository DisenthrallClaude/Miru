import 'package:miru/request/apis/season_schedule.dart';
import 'package:miru/utils/anime_categories.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/clients/bangumi_client.dart';
import 'package:miru/request/core/network_error_mapper.dart';
import 'package:miru/request/core/network_exception.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/bangumi/bangumi_relation.dart';
import 'package:miru/modules/comments/comment_response.dart';
import 'package:miru/modules/characters/characters_response.dart';
import 'package:miru/modules/bangumi/episode_item.dart';
import 'package:miru/modules/character/character_full_item.dart';
import 'package:miru/modules/staff/staff_response.dart';
import 'package:miru/modules/bangumi/bangumi_collection.dart';
import 'package:miru/modules/collect/collect_type.dart';
import 'package:miru/modules/collect/collect_type_mapper.dart';
import 'package:miru/modules/bangumi/bangumi_collection_type.dart';
import 'package:miru/modules/comments/comment_item.dart';
import 'package:miru/utils/search_parser.dart';

class BangumiSearchPage {
  const BangumiSearchPage({
    required this.items,
    required this.rawCount,
  });

  final List<BangumiItem> items;
  final int rawCount;
}

class BangumiApi {
  static final BangumiClient _client = BangumiClient.instance;

  static Future<List<List<BangumiItem>>> getCalendar() async {
    List<List<BangumiItem>> bangumiCalendar = [];
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiCalendar,
      );
      for (int i = 1; i <= 7; i++) {
        List<BangumiItem> bangumiList = [];
        final jsonList = jsonData['$i'];
        for (dynamic jsonItem in jsonList) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem['subject']);
            bangumiList.add(bangumiItem);
          } catch (_) {}
        }
        bangumiCalendar.add(bangumiList);
      }
    } catch (e) {
      MiruLogger().e('Resolve calendar failed', error: e);
      // 网络失败必须与「确实没有数据」区分开，否则首页会把故障渲染成空页面。
      rethrow;
    }
    return bangumiCalendar;
  }

  // Official fallback for season switching. Mirror mode uses the cached
  // /miru/v1/calendar/season endpoint instead of Bangumi search.
  static Future<List<List<BangumiItem>>> getCalendarBySearch(
      List<String> dateRange, int limit, int offset) async {
    List<BangumiItem> bangumiList = [];
    List<List<BangumiItem>> bangumiCalendar = [];
    var params = <String, dynamic>{
      "keyword": "",
      "sort": "rank",
      "filter": {
        "type": [2],
        // 产地过滤，默认只出国漫
        "tag": [ApiEndpoints.bangumiRegionTag],
        "air_date": [">=${dateRange[0]}", "<${dateRange[1]}"],
        // 不加 rank 过滤：实测当季国漫加了 rank>0 只剩 3 部，
        // 去掉后是 48 部 —— 新番普遍还没有排名。
        "nsfw": true
      }
    };
    try {
      final url = ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
          [limit, offset]);
      final jsonData = await _client.post(
        url,
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      MiruLogger().e('Resolve bangumi list failed', error: e);
      rethrow;
    }
    try {
      for (int weekday = 1; weekday <= 7; weekday++) {
        List<BangumiItem> bangumiDayList = [];
        for (BangumiItem bangumiItem in bangumiList) {
          if (bangumiItem.airWeekday == weekday) {
            bangumiDayList.add(bangumiItem);
          }
        }
        bangumiCalendar.add(bangumiDayList);
      }
    } catch (e) {
      MiruLogger()
          .e('Network: fetch bangumi item to calendar failed', error: e);
    }
    return bangumiCalendar;
  }

  /// v1.8.1：条目搜索原始结果（保留 infobox/platform/eps，时间表判定更新日要用）。
  static Future<(int, List<Map<String, dynamic>>)> searchSubjectsRaw(
    Map<String, dynamic> filter, {
    int limit = 20,
    int offset = 0,
    String sort = 'rank',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final jsonData = await _client
        .post(
          ApiEndpoints.formatUrl(
              ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
              [limit, offset]),
          data: {'keyword': '', 'sort': sort, 'filter': filter},
        )
        .timeout(timeout);
    final total = jsonData['total'] is int ? jsonData['total'] as int : 0;
    final list = <Map<String, dynamic>>[];
    for (final e in (jsonData['data'] as List? ?? const [])) {
      if (e is Map<String, dynamic>) list.add(e);
      if (e is Map && e is! Map<String, dynamic>) {
        list.add(Map<String, dynamic>.from(e));
      }
    }
    return (total, list);
  }

  /// 拉取一个过滤条件下的全部条目：先取第一页拿到 total，其余页并发
  /// （至多 [concurrency] 路、[maxPages] 页）。v1.8.0 是逐页串行，
  /// 10 页 × 往返延迟 = 时间表加载慢的主因之一。
  static Future<List<Map<String, dynamic>>> searchAllSubjectsRaw(
    Map<String, dynamic> filter, {
    int maxPages = 10,
    int concurrency = 4,
  }) async {
    const limit = 20;
    final (total, first) = await searchSubjectsRaw(filter, limit: limit);
    final pages = ((total + limit - 1) ~/ limit).clamp(1, maxPages);
    final results = List<List<Map<String, dynamic>>?>.filled(pages, null);
    results[0] = first;
    var next = 1;
    Future<void> worker() async {
      while (true) {
        final page = next++;
        if (page >= pages) return;
        try {
          final (_, list) = await searchSubjectsRaw(filter,
              limit: limit, offset: page * limit);
          results[page] = list;
        } catch (e) {
          // 单页失败重试一次，仍失败就跳过这一页（不让一页拖垮整张表）
          try {
            final (_, list) = await searchSubjectsRaw(filter,
                limit: limit, offset: page * limit);
            results[page] = list;
          } catch (e2) {
            MiruLogger().w('Schedule: page $page failed', error: e2);
          }
        }
      }
    }

    await Future.wait(
        List.generate(concurrency.clamp(1, pages), (_) => worker()));
    return [for (final r in results) ...?r];
  }

  /// v1.8.1：官方每日放送表 id → 星期（1=周一…7=周日）。失败返回空表。
  static Future<Map<int, int>> getOfficialWeekdays() async {
    try {
      final jsonData = await _client
          .get(ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiCalendar)
          .timeout(const Duration(seconds: 8));
      final out = <int, int>{};
      for (var d = 1; d <= 7; d++) {
        final list = jsonData['$d'];
        if (list is! List) continue;
        for (final e in list) {
          final id = e is Map && e['subject'] is Map ? e['subject']['id'] : null;
          if (id is int) out[id] = d;
        }
      }
      return out;
    } catch (e) {
      MiruLogger().w('Schedule: official calendar unavailable', error: e);
      return const {};
    }
  }

  /// v1.8.1：季度时间表（替代逐页串行 + 首播星期分组的 getCalendarBySearch）。
  ///
  /// * 本季窗口条目、官方放送表并发拉取；
  /// * [includeContinuing]（当季视图）额外拉「首播在窗口前 12 个月内」的国漫，
  ///   只保留仍在连载的长篇；
  /// * 更新日判定见 lib/utils/broadcast_schedule.dart。
  static Future<ScheduleBuild> getSeasonSchedule(
    List<String> dateRange, {
    bool includeContinuing = false,
    DateTime? today,
  }) async {
    Map<String, dynamic> filterOf(String from, String to) => {
          'type': [2],
          'tag': [ApiEndpoints.bangumiRegionTag],
          'air_date': ['>=$from', '<$to'],
          'nsfw': true,
        };
    final seasonF = searchAllSubjectsRaw(filterOf(dateRange[0], dateRange[1]));
    final officialF = getOfficialWeekdays();
    Future<List<Map<String, dynamic>>> continuingF = Future.value(const []);
    if (includeContinuing) {
      final start = DateTime.parse(dateRange[0]);
      final from = DateTime(start.year - 1, start.month, start.day);
      String fmt(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      continuingF = searchAllSubjectsRaw(filterOf(fmt(from), dateRange[0]),
              maxPages: 15)
          .catchError((Object e) {
        MiruLogger().w('Schedule: continuing query failed', error: e);
        return <Map<String, dynamic>>[];
      });
    }
    final season = await seasonF;
    final official = await officialF;
    final continuing = await continuingF;
    final build = buildSeasonSchedule(
      seasonRaw: season,
      continuingRaw: continuing,
      official: official,
      today: today,
    );
    MiruLogger().i('Schedule: season=${season.length} continuing='
        '${continuing.length} official=${official.length} placed='
        '${build.sources.length} '
        'bySource=${build.sources.values.fold<Map<String, int>>({}, (m, v) => m..[v] = (m[v] ?? 0) + 1)}');
    return build;
  }

  // 注：原 getBangumiMirrorSeasonCalendar / getBangumiMirrorPopularSubjects
  // 已删除 —— 它们指向的上游镜像域名（api.miru.fyi）需要签名才能使用，
  // 且全仓无调用方；时间表与推荐页分别走 getCalendarBySearch /
  // getBangumiList，不再依赖该链路。

  /// 按产地（默认国漫）拉取番剧列表。
  ///
  /// 与原版的区别：
  /// * 产地标签取自 `ApiEndpoints.bangumiRegionTag`（'中国'），不再写死 '日本'；
  /// * 用户选中的分类标签与产地标签取交集，保证分类浏览也只出国漫；
  /// * 分页改为 offset —— 国漫条目基数远小于日番，原先靠随机 rank 区间
  ///   翻页很容易命中空区间，导致「加载不出来」。
  static Future<List<BangumiItem>> getBangumiList({
    String tag = '',
    int limit = 24,
    int offset = 0,
  }) async {
    List<BangumiItem> bangumiList = [];
    final params = buildBangumiListParams(tag: tag);
    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
            [limit, offset]),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem));
        }
      }
    } catch (e) {
      MiruLogger().e('Network: resolve bangumi list failed', error: e);
      // 必须上抛：推荐页/分类页的 catch 分支靠它置 isTimeOut 并提示重试。
      // 吞掉异常会把网络故障伪装成「空列表」，用户只会看到一片空白。
      rethrow;
    }
    return bangumiList;
  }

  /// 推荐流 / 分类浏览的搜索参数（v1.8.1 拆出便于单测）。
  ///
  /// * 推荐流（tag 为空）：沿用 v1.8.0 的产地用户标签「中国」+ 热度排序；
  /// * 分类：改用 Bangumi 公共标签 `meta_tags`（产地「中国」+ 分类题材），
  ///   不再用用户标签 `tag`——后者只要有人打过就命中，内容与分类名对不上
  ///   （详见 lib/utils/anime_categories.dart）。
  static Map<String, dynamic> buildBangumiListParams({String tag = ''}) {
    final filter = <String, dynamic>{
      "type": [2],
      if (tag.isEmpty) "tag": [ApiEndpoints.bangumiRegionTag],
      if (tag.isNotEmpty) "meta_tags": categoryMetaTags(tag),
      // 刻意不加 rank 过滤：新番往往尚未排名（rank=0），
      // 加了会把当season新作全部挡掉。
      "nsfw": false,
    };
    return <String, dynamic>{
      'keyword': '',
      // 按热度排序：rank 排序会把 1961 年的《大闹天宫》一类老片顶到最前。
      'sort': 'heat',
      "filter": filter,
    };
  }

  static Future<List<BangumiItem>> getBangumiTrendsList(
      {int type = 2, int limit = 24, int offset = 0}) async {
    List<BangumiItem> bangumiList = [];
    var params = <String, dynamic>{
      'type': type,
      'limit': limit,
      'offset': offset,
    };
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPINextDomain + ApiEndpoints.bangumiTrendsNext,
        queryParameters: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          bangumiList.add(BangumiItem.fromJson(jsonItem['subject']));
        }
      }
    } catch (e) {
      MiruLogger().e('Network: resolve bangumi trends list failed', error: e);
      rethrow;
    }
    return bangumiList;
  }

  static List<String> _buildNumberFilter<T extends num>(T? min, T? max) {
    return [
      if (min != null) '>=$min',
      if (max != null) '<=$max',
    ];
  }

  static Map<String, dynamic> buildBangumiSearchParams(
    String keyword, {
    List<String> tags = const [],
    String sort = 'heat',
    SearchDateRange? dateRange,
    SearchIntRange? rankRange,
    SearchDoubleRange? scoreRange,
    List<int> weekdays = const [],
  }) {
    final rankFilter = rankRange?.isValid == true
        ? _buildNumberFilter<int>(rankRange!.min, rankRange.max)
        : (sort == 'rank')
            ? [">0", "<=99999"]
            : [">=0", "<=99999"];

    final filter = <String, dynamic>{
      "type": [2],
      "tag": tags,
      "rank": rankFilter,
      "nsfw": false
    };

    if (dateRange?.isValid == true) {
      filter["air_date"] = [">=${dateRange!.start}", "<${dateRange.end}"];
    }
    if (scoreRange?.isValid == true) {
      filter["rating"] =
          _buildNumberFilter<double>(scoreRange!.min, scoreRange.max);
    }
    if (weekdays.isNotEmpty) {
      filter["air_weekday"] = weekdays.toSet().toList()..sort();
    }

    return <String, dynamic>{
      'keyword': keyword,
      'sort': sort,
      "filter": filter,
    };
  }

  static Future<BangumiSearchPage?> bangumiSearch(String keyword,
      {List<String> tags = const [],
      int limit = 20,
      int offset = 0,
      String sort = 'heat',
      SearchDateRange? dateRange,
      SearchIntRange? rankRange,
      SearchDoubleRange? scoreRange,
      List<int> weekdays = const []}) async {
    List<BangumiItem> bangumiList = [];

    final params = buildBangumiSearchParams(
      keyword,
      tags: tags,
      sort: sort,
      dateRange: dateRange,
      rankRange: rankRange,
      scoreRange: scoreRange,
      weekdays: weekdays,
    );

    try {
      final jsonData = await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRankSearch,
            [limit, offset]),
        data: params,
      );
      final jsonList = jsonData['data'];
      for (dynamic jsonItem in jsonList) {
        if (jsonItem is Map<String, dynamic>) {
          try {
            BangumiItem bangumiItem = BangumiItem.fromJson(jsonItem);
            if (bangumiItem.nameCn != '') {
              bangumiList.add(bangumiItem);
            }
          } catch (e) {
            MiruLogger()
                .e('Network: resolve search results failed', error: e);
          }
        }
      }
      return BangumiSearchPage(
        items: bangumiList,
        rawCount: jsonList.length,
      );
    } catch (e) {
      MiruLogger().e('Network: bangumi search failed', error: e);
      // 契约（FIX-D 依赖）：网络失败必须抛出异常而不是吞成 null——
      // 搜索页靠异常/非空双契约区分「网络错误」与「无结果」，
      // 否则网络故障会被渲染成空列表。网络层异常原样上抛，
      // 响应结构异常归入解析错误，仍走同一异常体系。
      if (e is NetworkException) rethrow;
      throw NetworkErrorMapper.parse(e, StackTrace.current);
    }
  }

  /// 按 id 批量拉取条目，用于首页置顶清单。
  ///
  /// Bangumi 没有批量接口，只能逐条取；这里限制并发，避免一次打出
  /// 几十个请求把反代打挂或触发限流。返回顺序与 [ids] 一致，
  /// 取失败的条目直接跳过（不阻塞其余内容展示）。
  static Future<List<BangumiItem>> getBangumiListByIds(
    List<int> ids, {
    int concurrency = 6,
  }) async {
    final results = List<BangumiItem?>.filled(ids.length, null);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor;
        if (index >= ids.length) return;
        cursor++;
        results[index] = await getBangumiInfoByID(ids[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < ids.length; i++) worker(),
    ]);

    return results.whereType<BangumiItem>().toList();
  }

  static Future<BangumiItem?> getBangumiInfoByID(int id) async {
    try {
      // v1.5.2：从 next.bgm.tv(/p1) 切到 api.bgm.tv(/v0)。
      // 原因：详情数据是首页轮播、详情页、置顶清单的共同依赖，
      // next.bgm.tv 国内可达性时好时坏，而配对的镜像
      // next.bangumi.lol 对非浏览器 UA 一律 403（Cloudflare 盾），
      // 竞速形同虚设——这正是「16:9 海报点了加载不出来」的根因。
      // api.bgm.tv 的镜像 bgmapi.anibt.net 实测稳定可用，
      // BangumiItem.fromJson 本就兼容 v0/next 双格式，零适配成本。
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiInfoByID,
            [id]),
      );
      return BangumiItem.fromJson(jsonData);
    } catch (e) {
      MiruLogger().e('Network: resolve bangumi item failed', error: e);
      return null;
    }
  }

  static Future<List<BangumiRelation>> getBangumiRelationsByID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
        ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiRelationsByID,
        [id],
      ),
    );
    if (jsonData is! List) {
      throw const FormatException('Bangumi relations response must be a list');
    }

    final relations = <BangumiRelation>[];
    for (final jsonItem in jsonData) {
      try {
        if (jsonItem is! Map) {
          throw const FormatException('Bangumi relation must be an object');
        }
        relations.add(
          BangumiRelation.fromJson(Map<String, dynamic>.from(jsonItem)),
        );
      } catch (e, stackTrace) {
        MiruLogger().w(
          'BangumiApi: skipped malformed relation item',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    return relations;
  }

  static Future<EpisodeInfo> getBangumiEpisodeByID(int id, int episode) async {
    EpisodeInfo episodeInfo = EpisodeInfo.fromTemplate();
    var params = <String, dynamic>{
      'subject_id': id,
      'offset': episode - 1,
      'limit': 1
    };
    try {
      final jsonData = await _client.get(
        ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiEpisodeByID,
        queryParameters: params,
      );
      episodeInfo = EpisodeInfo.fromJson(jsonData['data'][0]);
    } catch (e) {
      MiruLogger().e('Network: resolve bangumi episode failed', error: e);
      // 调用方（评论页）依赖异常区分「无评论」与「请求失败」。
      rethrow;
    }
    return episodeInfo;
  }

  static Future<List<EpisodeInfo>> getBangumiEpisodesByID(int id) async {
    final List<EpisodeInfo> episodeList = [];
    const int limit = 100;
    int offset = 0;
    int? total;
    try {
      do {
        final params = <String, dynamic>{
          'subject_id': id,
          'offset': offset,
          'limit': limit,
        };
        final jsonData = await _client.get(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiEpisodeByID,
          queryParameters: params,
        );
        total ??= jsonData['total'] as int?;
        final data = jsonData['data'] as List<dynamic>? ?? [];
        if (data.isEmpty) {
          break;
        }
        episodeList.addAll(data
            .whereType<Map<String, dynamic>>()
            .map((jsonItem) => EpisodeInfo.fromJson(jsonItem)));
        offset += data.length;
      } while (total == null || offset < total);
    } catch (e) {
      MiruLogger()
          .e('Network: resolve bangumi episode list failed', error: e);
      // 部分成功也整体上抛：半截分集列表会让用户误以为番剧只有这些集。
      rethrow;
    }
    return episodeList;
  }

  static Future<CommentResponse> getBangumiCommentsByID(int id,
      {int offset = 0}) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiCommentsByIDNext,
          [id, 20, offset]),
    );
    return CommentResponse.fromJson(jsonData);
  }

  static Future<EpisodeCommentResponse> getBangumiCommentsByEpisodeID(
      int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiEpisodeCommentsByIDNext,
          [id]),
    );
    return EpisodeCommentResponse.fromJson(jsonData);
  }

  static Future<CharacterCommentResponse> getCharacterCommentsByCharacterID(
      int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPINextDomain +
              ApiEndpoints.bangumiCharacterCommentsByIDNext,
          [id]),
    );
    return CharacterCommentResponse.fromJson(jsonData);
  }

  static Future<StaffResponse> getBangumiStaffByID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiStaffByID, [id]),
    );
    return StaffResponse.fromJson(jsonData);
  }

  static Future<CharactersResponse> getCharatersByBangumiID(int id) async {
    final jsonData = await _client.get(
      ApiEndpoints.formatUrl(
          ApiEndpoints.bangumiAPIDomain + ApiEndpoints.bangumiCharacterByID,
          [id]),
    );
    return CharactersResponse.fromJson(jsonData);
  }

  static Future<CharacterFullItem> getCharacterByCharacterID(int id) async {
    CharacterFullItem characterFullItem = CharacterFullItem.fromTemplate();
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPINextDomain +
                ApiEndpoints.bangumiCharacterInfoByCharacterIDNext,
            [id]),
      );
      characterFullItem = CharacterFullItem.fromJson(jsonData);
    } catch (e) {
      MiruLogger().e('Network: resolve character info failed', error: e);
    }
    return characterFullItem;
  }

  static Future<String?> getUsername() async {
    final user = await getCurrentUser();
    return user?.username;
  }

  static Future<User?> getCurrentUser() async {
    try {
      final jsonData = await _client.get(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain +
                ApiEndpoints.bangumiUsernameByToken,
            []),
        requiresAuth: true,
      );
      if (jsonData['id'] != null) {
        return User.fromJson(Map<String, dynamic>.from(jsonData));
      }
    } on NetworkException catch (e) {
      if (e.statusCode == 401) {
        MiruLogger().e('Bangumi token unauthorized, please check your token');
        throw StateError('Bangumi token 未授权，请检查您的 token');
      }
      rethrow;
    } catch (e) {
      MiruLogger().e('Network: get current user failed', error: e);
    }
    return null;
  }

  /// Get the Bangumi collection of the current user
  static Future<List<BangumiCollection>> getBangumiCollectibles({
    List<BangumiCollectionType> includeBangumiTypes = const [
      BangumiCollectionType.planToWatch,
      BangumiCollectionType.watched,
      BangumiCollectionType.watching,
      BangumiCollectionType.onHold,
      BangumiCollectionType.abandoned,
    ],
    String? username,
    required int limit,
    void Function(String message, int current, int total)? onProgress,
  }) async {
    final List<BangumiCollection> bangumiCollection = [];
    final resolvedUsername = username != null && username.isNotEmpty
        ? username
        : await getUsername();
    int failedItemCount = 0;
    int progressCurrent = 0;
    int progressTotal = 0;
    if (resolvedUsername == null) {
      MiruLogger().w('get username failed');
      return [];
    }

    try {
      const Duration requestInterval = Duration(milliseconds: 250);

      for (final collectionType in includeBangumiTypes) {
        if (collectionType == BangumiCollectionType.unknown) {
          continue;
        }
        int offset = 0;
        int? total;
        bool totalInitialized = false;
        while (true) {
          dynamic jsonData;
          try {
            final url = ApiEndpoints.formatUrl(
                ApiEndpoints.bangumiAPIDomain +
                    ApiEndpoints.bangumiGetCollection,
                [resolvedUsername, limit, offset, collectionType.value]);
            jsonData = await _client.get(
              url,
              requiresAuth: true,
            );
          } catch (e) {
            MiruLogger().e(
              'BangumiApi: fetch collection failed. type=${collectionType.value}, offset=$offset',
              error: e,
            );
            rethrow;
          }

          final Map jsonMap = jsonData;
          final List<dynamic> jsonList = jsonMap['data'];
          total ??= jsonMap['total'];
          if (!totalInitialized && total != null) {
            progressTotal += total;
            totalInitialized = true;
          }

          for (dynamic jsonItem in jsonList) {
            if (jsonItem is Map<String, dynamic>) {
              try {
                bangumiCollection.add(BangumiCollection.fromJson(jsonItem));
                progressCurrent++;
                onProgress?.call(
                  '正在拉取${collectionType.label}收藏',
                  progressCurrent,
                  progressTotal,
                );
              } catch (e) {
                MiruLogger().e(
                  'BangumiApi: parse collection item failed: ${e.toString()}',
                  error: e,
                );
                failedItemCount++;
              }
            }
          }

          if (jsonList.isEmpty || (total != null && offset + limit >= total)) {
            break;
          }

          offset += limit;
          await Future.delayed(requestInterval);
        }
      }
    } catch (e) {
      MiruLogger().e('Network: get bangumi collection failed', error: e);
      rethrow;
    }
    MiruLogger()
        .d('get Bangumi collection count: ${bangumiCollection.length}');
    MiruLogger().d('get item failed count: $failedItemCount');
    return bangumiCollection;
  }

  /// Update the Bangumi collection by ID
  static Future<bool> updateBangumiById(
      int id, Map<String, dynamic> data) async {
    const Duration requestInterval = Duration(milliseconds: 250);
    try {
      await _client.post(
        ApiEndpoints.formatUrl(
            ApiEndpoints.bangumiAPIDomain +
                ApiEndpoints.bangumiSetCollection,
            [id]),
        data: data,
        requiresAuth: true,
      );
      MiruLogger().d('Update to Bangumi: Id: $id');
      return true;
    } on NetworkException catch (e) {
      String str;
      switch (e.statusCode) {
        case 400:
          str = 'Validation Error 验证错误';
          break;
        case 401:
          str = 'Unauthorized 未经授权';
          break;
        case 404:
          str = 'User not found 用户不存在';
          break;
        default:
          str = 'Error $e';
      }
      MiruLogger().e('BangumiApi: $str', error: e);
      return false;
    } catch (e) {
      MiruLogger().e('Network: update bangumi collection failed', error: e);
      rethrow;
    } finally {
      await Future.delayed(requestInterval);
    }
  }

  /// Update the Bangumi collection by Type
  static Future<bool> updateBangumiByType(int id, int localType) async {
    final type = CollectType.fromValue(localType).toBangumiCollectionType();
    if (type == null) {
      return false;
    }
    return await updateBangumiById(id, {'type': type.value});
  }

  /// update or add Bangumi evaluation by subjectID
  static Future<bool> addOrUpdateBangumiEvaluationBySubjectID(
    int subjectID,
    int localType, {
    String? comment,
    int? rate,
    List<String>? tags,
  }) async {
    final bangumiType =
        CollectType.fromValue(localType).toBangumiCollectionType();
    if (bangumiType == null) {
      return false;
    }
    final data = <String, dynamic>{'type': bangumiType.value};
    if (comment != null) data['comment'] = comment;
    if (rate != null) data['rate'] = rate;
    if (tags != null) data['tags'] = tags;
    return updateBangumiById(subjectID, data);
  }
}
