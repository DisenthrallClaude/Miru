import 'package:miru/bean/widget/glass.dart';
import 'package:flutter/material.dart';

enum _TileKind { plain, toggle, radio }

// 向 iOS 分组列表靠拢：整组一个大圆角，组内行几乎连续（仅留发丝级缝隙），
// 按下时该行morph 成大圆角，保留原有的触感反馈。
const double _outerRadius = 18;
const double _innerRadius = 2;
const double _rowGap = 2;

class SettingsList extends StatelessWidget {
  const SettingsList({super.key, required this.sections, this.maxWidth = 1000});

  final List<Widget> sections;

  /// Defaulted here so a page that says nothing still matches the others.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: sections.length,
      itemBuilder: (context, index) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: sections[index],
        ),
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.tiles,
    this.title,
    this.bottomInfo,
    this.margin,
  });

  final List<Widget> tiles;
  final Widget? title;
  final Widget? bottomInfo;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: margin ?? const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DefaultTextStyle.merge(
                // 分组标题用次级灰而非强调色，保持克制
                style: textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  letterSpacing: 0.2,
                ),
                child: title!,
              ),
            ),
          SettingsSplitGroup(children: tiles),
          if (bottomInfo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: DefaultTextStyle.merge(
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                child: bottomInfo!,
              ),
            ),
        ],
      ),
    );
  }
}

/// Rows laid out as an M3 split list: large corners at the group's two ends,
/// small ones in between, and a pressed row morphing out of the group. That
/// morph is what separates the rows, in place of a divider.
class SettingsSplitGroup extends StatelessWidget {
  const SettingsSplitGroup({
    super.key,
    required this.children,
    this.outerRadius = _outerRadius,
  });

  final List<Widget> children;

  /// The group's two end corners, and the radius a pressed row morphs to.
  /// Settings pages take the default; a page whose surrounding cards run at a
  /// smaller scale passes theirs so the group sits level with them.
  final double outerRadius;

  /// Hand to a row's [InkWell.onHighlightChanged] to drive the morph. Null
  /// outside a group, which leaves the row's shape static.
  static ValueChanged<bool>? pressReporterOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_SplitRowScope>()
        ?.onPressChanged;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: _rowGap),
          _SplitRow(
            first: i == 0,
            last: i == children.length - 1,
            outerRadius: outerRadius,
            child: children[i],
          ),
        ],
      ],
    );
  }
}

class _SplitRow extends StatefulWidget {
  const _SplitRow({
    required this.first,
    required this.last,
    required this.outerRadius,
    required this.child,
  });

  final bool first;
  final bool last;
  final double outerRadius;
  final Widget child;

  @override
  State<_SplitRow> createState() => _SplitRowState();
}

class _SplitRowState extends State<_SplitRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final outer = widget.outerRadius;
    final top = widget.first || _pressed ? outer : _innerRadius;
    final bottom = widget.last || _pressed ? outer : _innerRadius;
    final radius = BorderRadius.vertical(
      top: Radius.circular(top),
      bottom: Radius.circular(bottom),
    );

    final row = Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: _SplitRowScope(
        onPressChanged: (pressed) => setState(() => _pressed = pressed),
        child: widget.child,
      ),
    );

    // 行用「轻玻璃」：半透明底 + 斜向高光 + 发丝描边，玻璃质感常驻且
    // 零 GPU 开销（常驻 BackdropFilter 会让长列表帧率崩掉）。
    //
    // 按压反馈是纯属性动画（底色/描边/高光提亮）：包裹结构恒定，
    // InkWell 的 Element 与手势在按压全程保持存活。
    // 之前的实现按压时切换到 FrostedSurface——它首帧换 key 重挂子树，
    // 进行中的 tap 手势随 Element 一起被销毁，表现为
    // 「点一下只出玻璃态、再点一下才进入」。
    return AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: radius,
        // 白度刻意压低：源卡片列表会在同一块玻璃底上叠十几张卡，
        // 白度一高整片就糊成白色，玻璃的通透感反而没了。
        color: _pressed
            ? (isLight
                ? Colors.white.withValues(alpha: 0.46)
                : Colors.white.withValues(alpha: 0.12))
            : (isLight
                ? Colors.white.withValues(alpha: 0.30)
                : Colors.white.withValues(alpha: 0.05)),
        border: Border.all(
          color: _pressed
              ? (isLight
                  ? Colors.black.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.32))
              : (isLight
                  ? Colors.black.withValues(alpha: 0.07)
                  : Colors.white.withValues(alpha: 0.18)),
          width: 0.6,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(
                alpha: _pressed ? (isLight ? 0.5 : 0.2) : (isLight ? 0.32 : 0.10)),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.72],
        ),
      ),
      child: row,
    );
  }
}

class _SplitRowScope extends InheritedWidget {
  const _SplitRowScope({required this.onPressChanged, required super.child});

  final ValueChanged<bool> onPressChanged;

  // The callback always reaches the same state, so a rebuilt scope never
  // obsoletes the one a row already holds.
  @override
  bool updateShouldNotify(_SplitRowScope oldWidget) => false;
}

/// A [SettingsSection] whose tiles form a single radio group, so arrow keys
/// traverse the options and screen readers announce them as one set.
class SettingsRadioSection<T> extends StatelessWidget {
  const SettingsRadioSection({
    super.key,
    required this.groupValue,
    required this.onChanged,
    required this.tiles,
    this.title,
  });

  final T? groupValue;
  final ValueChanged<T?> onChanged;
  final List<Widget> tiles;
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<T>(
      groupValue: groupValue,
      onChanged: onChanged,
      child: SettingsSection(title: title, tiles: tiles),
    );
  }
}

Color _disabledOn(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38);

/// The icon-and-text run every row opens with. Callers wrap it in [Expanded].
class _TileLabel extends StatelessWidget {
  const _TileLabel({
    required this.title,
    this.leading,
    this.description,
    this.enabled = true,
  });

  final Widget title;
  final IconData? leading;
  final Widget? description;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final disabled = enabled ? null : _disabledOn(context);
    final foreground = disabled ?? colorScheme.onSurface;
    final secondary = disabled ?? colorScheme.onSurfaceVariant;

    return Row(
      children: [
        if (leading != null) ...[
          GlassIconDisc(
            icon: leading!,
            size: 32,
            iconSize: 18,
            color: secondary,
          ),
          const SizedBox(width: 16),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: textTheme.bodyLarge?.copyWith(color: foreground),
                child: title,
              ),
              if (description != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: textTheme.bodySmall?.copyWith(color: secondary),
                  child: description!,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A row that opens a whole category rather than changing one value: the
/// tonal icon badge marks that step down, which is why [SettingsTile] keeps a
/// flat icon. Drop it in a [SettingsSplitGroup] like any other row.
class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      onHighlightChanged: SettingsSplitGroup.pressReporterOf(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            GlassIconDisc(icon: icon, tinted: true),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// A row whose control is a slider. The label line carries a tonal readout of
/// the current value and the track spans the row beneath it, so the icon, the
/// track and the text never share a line.
class SettingsSliderTile extends StatelessWidget {
  const SettingsSliderTile({
    super.key,
    required this.title,
    required this.value,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.leading,
    this.description,
  });

  final Widget title;
  final IconData? leading;
  final Widget? description;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _TileLabel(
                  title: title,
                  leading: leading,
                  description: description,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  valueLabel,
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    // Steady digit widths, so dragging can't jitter the pill.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            // The pill is the readout, so no bubble rides the thumb; the zero
            // inset then measures the track against the row rather than the
            // thumb's overlay box.
            showValueIndicator: ShowValueIndicator.never,
            padding: EdgeInsets.zero,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class SettingsTile<T> extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.leading,
    this.description,
    this.trailing,
    this.value,
    this.onPressed,
    this.enabled = true,
  })  : _kind = _TileKind.plain,
        onToggle = null,
        initialValue = null,
        radioValue = null;

  /// Tapping the row toggles too, in which case [onToggle] receives null.
  const SettingsTile.switchTile({
    super.key,
    required this.title,
    required this.initialValue,
    required this.onToggle,
    this.leading,
    this.description,
    this.enabled = true,
  })  : _kind = _TileKind.toggle,
        trailing = null,
        value = null,
        onPressed = null,
        radioValue = null;

  /// Selection and change handling come from the enclosing
  /// [SettingsRadioSection], so the whole option list is one radio group.
  const SettingsTile.radioTile({
    super.key,
    required this.title,
    required T this.radioValue,
    this.leading,
    this.description,
    this.enabled = true,
  })  : _kind = _TileKind.radio,
        trailing = null,
        value = null,
        onPressed = null,
        onToggle = null,
        initialValue = null;

  final Widget title;

  /// Flat, not a tonal badge — the badge marks a row opening a whole category.
  final IconData? leading;
  final Widget? description;
  final Widget? trailing;
  final Widget? value;
  final void Function(BuildContext context)? onPressed;
  final void Function(bool? value)? onToggle;
  final bool? initialValue;
  final T? radioValue;
  final bool enabled;
  final _TileKind _kind;

  VoidCallback? _tapHandler(BuildContext context) {
    if (!enabled) {
      return null;
    }
    switch (_kind) {
      case _TileKind.plain:
        return onPressed == null ? null : () => onPressed!(context);
      case _TileKind.toggle:
        return onToggle == null ? null : () => onToggle!(null);
      case _TileKind.radio:
        final registry = RadioGroup.maybeOf<T>(context);
        return registry == null ? null : () => registry.onChanged(radioValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final secondary =
        enabled ? colorScheme.onSurfaceVariant : _disabledOn(context);

    return InkWell(
      onTap: _tapHandler(context),
      onHighlightChanged: SettingsSplitGroup.pressReporterOf(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            children: [
              Expanded(
                child: _TileLabel(
                  title: title,
                  leading: leading,
                  description: description,
                  enabled: enabled,
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                DefaultTextStyle.merge(
                  style: textTheme.bodyMedium?.copyWith(color: secondary),
                  child: value!,
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 8),
                IconTheme.merge(
                  data: IconThemeData(color: secondary),
                  child: trailing!,
                ),
              ],
              if (_kind == _TileKind.toggle) ...[
                const SizedBox(width: 12),
                Switch(
                  value: initialValue ?? false,
                  onChanged: enabled ? onToggle : null,
                ),
              ],
              if (_kind == _TileKind.radio) ...[
                const SizedBox(width: 12),
                Radio<T>(value: radioValue as T, enabled: enabled),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
