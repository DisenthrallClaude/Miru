// ignore_for_file: library_private_types_in_public_api

import 'package:mobx/mobx.dart';
import 'package:miru/pages/player/controller/player_aspect_ratio.dart';

part 'player_panel_controller.g.dart';

class PlayerPanelController = _PlayerPanelController
    with _$PlayerPanelController;

abstract class _PlayerPanelController with Store {
  /// 视频比例
  @observable
  PlayerAspectRatio aspectRatioMode = PlayerAspectRatio.automatic;

  // 视频亮度
  @observable
  double brightness = 0;

  // 播放器界面控制
  @observable
  bool lockPanel = false;
  @observable
  bool showVideoController = true;
  @observable
  bool showSeekTime = false;
  @observable
  bool showBrightness = false;
  @observable
  bool showVolume = false;
  @observable
  bool showPlaySpeed = false;
  @observable
  bool brightnessSeeking = false;
  @observable
  bool volumeSeeking = false;
  // 快进/快退 HUD 的方向（-1 退 / 0 无 / 1 进）。
  // 面板 Observer 里直接读取它（SeekHud direction 参数），此前未挂
  // @observable，恰好每次方向变化都伴随 currentPosition 更新才没露馅
  // ——属于踩在副作用上，双击快进退落地后方向可独立于位置变化。
  @observable
  int seekDirection = 0;
  @observable
  bool canHidePlayerPanel = true;

  @action
  void reset() {
    lockPanel = false;
    showVideoController = true;
    showSeekTime = false;
    showBrightness = false;
    showVolume = false;
    showPlaySpeed = false;
    brightnessSeeking = false;
    volumeSeeking = false;
    seekDirection = 0;
    canHidePlayerPanel = true;
  }
}
