/// 首页顶部横幅（大轮播）的固定内容。
///
/// 这里刻意**不使用** Bangumi 的封面：Bangumi 只提供竖版海报（约 0.65），
/// 塞进 16:9 横幅必然要裁切，观感很差。改为内置产品方指定的 16:9 官方主视觉图，
/// 内容与顺序固定，不随接口数据变化。
///
/// 图片位于 `assets/images/hero/`，已压到 1280×720 / JPEG。
/// 点击后仍跳转到对应的 Bangumi 详情页（用 [subjectId] 关联）。
class HeroBanner {
  const HeroBanner({
    required this.asset,
    required this.title,
    required this.subjectId,
  });

  /// 内置 16:9 主视觉图。
  final String asset;

  /// 番剧名，用于无障碍语义与兜底展示（画面本身已含题字，默认不叠加文字）。
  final String title;

  /// 对应的 Bangumi subject id，点击后据此打开详情页。
  final int subjectId;
}

/// 顺序即展示顺序。
const List<HeroBanner> kHeroBanners = <HeroBanner>[
  HeroBanner(
    asset: 'assets/images/hero/jianlai.jpg',
    title: '剑来',
    subjectId: 345825,
  ),
  HeroBanner(
    asset: 'assets/images/hero/guangyin.jpg',
    title: '光阴之外',
    subjectId: 458926,
  ),
  HeroBanner(
    asset: 'assets/images/hero/zhetian.jpg',
    title: '遮天',
    subjectId: 345768,
  ),
  HeroBanner(
    asset: 'assets/images/hero/doupo.jpg',
    title: '斗破苍穹',
    subjectId: 153197,
  ),
  HeroBanner(
    asset: 'assets/images/hero/cangyuan.jpg',
    title: '沧元图',
    subjectId: 403607,
  ),
];
