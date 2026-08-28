import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/utils/image_extension.dart';
import 'package:miru/services/logging/logger.dart';

class NetworkImgLayer extends StatefulWidget {
  const NetworkImgLayer({
    super.key,
    this.src,
    required this.width,
    required this.height,
    this.type,
    this.fadeOutDuration,
    this.fadeInDuration,
    this.quality,
    this.origAspectRatio,
    this.filterQuality = FilterQuality.high,
    this.color,
    this.colorBlendMode,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.onLoaded,
  });

  final String? src;
  final double width;
  final double height;
  final String? type;
  final Duration? fadeOutDuration;
  final Duration? fadeInDuration;
  final int? quality;
  final double? origAspectRatio;
  final FilterQuality filterQuality;
  final Color? color;
  final BlendMode? colorBlendMode;

  /// BoxFit.cover 的裁切锚点。竖版海报放进横向卡片时，
  /// 用 topCenter 能保住主视觉，避免裁掉人物头部。
  final Alignment alignment;

  /// 覆盖默认圆角（默认走 StyleString.imgRadius）。
  final BorderRadius? borderRadius;

  /// 图片解码完成后回调（每个 widget 实例只触发一次）。
  /// 用于「谁先加载完谁排前面」的信息流排序。
  final VoidCallback? onLoaded;

  static Widget heroFlightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final fromHero = fromHeroContext.widget as Hero;
    final toHero = toHeroContext.widget as Hero;
    final heroContext = flightDirection == HeroFlightDirection.push
        ? fromHeroContext
        : toHeroContext;
    final hero =
        flightDirection == HeroFlightDirection.push ? fromHero : toHero;

    return InheritedTheme.captureAll(
      heroContext,
      Material(
        type: MaterialType.transparency,
        child: hero.child,
      ),
    );
  }

  @override
  State<NetworkImgLayer> createState() => _NetworkImgLayerState();
}

class _NetworkImgLayerState extends State<NetworkImgLayer> {
  /// 换 key 强制 CachedNetworkImage 重建 State 并重新发起加载。
  /// flutter_cache_manager 不会缓存失败的下载（只落盘成功响应），
  /// 因此重建即是一次真实的重试，无需手动清磁盘缓存。
  Key _imageKey = UniqueKey();

  void _retryLoad() {
    setState(() {
      _imageKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final String imageUrl = widget.src ?? '';
    final double width = widget.width;
    final double height = widget.height;
    final String? type = widget.type;

    //// We need this to shink memory usage
    int? memCacheWidth, memCacheHeight;
    double aspectRatio = (width / height).toDouble();

    void setMemCacheSizes() {
      final sourceAspectRatio = widget.origAspectRatio;
      if (sourceAspectRatio != null) {
        // BoxFit.cover needs the decoded image to fill the target's limiting
        // axis. A portrait source shown in a landscape box must therefore be
        // decoded by width, otherwise it is downscaled and enlarged again.
        if (sourceAspectRatio < aspectRatio) {
          memCacheWidth = width.cacheSize(context);
        } else if (sourceAspectRatio > aspectRatio) {
          memCacheHeight = height.cacheSize(context);
        } else {
          memCacheWidth = width.cacheSize(context);
          memCacheHeight = height.cacheSize(context);
        }
        return;
      }
      if (aspectRatio > 1) {
        memCacheHeight = height.cacheSize(context);
      } else if (aspectRatio < 1) {
        memCacheWidth = width.cacheSize(context);
      } else {
        memCacheWidth = width.cacheSize(context);
        memCacheHeight = height.cacheSize(context);
      }
    }

    setMemCacheSizes();

    if (memCacheWidth == null && memCacheHeight == null) {
      memCacheWidth = width.toInt();
    }

    return widget.src != '' && widget.src != null
        ? ClipRRect(
            clipBehavior: Clip.antiAlias,
            borderRadius: widget.borderRadius ??
                BorderRadius.circular(
                  type == 'avatar'
                      ? 50
                      : type == 'emote'
                          ? 0
                          : StyleString.imgRadius.x,
                ),
            child: CachedNetworkImage(
              key: _imageKey,
              imageUrl: imageUrl,
              width: width,
              height: height,
              memCacheWidth: memCacheWidth,
              memCacheHeight: memCacheHeight,
              fit: BoxFit.cover,
              alignment: widget.alignment,
              imageBuilder: widget.onLoaded == null
                  ? null
                  : (context, imageProvider) {
                      // 回调必须延到帧后，避免在 build 期间触发 setState
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => widget.onLoaded!.call());
                      return Image(
                        image: imageProvider,
                        width: width,
                        height: height,
                        fit: BoxFit.cover,
                        alignment: widget.alignment,
                        filterQuality: widget.filterQuality,
                        color: widget.color,
                        colorBlendMode: widget.colorBlendMode,
                      );
                    },
              fadeOutDuration:
                  widget.fadeOutDuration ?? const Duration(milliseconds: 120),
              fadeInDuration:
                  widget.fadeInDuration ?? const Duration(milliseconds: 120),
              filterQuality: widget.filterQuality,
              color: widget.color,
              colorBlendMode: widget.colorBlendMode,
              errorListener: (e) {
                MiruLogger()
                    .w("NetworkImage: network image load error", error: e);
              },
              // 失败态必须与加载占位可区分：之前两者同款，
              // 封面失败时永远停在「加载中」观感，用户无从感知也无法重试。
              errorWidget: (BuildContext context, String url, Object error) =>
                  errorPlaceholder(context, _retryLoad),
              placeholder: (BuildContext context, String url) =>
                  placeholder(context),
            ))
        : placeholder(context);
  }

  Widget placeholder(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .onInverseSurface
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(widget.type == 'avatar'
            ? 50
            : widget.type == 'emote'
                ? 0
                : StyleString.imgRadius.x),
      ),
      child: widget.type == 'bg'
          ? const SizedBox()
          : Center(
              child: Image.asset(
                widget.type == 'avatar'
                    ? 'assets/images/noface.jpeg'
                    : 'assets/images/loading.png',
                width: widget.width,
                height: widget.height,
                cacheWidth: widget.width.cacheSize(context),
                cacheHeight: widget.height.cacheSize(context),
              ),
            ),
    );
  }

  /// 失败态：底色/圆角与加载占位一致，但内容换为错误图标与
  /// 「加载失败 点击重试」文案，点击可重试（换 key 重新加载）。
  Widget errorPlaceholder(BuildContext context, VoidCallback onRetry) {
    final theme = Theme.of(context);
    // 纯装饰背景（'bg'）保持占位原样：它本身就不展示内容
    if (widget.type == 'bg') return placeholder(context);
    return Container(
      width: widget.width,
      height: widget.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.onInverseSurface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(widget.type == 'avatar'
            ? 50
            : widget.type == 'emote'
                ? 0
                : StyleString.imgRadius.x),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onRetry,
          child: Center(
            // 容器可能很小（头像/表情），整体缩放避免溢出
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_not_supported_outlined,
                      size: 22,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '加载失败 点击重试',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
