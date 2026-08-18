import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:kazumi/utils/theme.dart';

/// 底部导航的「液态玻璃滑块」。
///
/// 切换页签时，一块玻璃从当前项弹到目标项：
/// * 位移用**弹簧模拟**（非固定曲线），因此会有过冲回弹的「duang duang」手感；
/// * 运动中按**实时速度**做水平拉伸 + 垂直压扁（squash & stretch），
///   越快越扁长，停下来回弹成圆角矩形 —— 这是「液体」而非「方块位移」的关键。
///
/// 该组件只负责画，不处理点击：它铺在 NavigationBar 之下，
/// 手势仍由 NavigationBar 自己接管，因此不影响任何既有交互。
class LiquidGlassIndicator extends StatefulWidget {
  const LiquidGlassIndicator({
    super.key,
    required this.index,
    required this.count,
    this.drivenPosition,
    this.height = 54,
    this.widthFactor = 0.72,
  });

  /// 当前选中项。
  final int index;

  /// 外部驱动的连续位置（如 TabController 的滑动进度）。
  /// 给定时不再使用内部弹簧，由调用方决定位置——用于跟手滑动场景。
  final double? drivenPosition;

  /// 页签总数。
  final int count;

  /// 滑块高度。
  final double height;

  /// 滑块宽度占单个页签宽度的比例。
  final double widthFactor;

  @override
  State<LiquidGlassIndicator> createState() => _LiquidGlassIndicatorState();
}

class _LiquidGlassIndicatorState extends State<LiquidGlassIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 以「页签序号」为单位的当前位置，可以是小数（运动中）。
  late double _position;

  /// 归一化速度，用于驱动拉伸量。
  double _velocity = 0;

  /// 弹簧参数：欠阻尼才会过冲回弹。
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 420,
    // < 1 为欠阻尼；0.62 大约回弹一到两下，既明显又不拖沓
    ratio: 0.62,
  );

  @override
  void initState() {
    super.initState();
    _position = widget.drivenPosition ?? widget.index.toDouble();
    _controller = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        setState(() {
          _position = _controller.value;
          _velocity = _controller.velocity;
        });
      });
  }

  @override
  void didUpdateWidget(covariant LiquidGlassIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.drivenPosition != null) {
      // 跟手模式：位置由外部给定，速度按帧间位移估算以驱动形变
      final next = widget.drivenPosition!;
      _velocity = (next - _position) * 60;
      _position = next;
      return;
    }
    if (oldWidget.index != widget.index) {
      _springTo(widget.index.toDouble());
    }
  }

  void _springTo(double target) {
    _controller.animateWith(
      SpringSimulation(_spring, _position, target, _controller.velocity),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = constraints.maxWidth / widget.count;
        final baseWidth = slot * widget.widthFactor;

        // 速度越大越扁长。除数决定灵敏度，clamp 防止极端形变。
        final stretch = (_velocity.abs() / 26).clamp(0.0, 0.5);
        final width = baseWidth * (1 + stretch);
        final height = widget.height * (1 - stretch * 0.42);

        // 以滑块中心对齐当前页签中心
        final centerX = slot * (_position + 0.5);
        final left = centerX - width / 2;

        return Stack(
          children: [
            Positioned(
              left: left,
              top: (widget.height - height) / 2,
              width: width,
              height: height,
              child: IgnorePointer(
                child: CupertinoLiquidGlass(
                  blurSigma: Frost.blur * 0.5,
                  tintOpacity: 0.16,
                  borderRadius:
                      BorderRadius.circular(height / 2),
                  edgeLightColor: Frost.edgeLight(Theme.of(context).brightness),
                  // 不要暗部/投影：有了玻璃就不需要阴影来交代层次，
                  // 去掉后滑块更「轻」，流动感也更纯粹。
                  edgeShadowColor: Colors.transparent,
                  specularGradient:
                      Frost.specular(Theme.of(context).brightness),
                  borderWidth: 1.0,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
