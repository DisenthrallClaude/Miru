class CollectSyncPlan {
  const CollectSyncPlan({
    required this.webDavEnabled,
    required this.webDavCollectiblesEnabled,
    required this.bangumiEnabled,
    required this.githubEnabled,
    required this.githubCollectiblesEnabled,
  });

  final bool webDavEnabled;
  final bool webDavCollectiblesEnabled;
  final bool bangumiEnabled;

  /// GitHub 云同步总开关（SettingsKeys.githubEnable）。
  final bool githubEnabled;

  /// GitHub 云同步的「同步追番收藏」子开关（SettingsKeys.githubEnableCollect）。
  final bool githubCollectiblesEnabled;

  bool get shouldSyncWebDavCollectibles =>
      webDavEnabled && webDavCollectiblesEnabled;

  bool get shouldSyncBangumi => bangumiEnabled;

  /// v1.6.8（W-🟡2）：GitHub 通道此前从未纳入计划对象，GitHub-only 用户
  /// 在追番页点同步被 canSync 误判为「同步功能不可用」——而同一能力在
  /// GitHub 设置页与启动自动同步里都可用。补上后按钮状态与实际可用
  /// 通道一致。
  bool get shouldSyncGithubCollectibles =>
      githubEnabled && githubCollectiblesEnabled;

  bool get canSync =>
      shouldSyncWebDavCollectibles ||
      shouldSyncBangumi ||
      shouldSyncGithubCollectibles;

  bool shouldUploadWebDavAfterBangumi({
    required bool webDavSynced,
    required bool bangumiSynced,
  }) {
    return shouldSyncWebDavCollectibles &&
        shouldSyncBangumi &&
        webDavSynced &&
        bangumiSynced;
  }
}
