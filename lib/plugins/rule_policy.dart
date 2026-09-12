/// 规则分类策略 —— 哪些规则随首次引导自动安装、哪些留给用户手动装。
///
/// 本文件只描述「政策」，不包含任何逻辑：
/// * 内置规则（assets/plugins/）只放国漫友好的源，开箱即可搜到国漫。
/// * 日漫为主的规则不内置、也不在引导的自动下载环节安装，
///   由用户之后在 设置 → 规则管理 → 规则仓库 里自行决定是否安装。
/// * 已知损坏的规则（站点失效 / 规则解析失败，经实测确认）同样不自动安装，
///   避免新用户开箱即遇到「装了却搜不到」的坏源。
library;

/// 日漫为主的规则名单（大小写不敏感比较由调用方负责，名单统一小写）。
///
/// 判定依据为逐条实测（2026-08，斗破苍穹/凡人修仙传 vs 鬼灭之刃/咒术回战）：
/// 这些源能搜到日漫、但搜不到国漫，或本身即日漫专用站（含需要验证码的）。
const Set<String> kJapaneseRuleNames = <String>{
  'aafun',
  'akianime',
  'ezdmw',
  'gugu3',
  'sorani',
  'xfdmneo',
  'xfdmnext',
  'girigirilove',
  'mgnacg',
  'mutefun',
  // v1.6.10：上游新增源，站点排行/推荐位全为日漫，
  // 且实测搜索接口失效（返回排行列表而非搜索结果）。
  'moonci',
};

/// 已知损坏的规则名单（实测确认站点失效或解析失败）。
///
/// * mwcy: 域名已失效，重定向到无关站点。
///
/// v1.6.10：baimao（白猫）移出本名单——站点已迁移至 bmmdmm.com 并
/// 改名「黑猫动漫」，选集列表现为服务端直出（旧「混淆 JS 动态渲染」
/// 的结论已过时），内置规则已更新为 v2.0（新域名 + 稳定的 class 型
/// XPath）并随包分发、存量用户经启动时的内置规则刷新获得修复。
const Set<String> kBrokenRuleNames = <String>{
  'mwcy',
};

/// 该规则是否应在首次引导的自动安装环节跳过。
///
/// 跳过 ≠ 禁止安装：这些规则依然出现在规则仓库里，
/// 用户在 设置 → 规则管理 → 规则仓库 中手动点击安装不受影响。
bool shouldSkipAutoInstall(String ruleName) {
  final key = ruleName.toLowerCase();
  return kJapaneseRuleNames.contains(key) || kBrokenRuleNames.contains(key);
}

/// 该规则是否为日漫为主的源（用于规则仓库列表打「日漫」标记，
/// 让用户在手动安装前知道源的内容倾向）。
bool isJapaneseRule(String ruleName) {
  return kJapaneseRuleNames.contains(ruleName.toLowerCase());
}
