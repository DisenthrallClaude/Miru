import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

class GeneralErrorWidget extends StatelessWidget {
  const GeneralErrorWidget({
    required this.errMsg,
    this.actions,
    super.key,
  });

  final String errMsg;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // P2-5：错误态与空态共用「色环徽章 + 文案」语汇，并以淡入上浮登场，
    // 不再是光秃秃一行字硬切出现。
    return RevealOnMount(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: Icon(
            CupertinoIcons.wifi_slash,
            size: 26,
            color: colorScheme.onErrorContainer,
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 2 / 3,
              ),
              child: Text(
                errMsg,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        if (actions != null)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: actions!,
          ),
      ],
      ),
    );
  }
}

/// 挂载时淡入并上浮 [rise] 像素（一次性，纯视觉）。
class RevealOnMount extends StatelessWidget {
  const RevealOnMount({
    super.key,
    required this.child,
    this.rise = 14,
    this.duration = const Duration(milliseconds: 460),
  });

  final Widget child;
  final double rise;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, rise * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}

class GeneralErrorButton extends StatelessWidget {
  const GeneralErrorButton({
    super.key,
    required this.onPressed,
    required this.text,
  });

  final Function() onPressed;
  final String text;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((_) {
          return Theme.of(context).colorScheme.primary.withAlpha(20);
        }),
      ),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
