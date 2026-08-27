import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/modules/announcement/announcement.dart';
import 'package:url_launcher/url_launcher.dart';

/// 远程公告弹窗：液态玻璃卡片风格，极简布局。
///
/// 结构自上而下：可选封面图（16:9）→ 标题 → 正文（纯文本，换行保留，
/// 最多滚动约 40% 屏高）→ 按钮组（最多渲染 3 个，超出忽略）。
/// 关闭途径：右上角 × 、点遮罩、系统返回键，三种都经由路由 pop，
/// 频控记录由 AnnouncementService 在 onDismiss 统一处理。
class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({super.key, required this.announcement});

  final Announcement announcement;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(28));

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: FrostedSurface(
          borderRadius: _radius,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 0.8,
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
                        announcement.coverImage.isEmpty ? 40 : 18,
                        24,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            announcement.title,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          if (announcement.body.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Flexible(
                              child: SingleChildScrollView(
                                child: Text(
                                  announcement.body,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color:
                                        colorScheme.onSurface.withValues(
                                            alpha: 0.85),
                                    height: 1.6,
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
                            for (final action
                                in announcement.actions.take(3))
                              _ActionButton(action: action),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
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
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面图：16:9，加载中给玻璃色占位，失败退化为灰色占位（不影响弹窗）。
class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          color: Colors.white.withValues(alpha: 0.06),
        ),
        errorWidget: (_, __, ___) => Container(
          color: Colors.white.withValues(alpha: 0.06),
          child: Icon(
            Icons.image_outlined,
            size: 32,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

/// 动作按钮：url 类型拉起外部浏览器；其余（clipboard 及未知）一律复制到
/// 剪贴板并 toast 反馈——管理页未来新增类型时旧客户端也不至于无响应。
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});

  final AnnouncementAction action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.primary,
        side: BorderSide(
          color: colorScheme.primary.withValues(alpha: 0.55),
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
