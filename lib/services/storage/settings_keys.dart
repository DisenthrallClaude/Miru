import 'package:miru/services/player/syncplay_endpoint.dart';

enum SettingGroup {
  player,
  danmaku,
  theme,
  interface,
  proxy,
  webdav,
  github,
  download,
  bangumi,
  collect,
  sync,
  update,
  misc,
}

class SettingContext {
  const SettingContext({this.compactLayout = false});

  final bool compactLayout;
}

class SettingKey<T> {
  const SettingKey(
    this.name,
    this.defaultValue, {
    required this.group,
    this.defaultResolver,
  });

  final String name;
  final T defaultValue;
  final SettingGroup group;
  final T Function(SettingContext context)? defaultResolver;

  T resolveDefault(SettingContext context) {
    return defaultResolver?.call(context) ?? defaultValue;
  }
}

// Add new settings here. SettingsKeys is the public typed registry used by
// callers; new keys can use literal string names directly.
class SettingsKeys {
  static const hAenable = SettingKey<bool>(
    _SettingBoxKey.hAenable,
    true,
    group: SettingGroup.player,
  );
  static const hardwareDecoder = SettingKey<String>(
    _SettingBoxKey.hardwareDecoder,
    'auto-safe',
    group: SettingGroup.player,
  );
  static const autoUpdate = SettingKey<bool>(
    _SettingBoxKey.autoUpdate,
    true,
    group: SettingGroup.update,
  );
  static const checkPluginUpdateOnStartup = SettingKey<bool>(
    'checkPluginUpdateOnStartup',
    true,
    group: SettingGroup.update,
  );
  static const defaultPlaySpeed = SettingKey<double>(
    _SettingBoxKey.defaultPlaySpeed,
    1.0,
    group: SettingGroup.player,
  );
  static const defaultShortcutForwardPlaySpeed = SettingKey<double>(
    _SettingBoxKey.defaultShortcutForwardPlaySpeed,
    2.0,
    group: SettingGroup.player,
  );
  static const defaultAspectRatioType = SettingKey<int>(
    _SettingBoxKey.defaultAspectRatioType,
    1,
    group: SettingGroup.player,
  );
  static const buttonSkipTime = SettingKey<int>(
    _SettingBoxKey.buttonSkipTime,
    80,
    group: SettingGroup.player,
  );
  static const arrowKeySkipTime = SettingKey<int>(
    _SettingBoxKey.arrowKeySkipTime,
    10,
    group: SettingGroup.player,
  );
  static const danmakuBorder = SettingKey<bool>(
    _SettingBoxKey.danmakuBorder,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuBorderSize = SettingKey<double>(
    _SettingBoxKey.danmakuBorderSize,
    1.5,
    group: SettingGroup.danmaku,
  );
  static const danmakuOpacity = SettingKey<double>(
    _SettingBoxKey.danmakuOpacity,
    1.0,
    group: SettingGroup.danmaku,
  );
  static final danmakuFontSize = SettingKey<double>(
    _SettingBoxKey.danmakuFontSize,
    25.0,
    group: SettingGroup.danmaku,
    defaultResolver: (context) => context.compactLayout ? 16.0 : 25.0,
  );
  static const danmakuTop = SettingKey<bool>(
    _SettingBoxKey.danmakuTop,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuScroll = SettingKey<bool>(
    _SettingBoxKey.danmakuScroll,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuBottom = SettingKey<bool>(
    _SettingBoxKey.danmakuBottom,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuMassive = SettingKey<bool>(
    _SettingBoxKey.danmakuMassive,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuDeduplication = SettingKey<bool>(
    _SettingBoxKey.danmakuDeduplication,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuArea = SettingKey<double>(
    _SettingBoxKey.danmakuArea,
    1.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuColor = SettingKey<bool>(
    _SettingBoxKey.danmakuColor,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuDuration = SettingKey<double>(
    _SettingBoxKey.danmakuDuration,
    8.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuLineHeight = SettingKey<double>(
    _SettingBoxKey.danmakuLineHeight,
    1.6,
    group: SettingGroup.danmaku,
  );
  static const danmakuTimeOffset = SettingKey<double>(
    _SettingBoxKey.danmakuTimeOffset,
    0.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuEnabledByDefault = SettingKey<bool>(
    _SettingBoxKey.danmakuEnabledByDefault,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuBiliBiliSource = SettingKey<bool>(
    _SettingBoxKey.danmakuBiliBiliSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuGamerSource = SettingKey<bool>(
    _SettingBoxKey.danmakuGamerSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuDanDanSource = SettingKey<bool>(
    _SettingBoxKey.danmakuDanDanSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuFontWeight = SettingKey<int>(
    _SettingBoxKey.danmakuFontWeight,
    4,
    group: SettingGroup.danmaku,
  );
  static const danmakuFollowSpeed = SettingKey<bool>(
    _SettingBoxKey.danmakuFollowSpeed,
    true,
    group: SettingGroup.danmaku,
  );
  static const themeMode = SettingKey<String>(
    _SettingBoxKey.themeMode,
    'system',
    group: SettingGroup.theme,
  );
  static const themeColor = SettingKey<String>(
    _SettingBoxKey.themeColor,
    'default',
    group: SettingGroup.theme,
  );
  static const privateMode = SettingKey<bool>(
    _SettingBoxKey.privateMode,
    false,
    group: SettingGroup.player,
  );
  static const autoPlay = SettingKey<bool>(
    _SettingBoxKey.autoPlay,
    true,
    group: SettingGroup.player,
  );
  static const autoPlayNext = SettingKey<bool>(
    _SettingBoxKey.autoPlayNext,
    true,
    group: SettingGroup.player,
  );
  static const playResume = SettingKey<bool>(
    _SettingBoxKey.playResume,
    true,
    group: SettingGroup.player,
  );
  static const showPlayerError = SettingKey<bool>(
    _SettingBoxKey.showPlayerError,
    true,
    group: SettingGroup.player,
  );
  static const oledEnhance = SettingKey<bool>(
    _SettingBoxKey.oledEnhance,
    false,
    group: SettingGroup.theme,
  );
  static const displayMode = SettingKey<String?>(
    _SettingBoxKey.displayMode,
    null,
    group: SettingGroup.interface,
  );
  static const enableGitProxy = SettingKey<bool>(
    _SettingBoxKey.enableGitProxy,
    true,
    group: SettingGroup.proxy,
  );
  static const enableBangumiProxy = SettingKey<bool>(
    _SettingBoxKey.enableBangumiProxy,
    true,
    group: SettingGroup.proxy,
  );
  static const enableSystemProxy = SettingKey<bool>(
    _SettingBoxKey.enableSystemProxy,
    false,
    group: SettingGroup.proxy,
  );
  static const defaultStartupPage = SettingKey<String>(
    _SettingBoxKey.defaultStartupPage,
    '/tab/popular/',
    group: SettingGroup.interface,
  );
  /// 远程公告频控状态：JSON 对象 {公告id: "关闭日期 yyyy-MM-dd"}。
  /// once 频控 = id 存在即不再弹；daily = 同一天内不重复弹。
  /// 用单一字符串键而不是逐公告动态键，避免 Hive 键无上限增长。
  static const announcementDismissState = SettingKey<String>(
    'announcementDismissState',
    '',
    group: SettingGroup.interface,
  );
  /// 最近一次成功拉取的公告源原文（JSON 字符串）。
  /// 拉取失败/解析失败时沿用这份上次成功数据展示（对接规格约定）；
  /// 每次成功拉取整体覆盖，天然携带删除语义。
  static const announcementCache = SettingKey<String>(
    'announcementCache',
    '',
    group: SettingGroup.interface,
  );
  /// 用户选择「忽略此版本」的更新版本号；自动检查时命中则不再弹窗。
  /// 出现更新的版本号后自动失效。
  static const updateIgnoredVersion = SettingKey<String>(
    'updateIgnoredVersion',
    '',
    group: SettingGroup.update,
  );
  /// 「我的追番」卡片展示的自定义用户名；空串回退「我的追番」。
  static const username = SettingKey<String>(
    'username',
    '',
    group: SettingGroup.interface,
  );
  /// 自定义头像的本地文件路径；空串 = 未设置，回退爱心图标。
  static const avatarPath = SettingKey<String>(
    'avatarPath',
    '',
    group: SettingGroup.interface,
  );
  static const webDavEnable = SettingKey<bool>(
    _SettingBoxKey.webDavEnable,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableHistory = SettingKey<bool>(
    _SettingBoxKey.webDavEnableHistory,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableCollect = SettingKey<bool>(
    _SettingBoxKey.webDavEnableCollect,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavURL = SettingKey<String>(
    _SettingBoxKey.webDavURL,
    '',
    group: SettingGroup.webdav,
  );
  static const webDavUsername = SettingKey<String>(
    _SettingBoxKey.webDavUsername,
    '',
    group: SettingGroup.webdav,
  );
  static const webDavPassword = SettingKey<String>(
    _SettingBoxKey.webDavPassword,
    '',
    group: SettingGroup.webdav,
  );
  static const githubEnable = SettingKey<bool>(
    _SettingBoxKey.githubEnable,
    false,
    group: SettingGroup.github,
  );
  static const githubToken = SettingKey<String>(
    _SettingBoxKey.githubToken,
    '',
    group: SettingGroup.github,
  );
  static const githubRepo = SettingKey<String>(
    _SettingBoxKey.githubRepo,
    '',
    group: SettingGroup.github,
  );
  static const githubLogin = SettingKey<String>(
    _SettingBoxKey.githubLogin,
    '',
    group: SettingGroup.github,
  );
  static const githubAvatarUrl = SettingKey<String>(
    _SettingBoxKey.githubAvatarUrl,
    '',
    group: SettingGroup.github,
  );
  static const githubEnableHistory = SettingKey<bool>(
    _SettingBoxKey.githubEnableHistory,
    true,
    group: SettingGroup.github,
  );
  static const githubEnableCollect = SettingKey<bool>(
    _SettingBoxKey.githubEnableCollect,
    true,
    group: SettingGroup.github,
  );
  static const githubLastSyncTime = SettingKey<int>(
    _SettingBoxKey.githubLastSyncTime,
    0,
    group: SettingGroup.github,
  );
  static const lowMemoryMode = SettingKey<bool>(
    _SettingBoxKey.lowMemoryMode,
    false,
    group: SettingGroup.player,
  );
  static const showWindowButton = SettingKey<bool>(
    _SettingBoxKey.showWindowButton,
    false,
    group: SettingGroup.theme,
  );
  static const useDynamicColor = SettingKey<bool>(
    _SettingBoxKey.useDynamicColor,
    false,
    group: SettingGroup.theme,
  );
  static const exitBehavior = SettingKey<int>(
    _SettingBoxKey.exitBehavior,
    2,
    group: SettingGroup.interface,
  );
  static const playerDebugMode = SettingKey<bool>(
    _SettingBoxKey.playerDebugMode,
    false,
    group: SettingGroup.player,
  );
  static const syncPlayEndPoint = SettingKey<String>(
    _SettingBoxKey.syncPlayEndPoint,
    defaultSyncPlayEndPoint,
    group: SettingGroup.player,
  );
  static const syncPlayUserName = SettingKey<String>(
    'syncPlayUserName',
    '',
    group: SettingGroup.player,
  );
  static const androidEnableOpenSLES = SettingKey<bool>(
    _SettingBoxKey.androidEnableOpenSLES,
    true,
    group: SettingGroup.player,
  );
  static const androidVideoRenderer = SettingKey<String>(
    _SettingBoxKey.androidVideoRenderer,
    'auto',
    group: SettingGroup.player,
  );
  static const androidAutoEnterPIP = SettingKey<bool>(
    _SettingBoxKey.androidAutoEnterPIP,
    false,
    group: SettingGroup.player,
  );
  static const defaultSuperResolutionMode = SettingKey<int>(
    _SettingBoxKey.defaultSuperResolutionMode,
    1,
    group: SettingGroup.player,
  );
  static const disableSuperResolutionWarning = SettingKey<bool>(
    _SettingBoxKey.disableSuperResolutionWarning,
    false,
    group: SettingGroup.player,
  );
  static const playerDisableAnimations = SettingKey<bool>(
    _SettingBoxKey.playerDisableAnimations,
    false,
    group: SettingGroup.player,
  );
  static const playerLogLevel = SettingKey<int>(
    _SettingBoxKey.playerLogLevel,
    2,
    group: SettingGroup.player,
  );
  static const timelineNotShowAbandonedBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineNotShowAbandonedBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const timelineNotShowWatchedBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineNotShowWatchedBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const timelineOnlyShowWatchingBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineOnlyShowWatchingBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const useSystemFont = SettingKey<bool>(
    _SettingBoxKey.useSystemFont,
    false,
    group: SettingGroup.theme,
  );
  static const forceAdBlocker = SettingKey<bool>(
    _SettingBoxKey.forceAdBlocker,
    false,
    group: SettingGroup.player,
  );
  static const backgroundPlayback = SettingKey<bool>(
    _SettingBoxKey.backgroundPlayback,
    false,
    group: SettingGroup.player,
  );
  static const proxyEnable = SettingKey<bool>(
    _SettingBoxKey.proxyEnable,
    false,
    group: SettingGroup.proxy,
  );
  static const proxyConfigured = SettingKey<bool>(
    _SettingBoxKey.proxyConfigured,
    false,
    group: SettingGroup.proxy,
  );
  static const proxyUrl = SettingKey<String>(
    _SettingBoxKey.proxyUrl,
    '',
    group: SettingGroup.proxy,
  );
  static const proxyTestUrl = SettingKey<String>(
    _SettingBoxKey.proxyTestUrl,
    '',
    group: SettingGroup.proxy,
  );
  /// 推荐页缓存已翻到的 offset，随缓存一同持久化，
  /// 保证从缓存恢复后继续下拉不会重复取同一页。
  static const popularCacheOffset = SettingKey<int>(
    _SettingBoxKey.popularCacheOffset,
    0,
    group: SettingGroup.bangumi,
  );
  /// 时间表缓存对应的季度字符串。与当前季度不一致时才重新联网拉取。
  static const calendarCacheSeason = SettingKey<String>(
    _SettingBoxKey.calendarCacheSeason,
    '',
    group: SettingGroup.bangumi,
  );
  static const showRating = SettingKey<bool>(
    _SettingBoxKey.showRating,
    true,
    group: SettingGroup.interface,
  );
  static const showAnimeCounter = SettingKey<bool>(
    _SettingBoxKey.showAnimeCounter,
    false,
    group: SettingGroup.interface,
  );
  static const downloadParallelEpisodes = SettingKey<int>(
    _SettingBoxKey.downloadParallelEpisodes,
    2,
    group: SettingGroup.download,
  );
  static const downloadParallelSegments = SettingKey<int>(
    _SettingBoxKey.downloadParallelSegments,
    3,
    group: SettingGroup.download,
  );
  static const downloadDanmaku = SettingKey<bool>(
    _SettingBoxKey.downloadDanmaku,
    true,
    group: SettingGroup.download,
  );
  static const downloadDirectory = SettingKey<String>(
    _SettingBoxKey.downloadDirectory,
    '',
    group: SettingGroup.download,
  );
  // macOS only: security-scoped bookmark that keeps downloadDirectory
  // writable across app restarts under the sandbox.
  static const downloadDirectoryBookmark = SettingKey<String>(
    'downloadDirectoryBookmark',
    '',
    group: SettingGroup.download,
  );
  static const shortcutDialogShown = SettingKey<bool>(
    _SettingBoxKey.shortcutDialogShown,
    false,
    group: SettingGroup.misc,
  );
  static const bangumiSyncEnable = SettingKey<bool>(
    _SettingBoxKey.bangumiSyncEnable,
    false,
    group: SettingGroup.bangumi,
  );
  static const bangumiAccessToken = SettingKey<String>(
    _SettingBoxKey.bangumiAccessToken,
    '',
    group: SettingGroup.bangumi,
  );
  static const bangumiSyncPriority = SettingKey<int>(
    _SettingBoxKey.bangumiSyncPriority,
    0,
    group: SettingGroup.bangumi,
  );
  static const bangumiImmediateSyncToastEnable = SettingKey<bool>(
    _SettingBoxKey.bangumiImmediateSyncToastEnable,
    true,
    group: SettingGroup.bangumi,
  );
  static const brightnessVolumeGesture = SettingKey<bool>(
    _SettingBoxKey.brightnessVolumeGesture,
    true,
    group: SettingGroup.player,
  );
  static const historySyncDeviceId = SettingKey<String>(
    _SettingBoxKey.historySyncDeviceId,
    '',
    group: SettingGroup.sync,
  );
  static const historySyncSequence = SettingKey<int>(
    _SettingBoxKey.historySyncSequence,
    0,
    group: SettingGroup.sync,
  );
  static const historySyncSnapshotInitialized = SettingKey<bool>(
    _SettingBoxKey.historySyncSnapshotInitialized,
    false,
    group: SettingGroup.sync,
  );
  static const playerControllerLayerDisappearTime = SettingKey<int>(
    'playerControllerLayerDisappearTime',
    4000,
    group: SettingGroup.player,
  );
  static const defaultVolume = SettingKey<double>(
    'defaultVolume',
    100.0,
    group: SettingGroup.player,
  );
  static const playerMuted = SettingKey<bool>(
    'playerMuted',
    false,
    group: SettingGroup.player,
  );
  /// 视频源解析超时（秒）。超时后会自动换用另一种解析器重试一次。
  /// 默认 20s 与解析服务层签名默认对齐（B7）；播放与下载链路共用。
  static const parseTimeout = SettingKey<int>(
    'parseTimeout',
    20,
    group: SettingGroup.player,
  );
  /// 云端解析加速：自建/自定义 Worker 地址。
  /// 留空 = 使用内置官方端点（v1.5.1 起零配置可用，见
  /// [ApiEndpoints.cloudResolverOfficialEndpoint]）；填了则完全替换官方端点。
  /// 部署方法见仓库 cloudflare-worker/miru-resolver/README.md。
  static const cloudResolverUrl = SettingKey<String>(
    'cloudResolverUrl',
    '',
    group: SettingGroup.player,
  );
  /// 云端解析加速开关（官方或自定义端点任一存在即生效）。
  static const cloudResolverEnable = SettingKey<bool>(
    'cloudResolverEnable',
    true,
    group: SettingGroup.player,
  );
  /// 匿名设备标识：首次启动随机生成，仅用于云端解析层的
  /// 「每日活跃人数」统计与配额分配。不含任何个人信息，
  /// 不随收藏/配置导出。空串表示尚未生成。
  static const anonUid = SettingKey<String>(
    'anonUid',
    '',
    group: SettingGroup.player,
  );
  /// 上次心跳的自然日（YYYYMMDD）：每天只发一次匿名活跃心跳。
  static const lastPingDay = SettingKey<String>(
    'lastPingDay',
    '',
    group: SettingGroup.player,
  );
  /// 播放秒开：本地媒体缓存（开头数据预取 + 二刷磁盘直读）。
  /// 移动数据网络下预取自动跳过，不偷跑流量。
  static const localMediaCacheEnable = SettingKey<bool>(
    'localMediaCacheEnable',
    true,
    group: SettingGroup.player,
  );

  static final List<SettingKey<Object?>> all = [
    hAenable,
    hardwareDecoder,
    autoUpdate,
    checkPluginUpdateOnStartup,
    defaultPlaySpeed,
    defaultShortcutForwardPlaySpeed,
    defaultAspectRatioType,
    buttonSkipTime,
    arrowKeySkipTime,
    danmakuBorder,
    danmakuBorderSize,
    danmakuOpacity,
    danmakuFontSize,
    danmakuTop,
    danmakuScroll,
    danmakuBottom,
    danmakuMassive,
    danmakuDeduplication,
    danmakuArea,
    danmakuColor,
    danmakuDuration,
    danmakuLineHeight,
    danmakuTimeOffset,
    danmakuEnabledByDefault,
    danmakuBiliBiliSource,
    danmakuGamerSource,
    danmakuDanDanSource,
    danmakuFontWeight,
    danmakuFollowSpeed,
    themeMode,
    themeColor,
    privateMode,
    autoPlay,
    autoPlayNext,
    playResume,
    showPlayerError,
    oledEnhance,
    displayMode,
    enableGitProxy,
    enableBangumiProxy,
    enableSystemProxy,
    defaultStartupPage,
    announcementDismissState,
    announcementCache,
    updateIgnoredVersion,
    username,
    avatarPath,
    webDavEnable,
    webDavEnableHistory,
    webDavEnableCollect,
    webDavURL,
    webDavUsername,
    webDavPassword,
    githubEnable,
    githubToken,
    githubRepo,
    githubLogin,
    githubAvatarUrl,
    githubEnableHistory,
    githubEnableCollect,
    githubLastSyncTime,
    lowMemoryMode,
    showWindowButton,
    useDynamicColor,
    exitBehavior,
    playerDebugMode,
    syncPlayEndPoint,
    syncPlayUserName,
    androidEnableOpenSLES,
    androidVideoRenderer,
    androidAutoEnterPIP,
    defaultSuperResolutionMode,
    disableSuperResolutionWarning,
    playerDisableAnimations,
    playerLogLevel,
    cloudResolverUrl,
    cloudResolverEnable,
    localMediaCacheEnable,
    timelineNotShowAbandonedBangumis,
    timelineNotShowWatchedBangumis,
    timelineOnlyShowWatchingBangumis,
    useSystemFont,
    forceAdBlocker,
    backgroundPlayback,
    proxyEnable,
    proxyConfigured,
    proxyUrl,
    proxyTestUrl,
    calendarCacheSeason,
    popularCacheOffset,
    showRating,
    showAnimeCounter,
    downloadParallelEpisodes,
    downloadParallelSegments,
    downloadDanmaku,
    downloadDirectory,
    downloadDirectoryBookmark,
    shortcutDialogShown,
    bangumiSyncEnable,
    bangumiAccessToken,
    bangumiSyncPriority,
    bangumiImmediateSyncToastEnable,
    brightnessVolumeGesture,
    historySyncDeviceId,
    historySyncSequence,
    historySyncSnapshotInitialized,
    playerControllerLayerDisappearTime,
    defaultVolume,
    playerMuted,
    parseTimeout,
  ];

  static List<SettingKey<Object?>> byGroup(SettingGroup group) {
    return [
      for (final key in all)
        if (key.group == group) key
    ];
  }

  SettingsKeys._();
}

// Historical Hive key names used by settings created before the typed registry.
// Keep these strings stable so existing users keep their saved settings.
// New settings do not need to be added here unless they intentionally reuse an
// existing persisted key.
class _SettingBoxKey {
  static const String hAenable = 'hAenable',
      hardwareDecoder = 'hardwareDecoder',
      autoUpdate = 'autoUpdate',
      defaultPlaySpeed = 'defaultPlaySpeed',
      defaultShortcutForwardPlaySpeed = 'defaultShortcutForwardPlaySpeed',
      defaultAspectRatioType = 'defaultAspectRatioType',
      buttonSkipTime = 'buttonSkipTime',
      arrowKeySkipTime = 'arrowKeySkipTime',
      danmakuBorder = 'danmakuBorder',
      danmakuBorderSize = 'danmakuBorderSize',
      danmakuOpacity = 'danmakuOpacity',
      danmakuFontSize = 'danmakuFontSize',
      danmakuTop = 'danmakuTop',
      danmakuScroll = 'danmakuScroll',
      danmakuBottom = 'danmakuBottom',
      danmakuMassive = 'danmakuMassive',
      danmakuDeduplication = 'danmakuDeduplication',
      danmakuArea = 'danmakuArea',
      danmakuColor = 'danmakuColor',
      danmakuDuration = 'danmakuDuration',
      danmakuLineHeight = 'danmakuLineHeight',
      danmakuTimeOffset = 'danmakuTimeOffset',
      danmakuEnabledByDefault = 'danmakuEnabledByDefault',
      danmakuBiliBiliSource = 'danmakuBiliBiliSource',
      danmakuGamerSource = 'danmakuGamerSource',
      danmakuDanDanSource = 'danmakuDanDanSource',
      danmakuFontWeight = 'danmakuFontWeight',
      danmakuFollowSpeed = 'danmakuFollowSpeed',
      themeMode = 'themeMode',
      themeColor = 'themeColor',
      privateMode = 'privateMode',
      autoPlay = 'autoPlay',
      autoPlayNext = 'autoPlayNext',
      playResume = 'playResume',
      showPlayerError = 'showPlayerError',
      oledEnhance = 'oledEnhance',
      displayMode = 'displayMode',
      enableGitProxy = 'enableGitProxy',
      enableBangumiProxy = 'enableBangumiProxy',
      enableSystemProxy = 'enableSystemProxy',
      defaultStartupPage = 'defaultStartupPage',
      webDavEnable = 'webDavEnable',
      webDavEnableHistory = 'webDavEnableHistory',
      webDavEnableCollect = 'webDavEnableCollect',
      webDavURL = 'webDavURL',
      webDavUsername = 'webDavUsername',
      webDavPassword = 'webDavPasswd',
      githubEnable = 'githubEnable',
      githubToken = 'githubToken',
      githubRepo = 'githubRepo',
      githubLogin = 'githubLogin',
      githubAvatarUrl = 'githubAvatarUrl',
      githubEnableHistory = 'githubEnableHistory',
      githubEnableCollect = 'githubEnableCollect',
      githubLastSyncTime = 'githubLastSyncTime',
      lowMemoryMode = 'lowMemoryMode',
      showWindowButton = 'showWindowButton',
      useDynamicColor = 'useDynamicColor',
      exitBehavior = 'exitBehavior',
      playerDebugMode = 'playerDebugMode',
      syncPlayEndPoint = 'syncPlayEndPoint',
      androidEnableOpenSLES = 'androidEnableOpenSLES',
      androidVideoRenderer = 'androidVideoRenderer',
      androidAutoEnterPIP = 'androidAutoEnterPIP',
      defaultSuperResolutionMode = 'defaultSuperResolutionType',
      disableSuperResolutionWarning = 'superResolutionWarn',
      playerDisableAnimations = 'playerDisableAnimations',
      playerLogLevel = 'playerLogLevel',
      timelineNotShowAbandonedBangumis = 'timelineNotShowAbandonedBangumis',
      timelineNotShowWatchedBangumis = 'timelineNotShowWatchedBangumis',
      timelineOnlyShowWatchingBangumis = 'timelineOnlyShowWatchingBangumis',
      useSystemFont = 'useSystemFont',
      forceAdBlocker = 'forceAdBlocker',
      backgroundPlayback = 'backgroundPlayback',
      proxyEnable = 'proxyEnable',
      proxyConfigured = 'proxyConfigured',
      proxyUrl = 'proxyUrl',
      proxyTestUrl = 'proxyTestUrl',
      calendarCacheSeason = 'calendarCacheSeason',
      popularCacheOffset = 'popularCacheOffset',
      showRating = 'showRating',
      showAnimeCounter = 'showAnimeCounter',
      downloadParallelEpisodes = 'downloadParallelEpisodes',
      downloadParallelSegments = 'downloadParallelSegments',
      downloadDanmaku = 'downloadDanmaku',
      downloadDirectory = 'downloadDirectory',
      shortcutDialogShown = 'shortcutDialogShown',
      bangumiSyncEnable = 'bangumiSyncEnable',
      bangumiAccessToken = 'bangumiAccessToken',
      bangumiSyncPriority = 'bangumiSyncPriority',
      bangumiImmediateSyncToastEnable = 'bangumiImmediateSyncToastEnable',
      brightnessVolumeGesture = 'brightnessVolumeGesture',
      historySyncDeviceId = 'historySyncDeviceId',
      historySyncSequence = 'historySyncSequence',
      historySyncSnapshotInitialized = 'historySyncSnapshotInitialized';
}
