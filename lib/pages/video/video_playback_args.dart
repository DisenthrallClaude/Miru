import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/modules/download/download_module.dart';
import 'package:miru/modules/roads/road_module.dart';
import 'package:miru/plugins/plugins.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    this.fallbacks = const [],
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;

  /// 同番剧在其他源上的候选条目（健康源优先）。
  /// 当前源视频解析失败时，播放控制器会按序自动兜底切换。
  final List<SourceFallback> fallbacks;
}

/// 一个可自动兜底的备选源：规则插件 + 该番剧在其站内的搜索结果地址。
class SourceFallback {
  const SourceFallback({
    required this.plugin,
    required this.title,
    required this.src,
  });

  final Plugin plugin;
  final String title;
  final String src;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
