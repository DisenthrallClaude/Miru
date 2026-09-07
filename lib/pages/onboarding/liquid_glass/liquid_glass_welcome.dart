import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'liquid_glass_controller.dart';
import 'liquid_glass_copy_widgets.dart';
import 'liquid_glass_painters.dart';
import 'liquid_glass_shaders.dart';
import 'liquid_glass_theme.dart';

/// 液态玻璃欢迎屏 —— 复刻 Appllama/liquid-glass-screens 的
/// LiquidGlassScreen（Sky/Astro 两主题合一，按昼夜选择）。
///
/// 一个手势擦洗整页：巨大的玻璃穹顶坐在底缘；上滑把它推向屏中，
/// 一路缩小成 + 按钮；落定后贴纸从按钮的玻璃里升起结成羽流，
/// 文案与 CTA 淡入；下拉则重新放大并收回羽流
/// （Sky 坠落淡出 / Astro 星尘漩涡入芯）。
///
/// v1.6.2：透镜改为真实 BackdropFilter（ImageFilter.shader，
/// Impeller），与原版 Skia BackdropFilter + RuntimeShader 同构——
/// 背景视频/星场与贴纸都会被球体真实折射；贴纸按槽位尺寸绘制；
/// 层序与原版一致（背景 → 贴纸 → 透镜 → 玻璃）。
class LiquidGlassWelcome extends StatefulWidget {
  const LiquidGlassWelcome({
    super.key,
    required this.theme,
    required this.onEnter,
    required this.onEnterViaGithub,
  });

  final LiquidGlassTheme theme;

  /// 主 CTA「直接进入」。
  final VoidCallback onEnter;

  /// 次入口「通过 GitHub 进入」。
  final VoidCallback onEnterViaGithub;

  @override
  State<LiquidGlassWelcome> createState() => _LiquidGlassWelcomeState();
}

class _LiquidGlassWelcomeState extends State<LiquidGlassWelcome>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  LiquidGlassController? _controller;
  late final Ticker _ticker;

  List<ui.Image?> _stickers = const [];
  ui.Image? _scene;
  ui.Image? _glowImage;
  bool _shadersReady = false;

  /// v1.6.6（C-1）：preload 彻底失败（永久降级到多层渐变球）标记。
  bool _shaderLoadFailed = false;

  // Sky 视频背景。
  Player? _player;
  VideoController? _videoController;
  bool _videoReady = false;

  double _sx = 1;
  double _sy = 1;
  Size _size = Size.zero;
  String? _themeId;

  /// v1.6.6（A-7）：跟踪系统「移除动画」偏好，变化时 retune 弹簧参数。
  bool? _reduceMotion;

  /// v1.6.6（C-6）：_scene 捕获时的逻辑尺寸（旋转后重捕获依据）。
  Size _lastSceneSize = Size.zero;

  LiquidGlassTheme get theme => widget.theme;

  LiquidGlassController get controller => _controller!;

  /// v1.6.3 统一文案/字标尺度：取 sx/sy 中较小者。
  ///
  /// 原版常量以 402×874 为基准、字号随 sx 走、行位随 h 分数走：
  /// 在宽高比偏离基准的屏上（尤其 w/h≥0.46 的偏宽/偏短屏——16:9 短屏、
  /// 横屏、平板；长屏反而因 0.7032h-0.6163h 差恒定而安全），
  /// 「两行标题块底部 0.6163h+76sx」会追上甚至越过第三行顶部 0.7032h，
  /// 造成文字重叠；宽屏/横屏/平板则字标爆炸。统一尺度后
  /// 全部元素随同一比例缩放，叠行由相对堆叠定位兜底。
  double get _cs => math.min(_sx, _sy);

  @override
  void initState() {
    super.initState();
    // v1.6.6（B-2）：跟随生命周期暂停/恢复 Sky 视频。
    // pauseUponEnteringBackgroundMode 保持 false（避开 media_kit
    // 内部暂停-恢复的首帧黑闪），后台解码由这里显式停掉——
    // 开屏页是「看一眼通知再回来」的高发页，不该在后台空烧 GPU。
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick);
    _ticker.start();
    unawaited(_prepare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = _player;
    // _videoReady：open() 已成功（测试环境下 Player 构造可能残留
    // 半初始化实例，避免对其调用平台通道）。
    if (player == null || !_videoReady) return;
    if (state == AppLifecycleState.paused) {
      unawaited(player.pause());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(player.play());
    }
  }

  void _onTick(Duration elapsed) {
    _controller?.tick(elapsed);
  }

  Future<void> _prepare() async {
    final ready = await LiquidGlassShaders.preload();
    if (mounted) {
      setState(() {
        _shadersReady = ready;
        // v1.6.6（C-1）：只有彻底失败才永久降级；未就绪期间
        // 玻璃球不画半成品（见 _buildGlass）。
        _shaderLoadFailed = !ready;
      });
    }
    await _loadStickers();
    await _loadGlowImage();
    if (theme.videoAsset != null) {
      await _initVideo();
    } else if (!_realLens) {
      // v1.6.6（D-2）：场景图只有回退透镜路径消费——真实 backdrop
      // 透镜路径不再捕获（省一张 ~10MB 全屏 ui.Image 常驻 + 一次
      // 全屏光栅化）。判定须在 preload 完成后做：_realLens 在
      // shader 就绪前恒为 false。
      _lastSceneSize = _size;
      unawaited(_captureScene());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyEnvironmentChange();
  }

  /// v1.6.6（A-4）：主题由父层换新时 MediaQuery 未必同时变化
  ///（didChangeDependencies 不触发，热切换会静默失效——旧主题的
  /// 贴纸/视频继续配新主题背景）。这里主动应用；_themeId 已更新时
  /// 幂等跳过，与 didChangeDependencies 路径不会重复执行。
  @override
  void didUpdateWidget(covariant LiquidGlassWelcome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme.id != widget.theme.id) {
      _applyEnvironmentChange();
    }
  }

  /// v1.6.6（A-3/A-4/A-7/B-3）：尺寸/主题/动效偏好变化统一入口。
  ///
  /// 主题热切换或旋转/分屏时不再整页重置——控制器走
  /// [LiquidGlassController.retune] 状态迁移（球位、模式、文案时序、
  /// 羽流物理保留，仅重算几何），背景由 AnimatedSwitcher 交叉淡化；
  /// 系统「移除动画」开关变化时同步切换弹簧参数。
  void _applyEnvironmentChange() {
    final mq = MediaQuery.of(context);
    final themeChanged = _themeId != null && _themeId != theme.id;
    final sizeChanged = _size != mq.size;
    final motionChanged =
        _reduceMotion != null && _reduceMotion != mq.disableAnimations;
    if (!themeChanged && !sizeChanged && !motionChanged) return;
    _size = mq.size;
    _themeId = theme.id;
    _sx = _size.width / 402;
    _sy = _size.height / 874;
    _reduceMotion = mq.disableAnimations;
    final old = _controller;
    if (old != null) {
      _controller = LiquidGlassController.retune(
        theme: theme,
        old: old,
        width: _size.width,
        height: _size.height,
        reduceMotion: mq.disableAnimations,
      );
    } else {
      _controller = LiquidGlassController(
        theme: theme,
        width: _size.width,
        height: _size.height,
        reduceMotion: mq.disableAnimations,
      );
    }
    _controller!.onSettled = _onOrbSettled;
    old?.dispose();
    if (themeChanged) {
      _applyThemeChange();
    } else if (theme.videoAsset == null && _shadersReady && !_realLens) {
      // v1.6.6（C-6）：旋转后旧场景图与新几何错位采样，重捕获；
      // v1.6.6（D-2）：真实 backdrop 路径不捕获（_prepare 已判
      // _realLens，这里只处理 shader 就绪后的尺寸变化）。
      if (_scene == null || _lastSceneSize != _size) {
        _lastSceneSize = _size;
        unawaited(_captureScene());
      }
    }
  }

  /// v1.6.6（A-4）：主题切换（昼夜）的资产重载段落（原
  /// didChangeDependencies 内联）。只被 _applyEnvironmentChange 在
  /// themeChanged（_themeId 已更新前判定）时调用，不会重复执行。
  void _applyThemeChange() {
    final oldPlayer = _player;
    // v1.6.5：先捕获旧场景图再置 null——_reloadThemeAssets 内部
    // 捕获的 _scene 此时已是 null，旧的全屏 ui.Image（约 10MB）
    // 此前会泄漏。
    final oldScene = _scene;
    _player = null;
    _videoController = null;
    _videoReady = false;
    _scene = null;
    // v1.6.6（A-3）：背景由 AnimatedSwitcher 交叉淡化（250ms），
    // 旧背景子树在过渡结束、卸载后才可释放播放器/场景图。
    if (oldPlayer != null || oldScene != null) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        oldPlayer?.dispose();
        oldScene?.dispose();
      });
    }
    unawaited(_reloadThemeAssets());
  }

  Future<void> _reloadThemeAssets() async {
    final oldStickers = _stickers;
    final oldGlow = _glowImage;
    final oldScene = _scene;
    _stickers = const [];
    _glowImage = null;
    await _loadStickers();
    await _loadGlowImage();
    if (theme.videoAsset != null) {
      await _initVideo();
    } else if (!_realLens) {
      // v1.6.6（D-2）：真实 backdrop 透镜路径不捕获场景图。
      _lastSceneSize = _size;
      await _captureScene();
    }
    if (mounted) {
      // 旧 ui.Image 在下一帧渲染（不再被画笔引用）后释放。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldScene?.dispose();
        oldGlow?.dispose();
        for (final img in oldStickers) {
          img?.dispose();
        }
      });
      setState(() {});
    } else {
      oldScene?.dispose();
      oldGlow?.dispose();
      for (final img in oldStickers) {
        img?.dispose();
      }
    }
  }

  Future<void> _loadStickers() async {
    final paths = theme.stickers;
    final images = <ui.Image?>[];
    for (final path in paths) {
      try {
        final data = await rootBundle.load(path);
        final buffer =
            await ui.ImmutableBuffer.fromUint8List(data.buffer.asUint8List());
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        images.add(frame.image);
      } catch (_) {
        images.add(null);
      }
    }
    if (mounted && identical(paths, theme.stickers)) {
      setState(() => _stickers = images);
    } else {
      // v1.6.6（D-3）：竞态丢弃的贴纸图显式释放——主题热切换或
      // 快速退出时，等引擎 finalizer 兑底会延迟回收峰值 ~40MB。
      for (final img in images) {
        img?.dispose();
      }
    }
  }

  /// Astro 地平光晕层：不透明调色板 PNG，必须以 plus 混合绘制
  ///（与原版 `SkImage blendMode=plus` 一致）——黑像素加 0，
  /// 星空透出，光带增亮。
  Future<void> _loadGlowImage() async {
    final asset = theme.glowAsset;
    if (asset == null) return;
    try {
      final data = await rootBundle.load(asset);
      final buffer =
          await ui.ImmutableBuffer.fromUint8List(data.buffer.asUint8List());
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      if (mounted && identical(asset, theme.glowAsset)) {
        setState(() => _glowImage = frame.image);
      } else {
        // v1.6.6（D-3）：竞态丢弃的光晕图显式释放。
        frame.image.dispose();
      }
    } catch (_) {
      // 光晕缺失：仅损失增亮层。
    }
  }

  /// Sky：把 asset 视频拷到应用目录后以文件播放
  /// （与原项目同理：asset 通道对播放器的 byte-range 不可靠）。
  Future<void> _initVideo() async {
    try {
      final player = Player();
      final videoController = VideoController(player);
      _player = player;
      _videoController = videoController;

      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/liquid_glass_sky.mp4');
      // v1.6.6（D-1）：以字节长度校验新鲜度——「存在即跳过」会让
      // 资产更新（换云海素材/压缩体积）对存量安装永不生效，新素材
      // 只在全新安装上出现。长度不同即重写（同长异内容的碰撞
      // 概率可忽略；素材迭代必然变长/变短）。
      final data = await rootBundle.load(theme.videoAsset!);
      final stale =
          !await file.exists() || await file.length() != data.lengthInBytes;
      if (stale) {
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }

      await player.open(Media(file.path));
      unawaited(player.setPlaylistMode(PlaylistMode.loop));
      unawaited(player.setVolume(0));

      // Video widget fill 透明：首帧未到时海报从其下透出。
      if (mounted) {
        setState(() => _videoReady = true);
      }
    } catch (_) {
      // 视频失败：海报帧兜底。
    }
  }

  /// Astro：捕获静态星空为透镜场景贴图（仅回退路径使用）。
  Future<void> _captureScene() async {
    if (_size == Size.zero || !mounted) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final asset = theme.refractionAsset;
    final scene = await LiquidGlassShaders.captureCoverScene(
      asset: asset,
      widthLogical: _size.width,
      heightLogical: _size.height,
      dpr: dpr,
    );
    if (!mounted || !identical(asset, theme.refractionAsset)) {
      // v1.6.6（D-3）：捕获结果被竞态丢弃时显式释放。
      scene?.dispose();
      return;
    }
    // v1.6.6（C-6）：重捕获时替换下的旧场景图在下一帧后释放。
    final oldScene = _scene;
    setState(() => _scene = scene);
    if (oldScene != null && !identical(oldScene, scene)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => oldScene.dispose());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _controller?.dispose();
    _player?.dispose();
    _scene?.dispose();
    _glowImage?.dispose();
    for (final img in _stickers) {
      img?.dispose();
    }
    super.dispose();
  }

  // ── 手势转发 ──────────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    _panTotal = Offset.zero;
    // v1.6.6（B-5）：手势开始时重置采样基准——两次手势间隔长时，
    // 首个 update 的 dtMs 巨大会把首帧手指速度低估为 ≈0。
    _lastPanTime = DateTime.now();
    _lastPanVelocity = Offset.zero;
    controller.onPanBegin(d.globalPosition.dx, d.globalPosition.dy);
    controller.onPanStart();
  }

  Offset _panTotal = Offset.zero;
  DateTime _lastPanTime = DateTime.now();
  Offset _lastPanVelocity = Offset.zero;

  void _onPanUpdate(DragUpdateDetails d) {
    _panTotal += d.delta;
    final now = DateTime.now();
    final dtMs = now.difference(_lastPanTime).inMilliseconds;
    if (dtMs > 4) {
      _lastPanVelocity = Offset(
        d.delta.dx / (dtMs / 1000),
        d.delta.dy / (dtMs / 1000),
      );
      _lastPanTime = now;
    }
    controller.onPanUpdate(
      x: d.globalPosition.dx,
      y: d.globalPosition.dy,
      translationX: _panTotal.dx,
      translationY: _panTotal.dy,
      velocityX: _lastPanVelocity.dx,
      velocityY: _lastPanVelocity.dy,
    );
  }

  void _onPanEnd(DragEndDetails d) {
    controller.onPanEnd(
      d.velocity.pixelsPerSecond.dx,
      d.velocity.pixelsPerSecond.dy,
    );
    controller.onPanFinalize();
  }

  void _onPanCancel() {
    controller.onPanCancel();
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // didChangeDependencies 已保证 controller 就绪。
    if (_controller == null) {
      return _splashFadeScaffold(const SizedBox.expand());
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          theme.night ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: _splashFadeScaffold(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 与原版 Canvas 层序一致：背景 → 贴纸 → 透镜 → 玻璃。
                //（回退路径下透镜输出不透明，需画在贴纸之下，
                // 否则按钮内出生的贴纸会被透镜整层遮住。）
                _buildBackdrop(),
                if (!_realLens) _buildLens(),
                _buildStickers(),
                if (_realLens) _buildLens(),
                _buildGlass(),
                _buildPlus(),
                _buildGateCopy(),
                _buildOpenCopy(),
                _buildPill(),
                _buildGithubEntry(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// v1.6.6（B-1）：球体着陆一拍——整个开屏最有「重量感」的时刻，
  /// 轻震一下（对齐上游原版的 expo-haptics 着陆震动）。
  void _onOrbSettled() {
    HapticFeedback.lightImpact();
  }

  /// v1.6.6（A-1）：原生启动层只认系统深色（values-night 一重判定），
  /// 与欢迎页的三重判定（应用内/系统/深夜窗口）不一致时（深夜窗口的
  /// 系统浅色用户、应用内深色的系统浅色用户），首帧从「原生同色」
  /// 起帧、300ms 渐变到目标底色——消灭冷启动「亮蓝 → 深黑」硬闪；
  /// 一致时直接落位。原生 splash → 加载页 → 玻璃页全程连成一体。
  Widget _splashFadeScaffold(Widget body) {
    final nativeColor =
        (MediaQuery.platformBrightnessOf(context) == Brightness.dark
                ? astroLiquidGlassTheme
                : skyLiquidGlassTheme)
            .pageColor;
    final target = theme.pageColor;
    if (nativeColor == target) {
      return Scaffold(backgroundColor: target, body: body);
    }
    // 用 double 驱动 + Color.lerp：新版 Flutter 的 Color 不支持
    // Tween 的 + - * 运算（TweenAnimationBuilder<Color> 会抛
    // "Cannot lerp between Color"），ColorTween 则不兼容
    // TweenAnimationBuilder 的类型参数——t 驱动 lerp 是最稳写法。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      builder: (_, t, __) => Scaffold(
        backgroundColor: Color.lerp(nativeColor, target, t),
        body: body,
      ),
    );
  }

  // ── 背景层 ────────────────────────────────────────────────────────────────

  Widget _buildBackdrop() {
    // v1.6.6（A-3）：昼夜切换时背景交叉淡化（250ms）——云海/星空
    // 互化不再瞬变；controller 状态已迁移，贴纸与玻璃球本身连续。
    // 旧背景子树在过渡期间仍在树上：旧播放器/场景图由
    // _applyThemeChange 延迟到过渡结束后释放。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: KeyedSubtree(
        key: ValueKey<String>(theme.id),
        child: _buildBackdropLayer(),
      ),
    );
  }

  Widget _buildBackdropLayer() {
    if (theme.videoAsset != null) {
      // Sky：视频（cover）+ 未就绪时的海报帧。
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            theme.refractionAsset,
            fit: BoxFit.cover,
          ),
          if (_videoReady && _videoController != null)
            Video(
              controller: _videoController!,
              fit: BoxFit.cover,
              fill: const Color(0x00000000),
              controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
            ),
        ],
      );
    }
    // Astro：星星层 + 地平光晕（随球上升散去；物质量再点亮）。
    // 光晕是不透明调色板 PNG：必须 plus 混合（黑像素加 0 → 星空透出），
    // 与原版 <SkImage blendMode="plus" opacity={...}> 一致。
    final glow = _glowImage;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(theme.refractionAsset, fit: BoxFit.cover),
        if (glow != null)
          AnimatedBuilder(
            animation: controller,
            builder: (_, __) => CustomPaint(
              painter: _PlusBlendImagePainter(
                image: glow,
                opacity: controller.glowAlpha,
              ),
            ),
          ),
        if (glow != null)
          AnimatedBuilder(
            animation: controller,
            builder: (_, __) => CustomPaint(
              painter: _PlusBlendImagePainter(
                image: glow,
                opacity: controller.feedAlpha,
              ),
            ),
          ),
      ],
    );
  }

  // ── 贴纸层（透镜之下，被玻璃真实折射） ────────────────────────────────────

  bool get _realLens => LiquidGlassShaders.isBackdropLensSupported;

  Widget _buildStickers() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => CustomPaint(
        painter: StickerFieldPainter(
          controller: controller,
          theme: theme,
          images: _stickers,
          approxLens: !_realLens,
        ),
      ),
    );
  }

  // ── 透镜层 ────────────────────────────────────────────────────────────────

  /// 真实 backdrop 透镜（Impeller）：BackdropFilter(ImageFilter.shader)
  /// 覆盖全屏 + ClipOval 圆形裁剪。shader 的 sceneRes/c 均为屏幕物理
  /// 像素坐标，与原版 BackdropFilter 语义一致。
  Widget _buildLens() {
    if (!_realLens) {
      return theme.videoAsset != null
          ? _buildSkyLensFallback()
          : _buildAstroLensFallback();
    }
    final shader = LiquidGlassShaders.lensBackdrop();
    if (shader == null) {
      return theme.videoAsset != null
          ? _buildSkyLensFallback()
          : _buildAstroLensFallback();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final R = controller.radius;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // 退化守卫：半径过小（异常几何）时不做 backdrop 快照。
        if (R < 4) {
          return const SizedBox.shrink();
        }
        // float 槽位：0/1 = sceneRes（引擎写入，不设置）；
        // 2/3 = c；4 = r；5 = amount；6 = bezel；7 = disp；8/9 = slosh。
        shader.setFloat(2, controller.orbX * dpr);
        shader.setFloat(3, controller.cy * dpr);
        shader.setFloat(4, R * dpr);
        shader.setFloat(
            5, _lerpClamped(R, controller.r1, controller.r0, 0.62, 0.42));
        shader.setFloat(
            6, _lerpClamped(R, controller.r1, controller.r0, 0.42, 0.25));
        shader.setFloat(
            7,
            _lerpClamped(R, controller.r1, controller.r0 * theme.domeAt,
                theme.buttonDispersion, theme.domeDispersion));
        shader.setFloat(8, controller.sloshX * R * 0.10 * dpr);
        shader.setFloat(9, controller.sloshY * R * 0.10 * dpr);

        return Positioned.fill(
          child: IgnorePointer(
            child: ClipOval(
              clipper: _OrbClipper(
                Offset(controller.orbX, controller.cy),
                R,
              ),
              child: BackdropFilter(
                filter: ui.ImageFilter.shader(shader),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Sky 的回退透镜：视频无法采样进 shader，用 clip + 放大近似
  /// （中心放大、随半径变化、slosh 拖影；穹顶态色散 0.05 不可见，省略）。
  Widget _buildSkyLensFallback() {
    final video = _videoController;
    if (video == null || !_videoReady) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final R = controller.radius;
        if (R < 4) return const SizedBox.shrink();
        final amount =
            _lerpClamped(R, controller.r1, controller.r0, 0.62, 0.42);
        final scale = 1 / (1 - amount * 0.55);
        final cx = controller.orbX;
        final cy = controller.cy;
        final alignment = Alignment(
          (cx / _size.width) * 2 - 1,
          (cy / _size.height) * 2 - 1,
        );
        final slosh = Offset(
          controller.sloshX * R * 0.08,
          controller.sloshY * R * 0.08,
        );
        return Positioned.fill(
          child: IgnorePointer(
            child: ClipOval(
              clipper: _OrbClipper(Offset(cx, cy), R),
              child: Transform.translate(
                offset: slosh,
                child: Transform.scale(
                  scale: scale,
                  alignment: alignment,
                  child: Video(
                    controller: video,
                    fit: BoxFit.cover,
                    fill: const Color(0x00000000),
                    controls: NoVideoControls,
                    pauseUponEnteringBackgroundMode: false,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Astro 的回退透镜：静态星空已捕获为贴图，shader 做真实折射。
  Widget _buildAstroLensFallback() {
    if (_scene == null || !_shadersReady) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => CustomPaint(
        painter: LensPainter(
          controller: controller,
          theme: theme,
          scene: _scene,
          dpr: MediaQuery.devicePixelRatioOf(context),
        ),
      ),
    );
  }

  // ── 玻璃层 ────────────────────────────────────────────────────────────────

  Widget _buildGlass() {
    // v1.6.6（C-1）：shader 未就绪且未失败时不画半成品——
    // 渐变近似球与真实 shader 球的「变脸」质感突变不可取；球晚
    // ~200ms 以完整质感登场，符合「穹顶从底缘浮现」的叙事。
    // preload 彻底失败（_shaderLoadFailed）时保留降级球，
    // 画笔内部的 glass()==null 分支会画多层渐变近似。
    final shaderReady = _shadersReady || LiquidGlassShaders.glass() != null;
    if (!shaderReady && !_shaderLoadFailed) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => CustomPaint(
        painter: GlassSpherePainter(
          controller: controller,
          theme: theme,
          dpr: MediaQuery.devicePixelRatioOf(context),
        ),
      ),
    );
  }

  // ── 前景元素 ──────────────────────────────────────────────────────────────

  Widget _buildPlus() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final R = controller.radius;
        final opacity =
            _lerpClamped(R, controller.r1 * 1.2, controller.r1 * 1.7, 1, 0);
        if (opacity <= 0) return const SizedBox.shrink();
        // v1.6.6（C-2）：区域与字号随 r1（按钮态球体就是锚）缩放，
        // 不再固定 60px/38px——小屏与平板上「+」与按钮比例一致。
        final d = controller.r1 * 1.5;
        return Positioned(
          left: controller.orbX - d / 2,
          top: controller.cy - d * 0.55,
          width: d,
          height: d,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Center(
                child: Text(
                  '+',
                  style: TextStyle(
                    fontSize: 38 * (controller.r1 / 44) * _cs,
                    fontWeight: FontWeight.w400,
                    color: theme.plus,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGateCopy() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final w = _size.width;
        final h = _size.height;
        final s = _cs;
        final wordmarkSize = 230 * s;
        return Stack(
          children: [
            // wordmark：chrome 气球字标位图（原版同款视觉）。
            Positioned(
              top: h * 0.4368 - 115 * s,
              left: (w - wordmarkSize) / 2,
              width: wordmarkSize,
              height: wordmarkSize,
              child: SoftCopyBlock(
                fade: controller.gateFade,
                soften: controller.gateSoft,
                darkTint: theme.night,
                child: Image.asset(
                  theme.wordmarkAsset,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
            // 上滑提示。
            // v1.6.6（C-3）：底部锚定 + 手势条避让（edge-to-edge 下
            // MediaQuery.padding.bottom 不在原 top 分数考量里）。
            Positioned(
              bottom: math.max(
                h - h * 0.8853 - 22 * s,
                MediaQuery.paddingOf(context).bottom + 6,
              ),
              height: 22 * s,
              left: 0,
              right: 0,
              child: SoftCopyBlock(
                fade: controller.hintFade,
                soften: controller.hintSoft,
                darkTint: theme.night,
                shift: Offset(
                  controller.sloshX * controller.radius * 0.04,
                  controller.sloshY * controller.radius * 0.04,
                ),
                child: Center(
                  child: Text(
                    theme.copy.hint,
                    style: TextStyle(
                      color: theme.hint,
                      fontSize: 15 * s,
                      height: 20 * s / (15 * s),
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1 * s,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildOpenCopy() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final s = _cs;
        final fontSize = 32 * s;
        final lineHeight = 38 * s;
        final bodyStyle = TextStyle(
          color: theme.ink,
          fontSize: fontSize,
          height: lineHeight / fontSize,
          letterSpacing: -0.7 * s,
          fontWeight: FontWeight.w500,
        );
        // v1.6.3：第三行改为相对堆叠（标题块底部 + 呼吸间距）。
        // 原版在 402×874 基准时 0.6163h+76sx 恰好贴着 0.7032h，
        // 换任何纵横比都会叠行；堆叠后任何屏都不可能重叠。
        // （块高加 4px 余量：文本行高在物理像素上会取整，
        // 严格 2×行高会触发亚像素 RenderFlex 溢出断言。）
        final headlineTop = h * 0.6163;
        final thirdTop = headlineTop + 2 * lineHeight + 6;
        return Stack(
          children: [
            // 主标题 + 划线。
            Positioned(
              top: headlineTop,
              height: 2 * lineHeight + 4,
              left: 0,
              right: 0,
              child: SoftCopyBlock(
                fade: controller.bodyFade,
                soften: controller.bodySoft,
                darkTint: theme.night,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(theme.copy.headline, style: bodyStyle),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StruckWord(
                          text: theme.copy.struck,
                          style: bodyStyle,
                          strikeColor: theme.ink,
                        ),
                        Text(' ${theme.copy.kept}', style: bodyStyle),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 旋转第三行。
            Positioned(
              top: thirdTop,
              height: lineHeight,
              left: 0,
              right: 0,
              child: Center(
                child: WipeLineText(
                  text: theme.copy.phrases[controller.phraseIndex],
                  wipe: controller.wipe,
                  fade: controller.thirdFade,
                  soften: controller.thirdSoft,
                  darkTint: theme.night,
                  style: bodyStyle,
                  height: lineHeight,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPill() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final s = _cs;
        final shown = controller.shown;
        final live = controller.pillLive;
        // v1.6.6（C-3）：底部锚定 + 手势条避让：原 top 分数未把
        // edge-to-edge 的 padding.bottom（手势导航典型 24~48px）
        // 纳入考量，inset 机型上 CTA 下缘落进系统上滑手势热区。
        // inset 为 0 时与原布局逐像素一致。
        final pillBottom = math.max(
          h - h * 0.8848 - 58.7 * _sy,
          MediaQuery.paddingOf(context).bottom + 6,
        );
        // v1.6.6（C-4）：宽屏/横屏钳制最大宽——基准 402 宽下胶囊占
        // 75% 屏宽是刻意比例，1280×800 上拉通全屏变成「轨道」。
        // 竖屏常规尺寸下与原布局一致。
        final pillW = math.min(_size.width - 100 * s, 340 * s + 120);
        return Positioned(
          bottom: pillBottom,
          left: (_size.width - pillW) / 2,
          width: pillW,
          height: 58.7 * _sy,
          child: IgnorePointer(
            ignoring: !live,
            child: Opacity(
              opacity: shown,
              child: Transform.translate(
                offset: Offset(0, (1 - shown) * 10 * _sy),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Color.lerp(theme.pillFrom, theme.pillTo, shown),
                  ),
                  child: Material(
                    color: const Color(0x00000000),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () {
                        // v1.6.6（B-1）：CTA 点击触觉反馈。
                        HapticFeedback.selectionClick();
                        widget.onEnter();
                      },
                      child: Center(
                        child: Text(
                          theme.copy.cta,
                          style: TextStyle(
                            color: theme.pillText,
                            // v1.6.6（C-2）：随 _cs 缩放，与文案体系一致。
                            fontSize: 17 * s,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2 * s,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 次入口：通过 GitHub 进入（打开仓库页并同样完成进入）。
  Widget _buildGithubEntry() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final s = _cs;
        final shown = controller.shown;
        final live = controller.pillLive;
        // v1.6.6（C-3）：随 pill 同步底部锚定（保持相对 pill 的位置：
        // 底缘贴胶囊顶缘上方 8px）。inset 为 0 时与原布局一致。
        final pillBottom = math.max(
          h - h * 0.8848 - 58.7 * _sy,
          MediaQuery.paddingOf(context).bottom + 6,
        );
        return Positioned(
          bottom: pillBottom + 58.7 * _sy + 8,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !live,
            child: Opacity(
              opacity: shown * 0.85,
              child: Center(
                child: InkWell(
                  onTap: () {
                    // v1.6.6（B-1）：次入口点击触觉反馈。
                    HapticFeedback.selectionClick();
                    widget.onEnterViaGithub();
                  },
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 16 * s,
                      vertical: 6 * s,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 14 * s,
                          color: theme.hint,
                        ),
                        SizedBox(width: 4 * s),
                        Text(
                          '通过 GitHub 进入',
                          style: TextStyle(
                            color: theme.hint,
                            fontSize: 13 * s,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 划线词：文字 + 一条横穿的中划线。
class _StruckWord extends StatelessWidget {
  const _StruckWord({
    required this.text,
    required this.style,
    required this.strikeColor,
  });

  final String text;
  final TextStyle style;
  final Color strikeColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 32;
    final lineHeight = (style.height ?? 1.2) * fontSize;
    return SizedBox(
      height: lineHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(text, style: style),
          Positioned(
            left: 0,
            right: 0,
            // 原版公式（screen.tsx）：
            // lineHeight*0.5 + fontSize*(0.36 - 0.234 - 0.052)。
            top: lineHeight * 0.5 + fontSize * 0.074,
            child: Container(
              height: fontSize * 0.104,
              color: strikeColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbClipper extends CustomClipper<Rect> {
  _OrbClipper(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  Rect getClip(Size size) {
    return Rect.fromCircle(center: center, radius: radius);
  }

  @override
  bool shouldReclip(covariant _OrbClipper oldClipper) =>
      oldClipper.center != center || oldClipper.radius != radius;
}

/// 以 plus 混合绘制一张全屏 cover 图（Astro 光晕层）：
/// 不透明黑底 PNG 只有加色才不遮星空。
class _PlusBlendImagePainter extends CustomPainter {
  _PlusBlendImagePainter({required this.image, required this.opacity});

  final ui.Image image;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001) return;
    // cover：居中裁剪。
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    final scale = math.max(size.width / srcW, size.height / srcH);
    final visibleW = size.width / scale;
    final visibleH = size.height / scale;
    final src = ui.Rect.fromLTRB(
      (srcW - visibleW) / 2,
      (srcH - visibleH) / 2,
      (srcW + visibleW) / 2,
      (srcH + visibleH) / 2,
    );
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..filterQuality = ui.FilterQuality.medium
      ..color = ui.Color.fromRGBO(255, 255, 255, opacity);
    canvas.drawImageRect(
      image,
      src,
      ui.Offset.zero & size,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PlusBlendImagePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.image != image;
}

double _lerpClamped(double x, double x0, double x1, double y0, double y1) {
  if (x1 == x0) return y0;
  final t = ((x - x0) / (x1 - x0)).clamp(0.0, 1.0);
  return y0 + (y1 - y0) * t;
}
