import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:miru/services/storage/storage.dart';
// 与其他设置详情页保持一致：顶栏统一走 SysAppBar 的液态玻璃材质。
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/settings/settings_list.dart';

class SetDisplayMode extends StatefulWidget {
  const SetDisplayMode({super.key});

  @override
  State<SetDisplayMode> createState() => _SetDisplayModeState();
}

class _SetDisplayModeState extends State<SetDisplayMode> {
  List<DisplayMode> modes = <DisplayMode>[];
  DisplayMode? active;
  DisplayMode? preferred;

  final ValueNotifier<int> page = ValueNotifier<int>(0);
  late final PageController controller = PageController()
    ..addListener(() {
      page.value = controller.page!.round();
    });

  @override
  void initState() {
    super.initState();
    init();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      fetchAll();
    });
  }

  Future<void> fetchAll() async {
    preferred = await FlutterDisplayMode.preferred;
    active = await FlutterDisplayMode.active;
    // 只读不写：设置项仅在用户主动选择时落盘（读取路径顺带写盘
    // 会把「从未设置过」的用户也固化成当前系统模式）。
    // await 之后页面可能已退出，避免对已卸载的 State 调用 setState。
    if (!mounted) return;
    setState(() {});
  }

  Future<void> init() async {
    try {
      modes = await FlutterDisplayMode.supported;
    } on PlatformException catch (_) {}
    var res = await getDisplayModeType(modes);

    preferred = modes.toList().firstWhere((el) => el == res);
    FlutterDisplayMode.setPreferredMode(preferred!);
  }

  Future<DisplayMode> getDisplayModeType(List<DisplayMode> modes) async {
    var value = GStorage.getSetting(SettingsKeys.displayMode);
    DisplayMode f = DisplayMode.auto;
    if (value != null) {
      f = modes.firstWhere((e) => e.toString() == value);
    }
    return f;
  }

  @override
  void dispose() {
    controller.dispose();
    page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 玻璃顶栏：SysAppBar 内部为 FrostedSurface 材质，
      // 返回键行为与原先裸 AppBar 的自动 leading 一致。
      appBar: const SysAppBar(title: Text('屏幕帧率设置')),
      body: (modes.isEmpty)
          ? const CircularProgressIndicator()
          : SettingsList(
              sections: [
                SettingsRadioSection<DisplayMode>(
                  title: Text('没有生效? 重启app试试'),
                  groupValue: preferred,
                  onChanged: (DisplayMode? newMode) async {
                    await FlutterDisplayMode.setPreferredMode(newMode!);
                    // 用户主动选择时才持久化（见 fetchAll 的只读说明）。
                    await GStorage.putSetting(
                        SettingsKeys.displayMode, newMode.toString());
                    await Future<dynamic>.delayed(
                      const Duration(milliseconds: 100),
                    );
                    await fetchAll();
                  },
                  tiles: modes
                      .map((e) => SettingsTile<DisplayMode>.radioTile(
                            radioValue: e,
                            title: e == DisplayMode.auto
                                ? Text('自动')
                                : Text('$e${e == active ? "  [系统]" : ""}'),
                          ))
                      .toList(),
                ),
              ],
            ),
    );
  }
}
