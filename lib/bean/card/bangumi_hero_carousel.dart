import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:miru/request/config/hero_banners.dart';
import 'package:miru/services/storage/feed_cache.dart';
import 'package:miru/utils/theme.dart';

/// 首页顶部大横幅轮播。
///
/// 内容固定为 [kHeroBanners]，图片是内置的 16:9 官方主视觉，
/// 不再裁切 Bangumi 的竖版海报，因此不会出现「横切之后很丑」的问题。
///
/// 画面本身已含题字，故不再叠加标题文字，避免重复与遮挡。
class BangumiHeroCarousel extends StatefulWidget {
  const BangumiHeroCarousel({
    super.key,
    this.source = const [],
    this.autoPlay = true,
  });

  /// 已加载的番剧列表，用于点击时按 id 就地取用，避免再发一次请求。
  final List<BangumiItem> source;

  final bool autoPlay;

  @override
  State<BangumiHeroCarousel> createState() => _BangumiHeroCarouselState();
}

class _BangumiHeroCarouselState extends State<BangumiHeroCarousel> {
  late final PageController _controller;
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!widget.autoPlay || kHeroBanners.length <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.animateToPage(
        (_index + 1) % kHeroBanners.length,
        duration: Motion.slow,
        curve: Motion.standard,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 正在打开的横幅，用于显示 loading 并防止重复点击。
  int? _openingId;

  Future<void> _open(HeroBanner banner) async {
    if (_openingId != null) return; // 防抖：避免连点触发多次导航

    // 1) 当前页面已加载的数据
    for (final item in widget.source) {
      if (item.id == banner.subjectId) {
        context.pushNamed('/info/', arguments: item);
        return;
      }
    }

    // 2) 本地缓存兜底。
    //    轮播这几部都在置顶清单里，而置顶清单是落盘的，
    //    所以即使当前列表被标签筛选换掉、或处于离线状态，这里依然能命中，
    //    不必走网络 —— 之前「点了报加载失败」就是卡在网络这一步。
    for (final item in FeedCache.loadPopular()) {
      if (item.id == banner.subjectId) {
        context.pushNamed('/info/', arguments: item);
        return;
      }
    }

    // 未命中才联网。之前这里是静默 await，点下去毫无反馈，
    // 观感就是「卡住了」；现在就地转圈并禁用重复点击。
    setState(() => _openingId = banner.subjectId);
    _timer?.cancel();
    try {
      final fetched = await BangumiApi.getBangumiInfoByID(banner.subjectId);
      if (!mounted) return;
      if (fetched == null) {
        MiruDialog.showToast(
            message: '「${banner.title}」暂时打不开，请检查网络后重试',
            context: context);
        return;
      }
      context.pushNamed('/info/', arguments: fetched);
    } finally {
      if (mounted) {
        setState(() => _openingId = null);
        _restartTimer();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Listener(
            // 手动滑动后重置自动轮播计时，避免刚滑完就被抢走
            onPointerDown: (_) => _timer?.cancel(),
            onPointerUp: (_) => _restartTimer(),
            child: PageView.builder(
              controller: _controller,
              itemCount: kHeroBanners.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final banner = kHeroBanners[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Semantics(
                    label: banner.title,
                    button: true,
                    child: InkWell(
                      borderRadius: Radii.brLg,
                      onTap: () => _open(banner),
                      child: ClipRRect(
                        borderRadius: Radii.brLg,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.asset(
                              banner.asset,
                              fit: BoxFit.cover,
                              // 内置图与容器同为 16:9，这里不会产生裁切
                              filterQuality: FilterQuality.medium,
                            ),
                            if (_openingId == banner.subjectId)
                              const ColoredBox(
                                color: Color(0x66000000),
                                child: Center(
                                  child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: Space.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(kHeroBanners.length, (i) {
            final active = i == _index;
            return AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              // 条目多时缩小圆点，否则一排会挤成一片
              margin: EdgeInsets.symmetric(
                  horizontal: kHeroBanners.length > 8 ? 2 : 3),
              width: active
                  ? (kHeroBanners.length > 8 ? 12 : 16)
                  : (kHeroBanners.length > 8 ? 4 : 6),
              height: kHeroBanners.length > 8 ? 4 : 6,
              decoration: BoxDecoration(
                color: active ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }
}
