import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'liquid_glass_theme.dart';

/// 液态玻璃欢迎屏控制器 —— 状态机 + 物理引擎。
///
/// 逐行移植自 Appllama/liquid-glass-screens：
/// * `src/liquid-glass/liquid-glass-screen.tsx` —— 球体行程 p、侧向软皮带、
///   弹簧着陆判定、焦散（力→光）、文案时序（第三行循环）、shown 进出。
/// * `src/liquid-glass/orb-field.tsx` —— 40 贴纸槽羽流物理（浮力/游走/归位
///   弹簧/邻避/指避/风）、坠落（Sky）与星尘漩涡（Astro）两种离场、
///   260 尘粒星尘。
///
/// 坐标系：逻辑像素，原项目以 402×874 为基准（sx = width/402，
/// sy = height/874）缩放。所有魔法数字与原版一致。
///
/// 本类不依赖 Flutter widget 树，由外部 Ticker 调 [tick]，便于单测。
class LiquidGlassController extends ChangeNotifier {
  LiquidGlassController({
    required LiquidGlassTheme theme,
    required this.width,
    required this.height,
    bool reduceMotion = false,
  })  : _theme = theme,
        _reduceMotion = reduceMotion {
    _sx = width / 402;
    _sy = height / 874;
    r0 = 245 * _sx;
    cy0 = height;
    r1 = 44 * _sx;
    cy1 = 0.469 * height;
    rf = 32 * _sx;
    cx = width / 2;
    travel = cy0 - cy1;
    _state = Float64List(stickerSlots * _k);
    _dust = Float64List(_dustMotes * _dustK);
    _makeState();
  }

  static const int stickerSlots = 40;
  static const int _k = 19;
  static const int _dustMotes = 260;
  static const int _dustK = 6;
  static const int _emitDelayMs = 350;

  /// 贴纸槽尺寸（pt，与原版 STICKER_SIZES 完全一致）。
  static const List<double> stickerSizes = [
    104, 82, 76, 93, 87, //
    68, 46, 58, 52, 55, //
    98, 49, 43, 54, 36, //
    91, 47, 41, 35, 62, //
    85, 32, 50, 30, //
    39, 27, 44, 24, //
    71, 40, 33, 64, //
    29, 57, 45, 26, //
    79, 31, 22, 37, //
  ];

  static const double _sinkRadius = 20;
  static const int _holdMs = 1950;
  static const int _outMs = 400;
  static const int _gapMs = 460;
  static const int _inMs = 560;

  final LiquidGlassTheme _theme;
  final bool _reduceMotion;
  final double width;
  final double height;

  // 几何（构造时按 sx/sy 换算）。
  late final double _sx, _sy;
  late final double r0; // gate 穹顶半径
  late final double cy0; // gate 中心 y（底缘）
  late final double r1; // + 按钮半径
  late final double cy1; // 按钮中心 y
  late final double rf; // 过冲下限半径
  late final double cx; // 屏幕中心 x
  late final double travel;

  // 球体主状态。
  double p = 0; // 0 = gate, 1 = open（>1：扔过头）
  double _pv = 0; // p 的速度（travel/s）
  double cxOff = 0;
  double _cxv = 0;
  bool _springActive = false;
  double _springTarget = 0;

  bool touchOn = false;
  double touchX = 0;
  double touchY = 0;
  double fvx = 0; // 手指速度
  double fvy = 0;
  double windX = 0;
  double windY = 0;

  int mode = 0; // 0 idle, 1 emit, 2 leave
  int settled = 0;
  double feed = 0; // 掉入核心的物质量（Astro 光晕 flare）

  // 运动光效。
  double glow = 0;
  double dirX = 0;
  double dirY = -1;
  double sloshX = 0;
  double sloshY = 0;

  // 文案。
  double shown = 0;
  int phraseIndex = 0;
  double wipe = 1;
  double thirdFade = 0;
  double thirdSoft = 0;
  double gateFade = 1;
  double gateSoft = 0;
  double bodyFade = 0;
  double bodySoft = 14;

  // 内部时序。
  double _warm = 0;
  double _prevCy = 0;
  double _prevCx = 0;
  double _prevV = 0;
  double _clock = 0;
  double _emitT = -1;
  double _leaveT = 0;
  int _lastMode = 0;
  int _leaving = 0;

  // shown / 第三行的显式 tween。
  double _shownFrom = 0;
  double _shownTo = 0;
  double _shownStart = -1;
  double _shownDur = 0;
  bool _shownEaseOut = false; // true: bezier(0.23,1,0.32,1); false: outQuad

  double _wipeStart = -1;
  double _thirdStart = -1;
  _ThirdPhase _thirdPhase = _ThirdPhase.idle;
  bool _live = false;

  // 物理状态数组（1:1 的槽位布局）。
  late final Float64List _state;
  late final Float64List _dust;
  int _dustHead = 0;

  final math.Random _rand = math.Random();

  // ── 派生量 ────────────────────────────────────────────────────────────────

  double get cy => cy0 + (cy1 - cy0) * p;

  double get radius {
    if (p <= 1) return r0 + (r1 - r0) * p;
    final up = (p - 1) * travel;
    return rf + (r1 - rf) * math.exp(-up / (40 * _sy));
  }

  double get orbX => cx + cxOff;

  /// Astro 地平光晕层透明度：gate 时全亮，球升到 0.70 前完全散去。
  double get glowAlpha => _clamp01(_lerpRange(p, 0.04, 0.70, 1, 0));

  double get feedAlpha => math.min(0.85, feed * 0.85);

  double get hintFade => _clamp01(_lerpRange(p, 0.06, 0.30, 1, 0));

  double get hintSoft => _clamp01(_lerpRange(p, 0.04, 0.28, 0, 12));

  double get plusOpacity => _clamp01(
      _lerpRange(radius, r1 * 1.2, r1 * 1.7, 1, 0));

  bool get pillLive => shown > 0.9;

  bool get isVortex => _theme.isVortex;

  /// 画笔用的横向缩放系数（402pt 基准）。
  double get sx => _sx;

  Float64List get state => _state;
  Float64List get dust => _dust;
  math.Random get random => _rand;

  // ── 手势（由 widget 转发） ────────────────────────────────────────────────

  void onPanBegin(double x, double y) {
    touchOn = true;
    touchX = x;
    touchY = y;
  }

  void onPanStart() {
    _springActive = false;
    _panP0 = p;
    _panCx0 = cxOff;
  }

  double _panP0 = 0;
  double _panCx0 = 0;

  void onPanUpdate({
    required double x,
    required double y,
    required double translationX,
    required double translationY,
    required double velocityX,
    required double velocityY,
  }) {
    touchX = x;
    touchY = y;
    fvx = velocityX;
    fvy = velocityY;
    windX = velocityX / 60;
    windY = velocityY / 60;
    var raw = _panP0 - translationY / travel;
    p = raw < 0
        ? raw * 0.25
        : raw > 1
            ? 1 + (raw - 1) * 0.25
            : raw;
    _pv = 0;
    // 侧向软皮带。
    final lim = 150 * _sx;
    cxOff = lim * _tanh((_panCx0 + translationX) / lim);
  }

  void onPanEnd(double velocityX, double velocityY) {
    final vy = -velocityY / travel;
    _springTarget = (p + vy * 0.18) > 0.5 ? 1 : 0;
    _pv = vy;
    _cxv = velocityX;
    _springActive = true;
  }

  void onPanFinalize() {
    touchOn = false;
  }

  // ── 帧循环 ────────────────────────────────────────────────────────────────

  /// 外部 Ticker 每帧调用。`dt` 秒。
  void tick(Duration elapsed) {
    final dt = _lastElapsed == null
        ? 1 / 60
        : math.min(0.05, (elapsed - _lastElapsed!).inMicroseconds / 1e6);
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    _clock += dt;
    _step(dt);
    notifyListeners();
  }

  Duration? _lastElapsed;

  void _step(double dt) {
    // 前几帧屏幕几何还在安定，避免读作推挤。
    if (_warm < 4) {
      _warm += 1;
      _prevCy = cy;
      _prevCx = cxOff;
      return;
    }

    // ── 弹簧（着陆/回座） ──
    if (_springActive) {
      final k = _reduceMotion ? 160.0 : 120.0;
      final c = _reduceMotion ? 30.0 : 15.0;
      final m = _reduceMotion ? 1.0 : 1.05;
      final a = (k * (_springTarget - p) - c * _pv) / m;
      _pv += a * dt;
      p += _pv * dt;
      final ac = (0 * 0 - cxOff * 260 - c * _cxv) / 1.05;
      _cxv += ac * dt;
      cxOff += _cxv * dt;
      if ((p - _springTarget).abs() < 5e-4 && _pv.abs() < 0.02 &&
          cxOff.abs() < 0.5 && _cxv.abs() < 20) {
        p = _springTarget;
        cxOff = 0;
        _pv = 0;
        _cxv = 0;
        _springActive = false;
      }
    }

    final orbVy = (cy - _prevCy) / dt;
    final orbVx = (cxOff - _prevCx) / dt;
    _prevCy = cy;
    _prevCx = cxOff;
    final orbA = (orbVy - _prevV) / dt;
    _prevV = orbVy;

    // ── 着陆由位置决定（而非弹簧回调），且等手指抬起 ──
    final cur = p;
    if (cur > 0.97 && settled == 0 && !touchOn) {
      settled = 1;
      if (mode != 1) mode = 1;
      _startShown(1, 0.52, true);
    } else if (cur < 0.80 && settled == 1) {
      settled = 0;
      _startShown(0, 0.24, false);
    }
    if (cur < _theme.releaseAt && mode == 1) mode = 2;
    if (cur <= 0.02 && mode == 2) mode = 0;

    // ── 焦散：光回应力，不是速度 ──
    final mx = fvx + (touchOn ? 0 : orbVx);
    final my = orbVy + fvy * 0.7;
    final sp = math.sqrt(mx * mx + my * my);
    var target = 0.0;
    if (touchOn) {
      target = math.min(1.0, sp / 430);
      if (sp > 45) {
        // 光聚在玻璃顶端；侧向推只倾斜（~25°），直拉向下才落底。
        final tx = (mx / sp) * 0.42;
        final ty = (my / sp > 0.55 ? 1 : -1) * math.sqrt(1 - tx * tx);
        dirX += (tx - dirX) * _perFrame(0.16, dt);
        dirY += (ty - dirY) * _perFrame(0.16, dt);
      }
    } else {
      final slowing = orbVy * orbA < 0 ? orbA.abs() : 0.0;
      target = math.min(1.0, slowing / 12000);
      if (target > 0.05) {
        dirX += (0 - dirX) * _perFrame(0.2, dt);
        dirY += (-1 - dirY) * _perFrame(0.2, dt);
      }
    }
    glow += (target - glow) * _perFrame(target > glow ? 0.22 : 0.12, dt);

    // 液体滞后玻璃一拍。
    sloshX += (_clamp(mx / 430, -1, 1) - sloshX) * _perFrame(0.12, dt);
    sloshY += (_clamp(my / 430, -1, 1) - sloshY) * _perFrame(0.12, dt);

    final decay = math.pow(0.02, dt).toDouble();
    fvx *= decay;
    fvy *= decay;
    final windDecay = math.pow(0.85, dt * 60).toDouble();
    windX *= windDecay;
    windY *= windDecay;

    // ── 文案驱动 ──
    _advanceShown();
    _advanceThirdLine();
    gateFade = _clamp01(_lerpRange(p, 0.08, 0.62, 1, 0));
    gateSoft = _clamp01(_lerpRange(p, 0.05, 0.60, 0, 13));

    // ── 贴纸羽流 ──
    _stepOrbField(dt);
  }

  // ── shown / 第三行动画 ────────────────────────────────────────────────────

  void _startShown(double to, double seconds, bool easeInBezier) {
    _shownFrom = shown;
    _shownTo = to;
    _shownStart = _clock;
    _shownDur = seconds;
    _shownEaseOut = !easeInBezier; // true → outQuad；false → cubic bezier
  }

  void _advanceShown() {
    if (_shownStart < 0) return;
    final t = (( _clock - _shownStart) / _shownDur).clamp(0.0, 1.0);
    final eased = _shownEaseOut
        ? 1 - (1 - t) * (1 - t) // easeOutQuad
        : _bezier(t, 0.23, 1, 0.32, 1);
    shown = _shownFrom + (_shownTo - _shownFrom) * eased;
    bodyFade = shown;
    bodySoft = (1 - shown) * 14;
    final liveNow = shown > 0.5;
    if (liveNow != _live) {
      _live = liveNow;
      if (liveNow) {
        _thirdPhase = _ThirdPhase.reveal;
        _thirdStart = _clock;
        _wipeStart = _clock;
        thirdSoft = 0;
        thirdFade = 1;
      } else {
        _thirdPhase = _ThirdPhase.idle;
        thirdFade = 0;
      }
    }
    if (t >= 1) _shownStart = -1;
  }

  void _advanceThirdLine() {
    if (!_live || _thirdPhase == _ThirdPhase.idle) return;
    switch (_thirdPhase) {
      case _ThirdPhase.reveal:
        if (_reduceMotion) {
          wipe = 1;
        } else {
          final t = ((_clock - _wipeStart) / (_inMs / 1000)).clamp(0.0, 1.0);
          wipe = _bezier(t, 0.16, 0.42, 0.40, 1);
        }
        if (_clock - _thirdStart >= (_holdMs + _inMs) / 1000) {
          _thirdPhase = _ThirdPhase.out;
          _thirdStart = _clock;
        }
        break;
      case _ThirdPhase.out:
        final t = ((_clock - _thirdStart) / (_outMs / 1000)).clamp(0.0, 1.0);
        thirdSoft = 19 * (1 - (1 - t) * (1 - t)); // out → 19，easeOutQuad
        thirdFade = 1 - t * t; // inQuad 淡出
        if (t >= 1) {
          _thirdPhase = _ThirdPhase.gap;
          _thirdStart = _clock;
        }
        break;
      case _ThirdPhase.gap:
        if (_clock - _thirdStart >= _gapMs / 1000) {
          phraseIndex = (phraseIndex + 1) % _theme.copy.phrases.length;
          _thirdPhase = _ThirdPhase.reveal;
          _thirdStart = _clock;
          _wipeStart = _clock;
          thirdSoft = 0;
          thirdFade = 1;
        }
        break;
      case _ThirdPhase.idle:
        break;
    }
  }

  // ── 贴纸羽流物理（orb-field.tsx 1:1） ─────────────────────────────────────

  void _makeState() {
    for (var i = 0; i < stickerSlots; i++) {
      _state[i * _k + 6] = _rand.nextDouble() * math.pi * 2;
      _state[i * _k + 9] = (_rand.nextDouble() * 2 - 1) * 0.5;
    }
    _seedHomes(_state);
  }

  /// 归位点：按钮上方升起的羽流，底部收窄向上展开，散点更宽更高。
  void _seedHomes(Float64List a) {
    for (var i = 0; i < stickerSlots; i++) {
      final b = i * _k;
      final big = stickerSizes[i] / 104;
      final t = _rand.nextDouble();
      final spread = 34 + t * 178;
      final stray = i % 7 == 3;
      a[b + 7] = (_rand.nextDouble() * 2 - 1) *
          spread *
          (stray ? 1.8 : 1 - 0.3 * big);
      a[b + 8] = -40 - t * 545 - (stray ? 90 : 0);
      // 少数小贴纸守在按钮附近，玻璃里总有东西可折射。
      if (i % 6 == 4 && stickerSizes[i] < 82) {
        a[b + 7] = (_rand.nextDouble() * 2 - 1) * 40;
        a[b + 8] = -14 + (_rand.nextDouble() * 2 - 1) * 30;
      }
    }
  }

  void _stepOrbField(double dt) {
    final s = _state;
    final d = _dust;
    final m = mode;
    if (s.length != stickerSlots * _k) {
      _makeState();
    }
    final ox = cx;
    final oy = cy1;
    final sinkX = cx;
    final sinkY = height;
    final vortex = isVortex;

    if (m != _lastMode) {
      if (m == 1) {
        _emitT = 0;
        // 上一轮离场把贴纸都扔出了屏，新一轮羽流需要新归位点。
        _seedHomes(s);
        for (var i = 0; i < stickerSlots; i++) {
          final b = i * _k;
          // 还在离场途中的先走完；之后会从按钮里重新出生。
          if (s[b + 5] > 0 && s[b + 18] > 0) continue;
          s[b] = ox;
          s[b + 1] = oy;
          s[b + 2] = 0;
          s[b + 3] = 0;
          s[b + 4] = 0;
          s[b + 5] = 0;
          s[b + 11] = 0;
          s[b + 12] = 0;
          s[b + 18] = 0;
        }
      } else if (m == 2) {
        _leaveT = 0;
        for (var i = 0; i < stickerSlots; i++) {
          final b = i * _k;
          if (s[b + 5] <= 0) continue;
          // 只有漩涡必须在球回座后完成离场；
          // Sky 回到浮力系并在 idle 时淡出。
          s[b + 18] = vortex ? 1 : 0;
          if (!vortex) {
            // 放手：四散一推 + 初次翻滚，之后交给重力。
            s[b + 2] += (_rand.nextDouble() - 0.5) * 90;
            s[b + 3] += 40 + _rand.nextDouble() * 160;
            s[b + 10] += (_rand.nextDouble() - 0.5) * 3.0;
            continue;
          }
          // 每张贴纸有自己的一条入芯之路：
          // 起点、时机（离核心近的先走）、时长（远的略长）、缠绕紧度。
          final dx = s[b] - sinkX;
          final dy = s[b + 1] - sinkY;
          final r0 = math.max(1.0, math.sqrt(dx * dx + dy * dy));
          final far = math.min(1.0, r0 / 900);
          s[b + 13] = r0;
          s[b + 14] = math.atan2(dy, dx);
          s[b + 15] = 0.02 + 0.12 * far + _rand.nextDouble() * 0.05;
          s[b + 16] = 0.30 + 0.28 * far + _rand.nextDouble() * 0.08;
          // 单臂：所有贴纸同向缠绕，整团羽流沿一侧倾泻而下。
          s[b + 17] = 0.42 + _rand.nextDouble() * 0.30;
          s[b + 10] = 0.6 + _rand.nextDouble() * 1.2;
        }
      }
      _lastMode = m;
    }

    if (_emitT >= 0) _emitT += dt * 1000;
    if (m == 2 || _leaving > 0) _leaveT += dt;
    final t = _clock;
    // 核心对尘埃的抓力在第一拍里建立。
    final ramp = math.min(1, _leaveT / 0.30);
    final pull = 0.25 + 0.75 * ramp * ramp;
    var swallowed = 0.0;
    var stillLeaving = 0;

    for (var i = 0; i < stickerSlots; i++) {
      final b = i * _k;
      final r = stickerSizes[i] * 0.5;

      if (m == 1 &&
          _emitT >= 0 &&
          s[b + 5] == 0 &&
          _emitT > _emitDelayMs + i * 30) {
        // 五分之四从按钮自身的玻璃中升起（出生即够大，
        // 透镜会放大并劈开它们）；其余在按钮上方以小点浮现再长大。
        final ang = -math.pi / 2 + (_rand.nextDouble() - 0.5) * 1.2;
        final sp = 90 + _rand.nextDouble() * 200;
        if (i % 5 != 2) {
          final a2 = _rand.nextDouble() * math.pi * 2;
          final rr = math.sqrt(_rand.nextDouble()) * 26;
          s[b] = ox + math.cos(a2) * rr;
          s[b + 1] = oy + 8 + math.sin(a2) * rr * 0.6;
          s[b + 4] = 0.34;
        } else {
          s[b] = ox + (_rand.nextDouble() - 0.5) * 120;
          s[b + 1] = oy - 50 - _rand.nextDouble() * 70;
          s[b + 4] = 0.16;
        }
        s[b + 2] = math.cos(ang) * sp;
        s[b + 3] = math.sin(ang) * sp;
        s[b + 5] = 1;
        s[b + 10] = (_rand.nextDouble() - 0.5) * 3.2;
        s[b + 11] = 0;
        s[b + 12] = 0;
        s[b + 18] = 0;
      }
      if (s[b + 5] <= 0) continue;

      var vx = s[b + 2];
      var vy = s[b + 3];
      final out = m == 2 || (vortex && s[b + 18] > 0);

      if (out && vortex) {
        stillLeaving += 1;
        // ── 螺旋入芯 ──
        // 对数螺线：半径按 ease-in 收拢（先是倾身、后是喷射），
        // 缠绕随深入收紧，路径只在核心附近甩开——如同坠入星核的物质。
        // 拉伸、自旋、尘埃全部读真实速度。
        final tau = _leaveT - s[b + 15];
        final r0 = s[b + 13];
        var rad = r0;
        if (tau > 0) {
          final u = math.min(1, tau / s[b + 16]);
          final e = math.pow(u, 2.0).toDouble();
          rad = r0 * (1 - e);
          final th =
              s[b + 14] + s[b + 17] * math.log(r0 / math.max(rad, 6));
          final nx = sinkX + math.cos(th) * rad;
          final ny = sinkY + math.sin(th) * rad;
          vx = (nx - s[b]) / dt;
          vy = (ny - s[b + 1]) / dt;
          s[b] = nx;
          s[b + 1] = ny;
          // 缩入核心并自旋加速。
          s[b + 4] = 0.12 + 0.88 * math.pow(math.min(1, rad / 260), 0.8);
          s[b + 10] +=
              (s[b + 10].sign == 0 ? 1 : s[b + 10].sign) * 26 * e * dt;
          if (u >= 1 || rad < _sinkRadius) {
            s[b + 5] = 0;
            s[b + 18] = 0;
            swallowed += 0.6 + 0.4 * (stickerSizes[i] / 104);
            // 入口处的尘埃飞溅。
            for (var k = 0; k < 5; k++) {
              final h = _dustHead;
              final c = h * _dustK;
              _dustHead = (h + 1) % _dustMotes;
              final a2 = _rand.nextDouble() * math.pi * 2;
              final spd = 120 + _rand.nextDouble() * 260;
              d[c] = sinkX;
              d[c + 1] = sinkY - 6;
              d[c + 2] = math.cos(a2) * spd;
              d[c + 3] = math.sin(a2) * spd - 120;
              d[c + 4] = 0.30 + _rand.nextDouble() * 0.25;
              d[c + 5] = d[c + 4];
            }
            continue;
          }
        } else {
          // 尚未轮到：原地悬停，最轻的漂移。
          final hold = math.pow(0.05, dt).toDouble();
          vx *= hold;
          vy *= hold;
          s[b] += vx * dt;
          s[b + 1] += vy * dt;
        }
        s[b + 2] = vx;
        s[b + 3] = vy;
        s[b + 9] += s[b + 10] * dt;
        final sp = math.sqrt(vx * vx + vy * vy);

        // 运动拉伸：转向航向并沿其拉伸。
        if (sp > 40) s[b + 11] = math.atan2(vy, vx);
        final st = math.min(0.9, math.max(0, (sp - 450) / 2400));
        s[b + 12] += (st - s[b + 12]) * math.min(1, dt * 16);

        // 星尘脱落——越快越多。
        if (sp > 200) {
          final n = sp > 1400 ? 4 : (sp > 600 ? 3 : 2);
          final ux = vx / math.max(1, sp);
          final uy = vy / math.max(1, sp);
          for (var k = 0; k < n; k++) {
            final h = _dustHead;
            final c = h * _dustK;
            _dustHead = (h + 1) % _dustMotes;
            final off = (_rand.nextDouble() - 0.5) * stickerSizes[i] * 0.45;
            final back = _rand.nextDouble() * stickerSizes[i] * 0.3;
            d[c] = s[b] - ux * back - uy * off;
            d[c + 1] = s[b + 1] - uy * back + ux * off;
            d[c + 2] =
                vx * (0.25 + 0.30 * _rand.nextDouble()) + (_rand.nextDouble() - 0.5) * 80;
            d[c + 3] =
                vy * (0.25 + 0.30 * _rand.nextDouble()) + (_rand.nextDouble() - 0.5) * 80;
            d[c + 4] = 0.45 + _rand.nextDouble() * 0.40;
            d[c + 5] = d[c + 4];
          }
        }
        continue;
      }

      if (s[b + 4] < 1) s[b + 4] = math.min(1, s[b + 4] + dt * 3.6);
      s[b + 12] *= math.pow(0.02, dt).toDouble();

      if (out) {
        stillLeaving += 1;
        // 坠落：重力 + 轻微摆动，再无牵挂。
        vy += 1500 * dt;
        vx += math.sin(t * 1.3 + s[b + 6]) * 30 * dt;
      } else {
        vy -= 16 * dt; // 浮力
        vx += math.sin(t * 0.85 + s[b + 6]) * 11 * dt; // 游走
        vy += math.cos(t * 0.65 + s[b + 6] * 1.3) * 7 * dt;
        final hx = ox + s[b + 7];
        final hy = oy + s[b + 8];
        vx += (hx - s[b]) * 2.0 * dt; // 归位弹簧
        vy += (hy - s[b + 1]) * 2.0 * dt;
      }

      if (touchOn) {
        final dx = s[b] - touchX;
        final dy = s[b + 1] - touchY;
        final dd = math.sqrt(dx * dx + dy * dy);
        const reach = 170.0;
        if (dd < reach && dd > 0.5) {
          final f = (1 - dd / reach) * 2600 * dt;
          vx += (dx / dd) * f;
          vy += (dy / dd) * f;
          s[b + 10] += (dx / dd) * 0.9 * dt * 12;
        }
        vx += windX * 0.09 * dt * 60;
        vy += windY * 0.09 * dt * 60;
      }

      // 邻居斥力。
      for (var j = 0; j < stickerSlots; j++) {
        if (j == i) continue;
        final c = j * _k;
        if (s[c + 5] <= 0) continue;
        final dx = s[b] - s[c];
        final dy = s[b + 1] - s[c + 1];
        final dd = math.sqrt(dx * dx + dy * dy);
        final minD = (r + stickerSizes[j] * 0.5) * 0.86;
        if (dd < minD && dd > 0.1) {
          final f = (minD - dd) * 13 * dt;
          vx += (dx / dd) * f;
          vy += (dy / dd) * f;
        }
      }

      // 边界。
      final pad = -r * 0.5;
      if (s[b] < pad) vx += (pad - s[b]) * 6 * dt;
      if (s[b] > width - pad) vx -= (s[b] - (width - pad)) * 6 * dt;
      if (!out) {
        if (s[b + 1] < -r * 1.3) vy += (-r * 1.3 - s[b + 1]) * 8 * dt;
        final floor = (i % 6 == 4 && stickerSizes[i] < 82)
            ? oy + r
            : oy - r * 0.8;
        if (s[b + 1] > floor) vy -= (s[b + 1] - floor) * 10 * dt;
      }

      final drag = math.pow(out ? 0.55 : 0.07, dt).toDouble();
      vx *= drag;
      vy *= drag;
      s[b + 2] = vx;
      s[b + 3] = vy;
      s[b] += vx * dt;
      s[b + 1] += vy * dt;

      // 翻滚：自旋衰减后归于轻摇。
      s[b + 10] *= math.pow(out ? 0.6 : 0.25, dt).toDouble();
      s[b + 9] += s[b + 10] * dt + math.sin(t * 0.7 + s[b + 6]) * 0.09 * dt;

      if (out && s[b + 1] > height + r * 1.5) {
        s[b + 5] = 0;
        s[b + 18] = 0;
      }
      // idle 且未离场：短促下沉后上浮淡出（Sky 的回归）。
      if (m == 0 && s[b + 18] <= 0) {
        s[b + 5] = math.max(0, s[b + 5] - dt * 0.65);
      }
    }

    // ── 尘埃 ──
    // 每粒尘埃受同一核心牵引，轨迹也弯进螺线，一秒内烧尽。
    if (vortex) {
      for (var q = 0; q < _dustMotes; q++) {
        final c = q * _dustK;
        if (d[c + 4] <= 0) continue;
        d[c + 4] -= dt;
        final dx = sinkX - d[c];
        final dy = sinkY - d[c + 1];
        final dist = math.max(1, math.sqrt(dx * dx + dy * dy));
        final g = (700 + 7e5 / math.max(dist, 60)) * (m == 2 ? pull : 0.3);
        final nx = dx / dist;
        final ny = dy / dist;
        d[c + 2] += (nx * g - ny * g * 0.30) * dt;
        d[c + 3] += (ny * g + nx * g * 0.30) * dt;
        final dr = math.pow(0.25, dt).toDouble();
        d[c + 2] *= dr;
        d[c + 3] *= dr;
        d[c] += d[c + 2] * dt;
        d[c + 1] += d[c + 3] * dt;
        if (dist < _sinkRadius * 0.6) d[c + 4] = 0;
      }
    }

    _leaving = stillLeaving;
    if (swallowed > 0) feed = math.min(1, feed + swallowed * 0.16);
    feed *= math.pow(0.08, dt).toDouble();
  }

  @override
  void dispose() {
    _lastElapsed = null;
    super.dispose();
  }
}

enum _ThirdPhase { idle, reveal, out, gap }

// ── 数值工具 ────────────────────────────────────────────────────────────────

double _clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double _clamp01(double v) => _clamp(v, 0, 1);

/// dart:math 没有 tanh，自己定义。
double _tanh(double x) {
  final e2x = math.exp(2 * x);
  if (e2x.isInfinite) return x > 0 ? 1.0 : -1.0;
  return (e2x - 1) / (e2x + 1);
}

double _lerpRange(double x, double x0, double x1, double y0, double y1) {
  if (x1 == x0) return y0;
  final t = (x - x0) / (x1 - x0);
  return y0 + (y1 - y0) * t;
}

/// Reanimated 每帧固定 lerp 系数换算到任意 dt。
double _perFrame(double factor, double dt) =>
    1 - math.pow(1 - factor, dt * 60).toDouble();

/// 单参数三次贝塞尔 y(t)（0.23,1,0.32,1 / 0.16,0.42,0.40,1）。
double _bezier(double t, double x1, double y1, double x2, double y2) {
  // 先解 x(t)=t 的参数 u（牛顿迭代，几次即收敛）。
  var u = t;
  for (var i = 0; i < 8; i++) {
    final bx = _cubic(u, x1, x2) - t;
    if (bx.abs() < 1e-6) break;
    final dBx = _cubicDeriv(u, x1, x2);
    if (dBx.abs() < 1e-6) break;
    u -= bx / dBx;
    u = _clamp01(u);
  }
  return _cubic(u, y1, y2);
}

/// 标准三次贝塞尔（端点 0 → 1）：B(t) = 3(1-t)²t·a + 3(1-t)t²·b + t³。
double _cubic(double t, double a, double b) {
  final mt = 1 - t;
  return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t;
}

/// B'(t) = 3(1-t)²·a + 6(1-t)t·(b-a) + 3t²·(1-b)。
double _cubicDeriv(double t, double a, double b) {
  final mt = 1 - t;
  return 3 * mt * mt * a + 6 * mt * t * (b - a) + 3 * t * t * (1 - b);
}
