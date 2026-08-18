// 推荐页（仿腾讯视频布局）可视化预览。
//
//   flutter test test/feed_preview_test.dart --update-goldens
// 产物：test/goldens/feed_*.png
//
// 网络封面在测试环境不会加载，图片位置显示为占位块——
// 这正好用来检查版式、角标、文字层级与截断行为。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/card/bangumi_feed_card.dart';
import 'package:kazumi/bean/card/bangumi_hero_carousel.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/utils/theme.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      loader.addFont(File(p).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }

  await load('Noto_Serif_SC', [
    'assets/fonts/NotoSerifSC-Regular.ttf',
    'assets/fonts/NotoSerifSC-SemiBold.ttf',
  ]);
  final icons = File(
      '${Platform.environment['HOME']}/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

BangumiItem _item({
  required int id,
  required String nameCn,
  required String summary,
  required String airDate,
  required double score,
  int votes = 500,
  List<String> tags = const [],
}) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'Sample $id',
    nameCn: nameCn,
    summary: summary,
    airDate: airDate,
    airWeekday: 1,
    rank: 100,
    images: const {},
    tags: tags
        .map((t) => BangumiTag(name: t, count: 10, totalCount: 100))
        .toList(),
    alias: const [],
    ratingScore: score,
    votes: votes,
    votesCount: const [],
    info: '',
  );
}

void main() {
  setUpAll(_loadFonts);

  final year = DateTime.now().year;
  final items = <BangumiItem>[
    _item(
        id: 1,
        nameCn: '葬送的芙莉莲',
        summary: '魔王被打倒后，精灵魔法使芙莉莲踏上了重新认识人类的旅程。这是一个关于时间与告别的故事。',
        airDate: '$year-10-01',
        score: 9.1,
        votes: 8000,
        tags: ['奇幻', '治愈']),
    _item(
        id: 2,
        nameCn: '孤独摇滚！',
        summary: '极度内向的后藤一里想要加入乐队，却连搭话都做不到。',
        airDate: '2022-10-08',
        score: 8.7,
        votes: 6000,
        tags: ['音乐', '搞笑']),
    _item(
        id: 3,
        nameCn: '间谍过家家 第二季',
        summary: '为了世界和平，间谍、杀手与超能力少女组成了一个假家庭。',
        airDate: '2023-10-07',
        score: 8.2,
        tags: ['喜剧']),
    _item(
        id: 4,
        nameCn: '夏日重现',
        summary: '回到故乡的慎平被卷入了不断重复的夏日循环。',
        airDate: '2022-04-15',
        score: 8.4,
        tags: ['悬疑']),
    _item(
        id: 5,
        nameCn: '进击的巨人 最终季',
        summary: '',
        airDate: '2021-01-01',
        score: 0,
        tags: ['战斗', '剧情']),
    _item(
        id: 6,
        nameCn: '一个标题非常非常长用来测试单行截断行为的番剧名称',
        summary: '副标题也故意写得很长，用来确认省略号是否正确出现而不是溢出。',
        airDate: '$year-01-01',
        score: 7.5),
  ];

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final name = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('feed layout preview – $name', (tester) async {
      tester.view.physicalSize = const Size(1170, 2100);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildKazumiTheme(
            brightness: brightness, fontFamily: 'Noto_Serif_SC'),
        home: Builder(builder: (context) {
          return Scaffold(
            body: SafeArea(
              child: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text('热门番组',
                        style: Theme.of(context).textTheme.displayMedium),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  sliver: SliverMainAxisGroup(slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: BangumiHeroCarousel(
                            source: items, autoPlay: false),
                      ),
                    ),
                    SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        mainAxisExtent: 120 / 0.65 + 46,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (c, i) => BangumiFeedCardV(bangumiItem: items[i]),
                        childCount: items.length,
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        }),
      ));
      await tester.pumpAndSettle();

      // 与 design_preview 相同：CI 字体路径和本机不一致，不做像素对比。
      expect(find.text('热门番组'), findsOneWidget);
      expect(find.text('葬送的芙莉莲'), findsWidgets);
    });
  }
}
