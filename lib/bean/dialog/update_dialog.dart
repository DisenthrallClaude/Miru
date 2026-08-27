import 'package:flutter/material.dart';
import 'package:miru/bean/widget/frosted_surface.dart';

/// 「发现新版本」玻璃弹窗：与公告弹窗同一套纯白液态玻璃视觉。
///
/// 结构：标题（发现新版本 vX.Y.Z）→ 发布时间（小字）→
/// 更新说明（Markdown 符号清洗后的纯文本，内部滚动）→
/// 胶囊按钮组：忽略此版本（仅自动检查时）/ 发布页 / 立即更新。
/// 关闭途径：右上角 ✕ / 系统返回键；点遮罩不关闭。
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.version,
    required this.description,
    required this.publishedAt,
    required this.onUpdate,
    required this.onOpenPage,
    this.onIgnore,
  });

  /// 新版本号（tag 名，如 v1.4.0）。
  final String version;

  /// 更新说明（应传清洗过 Markdown 符号的纯文本）。
  final String description;

  /// 发布时间文案（已格式化；空串隐藏）。
  final String publishedAt;

  /// 主按钮回调：立即更新（应用内下载 / 拉起发布页）。
  final VoidCallback onUpdate;

  /// 前往发布页回调（浏览器打开 Releases）。
  final VoidCallback onOpenPage;

  /// 「忽略此版本」回调；null 时不显示该按钮（手动检查场景）。
  final VoidCallback? onIgnore;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(24));

  // 白玻璃卡上的固定前景色：不随主题翻转，保证任何主题下可读。
  static const Color _ink = Color(0xFF1F2328);
  static const Color _inkSoft = Color(0xFF57606A);
  static const Color _accent = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        // 柔和投影：白玻璃自身没有边界感，投影给出卡片层次。
        child: Container(
          decoration: BoxDecoration(
            borderRadius: _radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: FrostedSurface(
            borderRadius: _radius,
            // 纯白玻璃：白色 tint 叠加在模糊层上，明暗主题下都是浅色卡。
            tint: Colors.white,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.45),
              width: 1,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: _radius,
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 30, 24, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.system_update_alt_rounded,
                                size: 22, color: _accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '发现新版本 $version',
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                  color: _ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (publishedAt.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '发布于 $publishedAt',
                            style: const TextStyle(
                                fontSize: 12.5, color: _inkSoft),
                          ),
                        ],
                        if (description.trim().isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Flexible(
                            child: SingleChildScrollView(
                              child: Text(
                                description,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  height: 1.65,
                                  color: _inkSoft,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          alignment: WrapAlignment.end,
                          children: [
                            if (onIgnore != null)
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _inkSoft,
                                  side: BorderSide(
                                    color: _inkSoft.withValues(alpha: 0.35),
                                    width: 1,
                                  ),
                                  shape: const StadiumBorder(),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 9),
                                  minimumSize: const Size(0, 38),
                                ),
                                onPressed: () {
                                  Navigator.of(context, rootNavigator: true)
                                      .pop();
                                  onIgnore!();
                                },
                                child: const Text('忽略此版本'),
                              ),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _inkSoft,
                                side: BorderSide(
                                  color: _inkSoft.withValues(alpha: 0.35),
                                  width: 1,
                                ),
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 9),
                                minimumSize: const Size(0, 38),
                              ),
                              onPressed: () {
                                Navigator.of(context, rootNavigator: true)
                                    .pop();
                                onOpenPage();
                              },
                              child: const Text('发布页'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: _accent,
                                foregroundColor: Colors.white,
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 9),
                                minimumSize: const Size(0, 38),
                              ),
                              onPressed: () {
                                Navigator.of(context, rootNavigator: true)
                                    .pop();
                                onUpdate();
                              },
                              child: const Text('立即更新'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context,
                          rootNavigator: true).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _inkSoft,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把 GitHub Release 的 Markdown 说明清洗成适合纯文本展示的形式：
/// 去掉标题井号、加粗/斜体星号、链接语法，列表符号转中点。
String stripMarkdown(String input) {
  var text = input;
  // 链接 [label](url) → label
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // 图片 ![alt](url) → 整体删除
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  // 标题行：去掉行首井号（含 # 后空格）；multiLine 让 ^ 命中每一行
  text = text.replaceAllMapped(
    RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true),
    (m) => '',
  );
  // 加粗/斜体标记
  text = text.replaceAll('**', '').replaceAll('__', '');
  // 行内代码标记
  text = text.replaceAll('`', '');
  // 无序列表符号 → 中点（multiLine 逐行匹配）
  text = text.replaceAllMapped(
    RegExp(r'^\s*[-*+]\s+', multiLine: true),
    (m) => '· ',
  );
  // 分隔线 → 长破折（列表正则要求符号后有空白+内容，--- 不受影响）
  text = text.replaceAllMapped(
    RegExp(r'^\s*([-*_]\s*){3,}$', multiLine: true),
    (m) => '——',
  );
  // 压缩 3+ 连续空行为 2 个
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}
