import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:antlr4/antlr4.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:miru/bean/widget/image_preview.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bbcode_base_listener.dart';
import 'bbcode_elements.dart';
import 'generated/BBCodeParser.dart';
import 'generated/BBCodeLexer.dart';

class BBCodeWidget extends StatefulWidget {
  const BBCodeWidget({super.key, required this.bbcode});

  final String bbcode;

  @override
  State<StatefulWidget> createState() => _BBCodeWidgetState();
}

class _BBCodeWidgetState extends State<BBCodeWidget> {
  bool _isVisible = false;

  /// 渲染缓存（F15）：同一段 bbcode 且遮罩状态不变时复用 TextSpan 树，
  /// 不再每次 build 现场重跑 ANTLR 全量解析（setState 切遮罩也不再重解析）。
  ///
  /// 缓存键还包含主题取色（N2/F15 回归）：span 树里的引用文字/引用
  /// 图标取 colorScheme.outline，只看 source+visible 会在切深浅色后
  /// 复用旧主题的 span（引用文字/图标持旧 outline 色，对比度失效）。
  String? _cachedSource;
  bool? _cachedVisible;
  Color? _cachedOutlineColor;
  List<InlineSpan> _cachedSpans = const [];

  /// 当前缓存树里创建的手势识别器；缓存失效时统一释放（F15：
  /// 此前每帧新建 TapGestureRecognizer 且从不 dispose）。
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void didUpdateWidget(covariant BBCodeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bbcode != widget.bbcode) {
      _invalidateSpans();
    }
  }

  @override
  void dispose() {
    _invalidateSpans();
    super.dispose();
  }

  void _invalidateSpans() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _cachedSource = null;
    _cachedVisible = null;
    _cachedOutlineColor = null;
    _cachedSpans = const [];
  }

  /// color 可以为三种表现形式
  ///
  /// `ARGB: #FFFFFFFF`
  ///
  /// `RGB: #FFFFFF`
  ///
  /// `NAME: red`
  ///
  /// 若全部解析失败则返回 null 使用默认颜色
  Color? _parseColor(String hex) {
    if (hex.startsWith('#')) {
      hex = hex.replaceFirst('#', '');
      if (hex.length == 6) {
        hex = "FF$hex";
      }
      if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }
    switch (hex) {
      case 'red':
        return Colors.red;
      case 'blue':
        return Colors.blue;
      case 'orange':
        return Colors.orange;
      case 'green':
        return Colors.green;
      case 'grey':
        return Colors.grey;
      default:
        return null;
    }
  }

  /// 只放行 http(s) 链接：[url=javascript:…] 等任意 scheme 不应被拉起；
  /// 解析失败/拉起失败静默忽略，防止点击恶意链接抛异常（F16）。
  Future<void> _openLink(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      MiruLogger().w('BBCode: blocked non-http link: $link');
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      MiruLogger().w('BBCode: open link failed', error: e);
    }
  }

  List<InlineSpan> _buildSpans() {
    BBCodeParser.checkVersion();
    final input = InputStream.fromString(widget.bbcode);
    final lexer = BBCodeLexer(input);
    final tokens = CommonTokenStream(lexer);
    final parser = BBCodeParser(tokens);
    final tree = parser.document();
    final bbcodeBaseListener = BBCodeBaseListener();
    try {
      ParseTreeWalker.DEFAULT.walk(bbcodeBaseListener, tree);
    } finally {
      // 解析抛异常也要清掉全局单例的标签位置，避免脏状态残留（F17）。
      bbCodeTag.clear();
    }

    final imageUrls = bbcodeBaseListener.bbcode
        .whereType<BBCodeImg>()
        .map((e) => e.imageUrl)
        .toList();
    var imageIndex = 0;

    return bbcodeBaseListener.bbcode.map((e) {
      if (e is BBCodeText) {
        Color? textColor = (!_isVisible && e.masked)
            ? Colors.transparent
            : (e.link != null)
                ? Colors.blue
                : (e.quoted)
                    ? Theme.of(context).colorScheme.outline
                    : (e.color != null)
                        ? _parseColor(e.color!)
                        : null;
        TapGestureRecognizer? recognizer;
        if (e.link != null || e.masked) {
          recognizer = TapGestureRecognizer()
            ..onTap = () {
              if ((!e.masked || _isVisible) && e.link != null) {
                _openLink(e.link!);
              } else if (e.masked) {
                setState(() {
                  _isVisible = !_isVisible;
                });
              }
            };
          _recognizers.add(recognizer);
        }
        return TextSpan(
          text: e.text,
          mouseCursor: (e.link != null || e.masked)
              ? SystemMouseCursors.click
              : SystemMouseCursors.text,
          recognizer: recognizer,
          style: TextStyle(
            fontWeight: (e.bold) ? FontWeight.bold : null,
            fontStyle: (e.italic) ? FontStyle.italic : null,
            decoration: TextDecoration.combine([
              if (e.underline || e.link != null) TextDecoration.underline,
              if (e.strikeThrough) TextDecoration.lineThrough,
            ]),
            decorationColor: textColor,
            fontSize: e.size.toDouble(),
            color: textColor,
            backgroundColor:
                (!_isVisible && e.masked) ? Color(0xFF555555) : null,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        );
      } else if (e is BBCodeImg) {
        final currentIndex = imageIndex++;
        final heroTag = ImageViewer.heroTagFor(e.imageUrl, currentIndex);
        return WidgetSpan(
          child: GestureDetector(
            onTap: () => ImageViewer.show(
              context,
              imageUrls: imageUrls,
              initialIndex: currentIndex,
              heroTag: heroTag,
            ),
            child: Hero(
              tag: heroTag,
              child: CachedNetworkImage(
                imageUrl: e.imageUrl,
                placeholder: (context, url) =>
                    const SizedBox(width: 1, height: 1),
                errorWidget: (context, error, stackTrace) {
                  return const Text('.');
                },
              ),
            ),
          ),
        );
      } else if (e is BBCodeBgm) {
        return WidgetSpan(
          child: CachedNetworkImage(
            // F7：互斥分段构造（历史版本连续 if 且末行无条件覆盖，
            // id≤23 全部请求 tv/负数.gif 必 404，渲染成「.」）。
            imageUrl: BBCodeBgm.smileUrl(e.id),
            placeholder: (context, url) => const SizedBox(width: 1, height: 1),
            errorWidget: (context, error, stackTrace) {
              return const Text('.');
            },
          ),
        );
      } else if (e is BBCodeMusume) {
        return WidgetSpan(
          child: CachedNetworkImage(
            imageUrl:
                'https://lain.bgm.tv/img/smiles/musume/musume_${e.id}.gif',
            placeholder: (context, url) => const SizedBox(width: 1, height: 1),
            errorWidget: (context, error, stackTrace) {
              return const Text('.');
            },
            width: 50,
            height: 50,
          ),
        );
      } else if (e is BBCodeSticker) {
        return WidgetSpan(
          child: CachedNetworkImage(
            imageUrl: 'https://bangumi.tv/img/smiles/${e.id}.gif',
            placeholder: (context, url) => const SizedBox(width: 1, height: 1),
            errorWidget: (context, error, stackTrace) {
              return const Text('.');
            },
          ),
        );
      } else {
        // e is Icon
        return WidgetSpan(
          child: Icon(
            (e as Icon).icon,
            color: Theme.of(context).colorScheme.outline,
          ),
          alignment: PlaceholderAlignment.top,
        );
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Theme.of 每帧读取：既建立 inherited 依赖（主题切换必触发重建），
    // 又以取色值本身做缓存失效条件（N2，见 _cachedOutlineColor 注释）。
    final outlineColor = Theme.of(context).colorScheme.outline;
    if (_cachedSource != widget.bbcode ||
        _cachedVisible != _isVisible ||
        _cachedOutlineColor != outlineColor) {
      _invalidateSpans();
      _cachedSource = widget.bbcode;
      _cachedVisible = _isVisible;
      _cachedOutlineColor = outlineColor;
      _cachedSpans = _buildSpans();
    }

    return Wrap(
      children: [
        RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: _cachedSpans,
          ),
        ),
      ],
    );
  }
}
