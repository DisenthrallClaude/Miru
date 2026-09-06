import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';

/// v1.6.4 自定义字体服务。
///
/// 内置一份精选字体目录（默认全部「未下载」——不占安装包体积，
/// 用户看中哪款下载哪款），下载到应用支持目录后用 [FontLoader]
/// 动态注册，全程无需重启即可生效。
///
/// 字体选择标准：
/// * 免费商用授权（OFL / 官方免费授权），可用于任意场景；
/// * 有真实可验证的直链（全部经过 HEAD 探测 200）；
/// * 风格覆盖：楷体 / 黑体 / 手写 / 毛笔 / 可爱——审美差异大，
///   每款都能撑起一种界面气质。
///
/// 下载源策略：每款字体主源 + 镜像源（GitHub Releases 与 jsDelivr
/// CDN 互为镜像），单源被墙/限速时自动切换重试。
class CustomFontService {
  CustomFontService._();

  static final CustomFontService instance = CustomFontService._();

  /// 字体目录（静态精选，按风格分组排序）。
  static const List<CustomFontEntry> catalog = [
    CustomFontEntry(
      id: 'lxgw-wenkai',
      name: '霞鹜文楷',
      style: '楷体 · 温润书卷气',
      license: 'SIL OFL 1.1',
      sizeBytes: 19091920,
      family: 'LXGW WenKai',
      previewText: '霞鹜文楷 清雅温润',
      files: [
        'https://github.com/lxgw/LxgwWenKai/releases/download/v1.520/LXGWWenKai-Regular.ttf',
        'https://github.com/lxgw/LxgwWenKai/releases/download/v1.520/LXGWWenKai-Medium.ttf',
      ],
      mirrors: [
        'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai@v1.520/LXGWWenKai-Regular.ttf',
      ],
      weights: [400, 500],
    ),
    CustomFontEntry(
      id: 'lxgw-wenkai-lite',
      name: '霞鹜文楷 Lite',
      style: '楷体 · 轻量屏显',
      license: 'SIL OFL 1.1',
      sizeBytes: 9094052,
      family: 'LXGW WenKai Lite',
      previewText: '轻若无物 惜字如金',
      files: [
        'https://github.com/lxgw/LxgwWenkai-Lite/releases/download/v1.200/LXGWWenKaiLite-Regular.ttf',
      ],
      mirrors: [
        'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenkai-Lite@v1.200/LXGWWenKaiLite-Regular.ttf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'noto-sans-sc',
      name: '思源黑体',
      style: '黑体 · 现代通用',
      license: 'SIL OFL 1.1',
      sizeBytes: 8331336,
      family: 'Noto Sans SC',
      previewText: '现代 简洁 通用',
      files: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'zcool-kuaile',
      name: '站酷快乐体',
      style: '可爱 · 圆润活泼',
      license: '免费商用',
      sizeBytes: 1514968,
      family: 'ZCOOL KuaiLe',
      previewText: '快乐每一天',
      files: [
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/google/fonts/main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'longcang',
      name: '龙藏体',
      style: '手写 · 行楷流畅',
      license: 'SIL OFL 1.1',
      sizeBytes: 5162508,
      family: 'Long Cang',
      previewText: '行云流水 一气呵成',
      files: [
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/longcang/LongCang-Regular.ttf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/google/fonts/main/ofl/longcang/LongCang-Regular.ttf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'mashanzheng',
      name: '马善政体',
      style: '毛笔 · 楷书笔意',
      license: 'SIL OFL 1.1',
      sizeBytes: 4236820,
      family: 'Ma Shan Zheng',
      previewText: '笔走龙蛇 力透纸背',
      files: [
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/google/fonts/main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'zhimangxing',
      name: '志莽行书',
      style: '手写 · 硬笔行书',
      license: 'SIL OFL 1.1',
      sizeBytes: 4573668,
      family: 'Zhi Mang Xing',
      previewText: '日常书写 随性洒脱',
      files: [
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zhimangxing/ZhiMangXing-Regular.ttf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/google/fonts/main/ofl/zhimangxing/ZhiMangXing-Regular.ttf',
      ],
      weights: [400],
    ),
    CustomFontEntry(
      id: 'liujianmaocao',
      name: '柳建毛草',
      style: '草书 · 恣意奔放',
      license: 'SIL OFL 1.1',
      sizeBytes: 4398744,
      family: 'Liu Jian Mao Cao',
      previewText: '狂草纵横 挥洒自如',
      files: [
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf',
      ],
      mirrors: [
        'https://raw.githubusercontent.com/google/fonts/main/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf',
      ],
      weights: [400],
    ),
  ];

  /// 当前激活的字体 id（空 = 未启用自定义字体）。
  String get activeFontId => GStorage.getSetting(SettingsKeys.customFontId);

  /// 当前激活的字体 family（null = 走内置/系统逻辑）。
  String? get activeFamily {
    final id = activeFontId;
    if (id.isEmpty) return null;
    for (final entry in catalog) {
      if (entry.id == id) return entry.family;
    }
    return null;
  }

  /// 是否已下载到本地（目录存在且至少一个字体文件）。
  Future<bool> isDownloaded(String id) async {
    final dir = await _fontDirectory(id);
    if (!await dir.exists()) return false;
    final files = await dir.list().toList();
    return files.any((f) => f is File && f.path.endsWith('.ttf'));
  }

  /// 字体下载目录：`<appSupport>/custom_fonts/<id>/`。
  Future<Directory> _fontDirectory(String id) async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/custom_fonts/$id');
  }

  /// 下载一款字体（主源失败自动换镜像源）。
  ///
  /// [onProgress] 收到 0.0~1.0 的总进度。下载完成后自动
  /// [FontLoader] 注册，无需重启。
  Future<void> download(
    CustomFontEntry entry, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await _fontDirectory(entry.id);
    await dir.create(recursive: true);

    // 候选源：主源在前、镜像在后；全部尝试一轮。
    final candidates = [...entry.files, ...entry.mirrors];
    var fileIndex = 0; // entry.files 的下载游标
    var candidateIndex = 0;

    while (fileIndex < entry.files.length &&
        candidateIndex < candidates.length) {
      final url = candidates[candidateIndex];
      final fileName = entry.files[fileIndex].split('/').last;
      final target = File('${dir.path}/$fileName');

      try {
        await Dio().download(
          url,
          target.path,
          options: Options(
            // GitHub 直链/CDN 可能给 gzip；按解码后的字节流落盘。
            receiveTimeout: const Duration(minutes: 5),
            headers: {'accept-encoding': 'identity'},
          ),
          onReceiveProgress: (count, totalBytes) {
            if (totalBytes > 0 && onProgress != null) {
              final overall =
                  (fileIndex + count / totalBytes) / entry.files.length;
              onProgress(overall.clamp(0.0, 0.99));
            }
          },
        );
        fileIndex++;
        // 文件下载成功后候选源重置为主源（下一个文件从主源开始）。
        candidateIndex = 0;
      } catch (e) {
        MiruLogger().w('CustomFont: download failed $url', error: e);
        if (await target.exists()) {
          await target.delete();
        }
        candidateIndex++;
        if (candidateIndex >= candidates.length) {
          throw Exception('字体下载失败：所有源均不可达，请检查网络后重试');
        }
      }
    }

    await _registerFont(entry, dir);
    if (onProgress != null) onProgress(1.0);
  }

  /// 注册字体（FontLoader 动态注册，立即生效；幂等可重复调用）。
  Future<void> _registerFont(CustomFontEntry entry, Directory dir) async {
    final loader = FontLoader(entry.family);
    var loaded = 0;
    final files = await dir
        .list()
        .where((f) => f is File && f.path.endsWith('.ttf'))
        .cast<File>()
        .toList();
    for (final file in files) {
      final bytes = await file.readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      loaded++;
    }
    if (loaded == 0) {
      throw Exception('字体文件缺失');
    }
    await loader.load();
  }

  /// 激活一款字体：确保已下载（必要时先下载）→ 注册 → 写入设置。
  Future<void> activate(
    CustomFontEntry entry, {
    void Function(double progress)? onProgress,
  }) async {
    if (!await isDownloaded(entry.id)) {
      await download(entry, onProgress: onProgress);
    } else {
      final dir = await _fontDirectory(entry.id);
      await _registerFont(entry, dir);
    }
    await GStorage.putSetting(SettingsKeys.customFontId, entry.id);
  }

  /// 启动时恢复已激活字体（main.runApp 前调用）。
  ///
  /// 失败静默（文件损坏/误删）并自动取消激活——比带着一个指向
  /// 不存在 family 的 fontFamily 渲染成系统默认字体更诚实，
  /// 用户在 设置 → 外观 → 自定义字体 里重新下载即可。
  Future<void> restoreActiveFont() async {
    final id = activeFontId;
    if (id.isEmpty) return;
    final entry = catalog.where((e) => e.id == id).firstOrNull;
    if (entry == null) {
      await deactivate();
      return;
    }
    try {
      final dir = await _fontDirectory(entry.id);
      await _registerFont(entry, dir);
    } catch (e) {
      MiruLogger().w('CustomFont: restore failed, deactivated', error: e);
      await deactivate();
    }
  }

  /// 取消激活（回到内置/系统字体逻辑）。已下载文件保留，
  /// 用户再次激活时秒切（FontLoader 重复注册幂等）。
  Future<void> deactivate() async {
    await GStorage.putSetting(SettingsKeys.customFontId, '');
  }

  /// 删除一款已下载字体的本地文件（若正在使用则同时取消激活）。
  Future<void> deleteLocal(String id) async {
    if (activeFontId == id) {
      await deactivate();
    }
    final dir = await _fontDirectory(id);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

/// 字体目录条目。
class CustomFontEntry {
  const CustomFontEntry({
    required this.id,
    required this.name,
    required this.style,
    required this.license,
    required this.sizeBytes,
    required this.family,
    required this.previewText,
    required this.files,
    this.mirrors = const [],
    this.weights = const [400],
  });

  /// 稳定 id（存储键）。
  final String id;

  /// 展示名。
  final String name;

  /// 风格描述（一行）。
  final String style;

  /// 授权说明。
  final String license;

  /// 主文件字节大小（展示用估算）。
  final int sizeBytes;

  /// FontLoader 注册的 family 名（激活后 fontFamily 用它）。
  final String family;

  /// 预览文案（字体页用对应字体渲染）。
  final String previewText;

  /// 主源直链（按字重顺序）。
  final List<String> files;

  /// 镜像源直链。
  final List<String> mirrors;

  /// 覆盖字重。
  final List<int> weights;

  /// 展示用下载大小。
  String get sizeLabel {
    final mb = sizeBytes / 1024 / 1024;
    if (mb < 1) return '${(sizeBytes / 1024).round()} KB';
    return mb.toStringAsFixed(1);
  }
}
