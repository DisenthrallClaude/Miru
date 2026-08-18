import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/image_extension.dart';
import 'package:kazumi/services/logging/logger.dart';

class NetworkImgLayer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final String imageUrl = src ?? '';

    //// We need this to shink memory usage
    int? memCacheWidth, memCacheHeight;
    double aspectRatio = (width / height).toDouble();

    void setMemCacheSizes() {
      final sourceAspectRatio = origAspectRatio;
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

    return src != '' && src != null
        ? ClipRRect(
            clipBehavior: Clip.antiAlias,
            borderRadius: borderRadius ??
                BorderRadius.circular(
                  type == 'avatar'
                      ? 50
                      : type == 'emote'
                          ? 0
                          : StyleString.imgRadius.x,
                ),
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              width: width,
              height: height,
              memCacheWidth: memCacheWidth,
              memCacheHeight: memCacheHeight,
              fit: BoxFit.cover,
              alignment: alignment,
              imageBuilder: onLoaded == null
                  ? null
                  : (context, imageProvider) {
                      // 回调必须延到帧后，避免在 build 期间触发 setState
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => onLoaded!.call());
                      return Image(
                        image: imageProvider,
                        width: width,
                        height: height,
                        fit: BoxFit.cover,
                        alignment: alignment,
                        filterQuality: filterQuality,
                        color: color,
                        colorBlendMode: colorBlendMode,
                      );
                    },
              fadeOutDuration:
                  fadeOutDuration ?? const Duration(milliseconds: 120),
              fadeInDuration:
                  fadeInDuration ?? const Duration(milliseconds: 120),
              filterQuality: filterQuality,
              color: color,
              colorBlendMode: colorBlendMode,
              errorListener: (e) {
                KazumiLogger()
                    .w("NetworkImage: network image load error", error: e);
              },
              errorWidget: (BuildContext context, String url, Object error) =>
                  placeholder(context),
              placeholder: (BuildContext context, String url) =>
                  placeholder(context),
            ))
        : placeholder(context);
  }

  Widget placeholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .onInverseSurface
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(type == 'avatar'
            ? 50
            : type == 'emote'
                ? 0
                : StyleString.imgRadius.x),
      ),
      child: type == 'bg'
          ? const SizedBox()
          : Center(
              child: Image.asset(
                type == 'avatar'
                    ? 'assets/images/noface.jpeg'
                    : 'assets/images/loading.png',
                width: width,
                height: height,
                cacheWidth: width.cacheSize(context),
                cacheHeight: height.cacheSize(context),
              ),
            ),
    );
  }
}
