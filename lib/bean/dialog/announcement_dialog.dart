import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/modules/announcement/announcement.dart';
import 'package:url_launcher/url_launcher.dart';

/// 远程公告弹窗：纯白极简液态玻璃卡片（与管理端 Web 预览一致）。
///
/// 结构自上而下：可选封面图（16:9，加载失败整体收起退化为纯文字
/// 卡片）→ 标题（加粗，应用 font 字体）→ 正文（纯文本，\n 换行，
/// 最多滚动约 40% 屏高）→ 按钮组（规格上限 2 个，超出忽略）。
/// 白色半透明玻璃底 + 模糊 + 圆角 24 + 细白描边 + 柔和投影；
/// 文字用深色（白卡上对比稳定，与主题无关）。
/// 关闭途径：右上角 ✕、系统返回键；点遮罩不关闭（规格：防误触）。
class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({super.key, required this.announcement});

  final Announcement announcement;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(24));

  // 白玻璃卡上的固定前景色：不随主题翻转，保证任何主题下可读。
  static const Color _ink = Color(0xFF1F2328);
  static const Color _inkSoft = Color(0xFF57606A);
  static const Color _accent = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    final font = announcement.resolvedFont;

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
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (announcement.coverImage.isNotEmpty)
                        _CoverImage(url: announcement.coverImage),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          announcement.coverImage.isEmpty ? 44 : 18,
                          24,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              announcement.title,
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                                color: _ink,
                                fontFamily: font.fontFamily,
                                fontFamilyFallback: font.fallback,
                              ),
                            ),
                            if (announcement.body.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Flexible(
                                child: SingleChildScrollView(
                                  child: Text(
                                    announcement.body,
                                    style: TextStyle(
                                      fontSize: 15,
                                      height: 1.6,
                                      color: _inkSoft,
                                      fontFamily: font.fontFamily,
                                      fontFamilyFallback: font.fallback,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (announcement.actions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            alignment: WrapAlignment.end,
                            children: [
                              // 规格上限：最多渲染 2 个动作按钮。
                              for (final action
                                  in announcement.actions.take(2))
                                _ActionButton(action: action),
                            ],
                          ),
                        ),
                      const SizedBox(height: 20),
                    ],
                  ),
                  // 关闭按钮：贴右上角，玻璃小圆片，不压封面图主体。
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context, rootNavigator: true)
                          .pop(),
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

/// 封面图：16:9。加载失败时整体收起（规格：退化为无图纯文字卡片，
/// 不留灰块、不报错）。
class _CoverImage extends StatefulWidget {
  const _CoverImage({required this.url});

  final String url;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: CachedNetworkImage(
        imageUrl: widget.url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          color: Colors.white.withValues(alpha: 0.25),
        ),
        errorWidget: (_, __, ___) {
          // 下一帧再收起，避免在 build 中触发 setState。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _failed = true);
          });
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

/// 动作按钮：胶囊形，url 类型拉起外部浏览器；其余（clipboard 及未知）
/// 一律复制到剪贴板并 toast 反馈——管理页未来新增类型时旧客户端
/// 也不至于无响应。
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});

  final AnnouncementAction action;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: AnnouncementDialog._accent,
        side: BorderSide(
          color: AnnouncementDialog._accent.withValues(alpha: 0.55),
          width: 1,
        ),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        minimumSize: const Size(0, 38),
      ),
      onPressed: () => _handleTap(context),
      child: Text(action.label),
    );
  }

  Future<void> _handleTap(BuildContext context) async {
    if (action.isUrl) {
      final uri = Uri.tryParse(action.value);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
      // 链接无法拉起（设备无浏览器/链接格式异常）时退化为复制，
      // 至少把内容留给用户。
    }
    await Clipboard.setData(ClipboardData(text: action.value));
    MiruDialog.showToast(message: '已复制');
  }
}
