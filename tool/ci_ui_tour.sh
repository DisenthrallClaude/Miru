#!/usr/bin/env bash
# GitHub Actions 模拟器 UI 巡检（P2）：开启系统动画，按真实触控走一遍
# 首页 → 详情（纵深过渡）→ 选择播放源（错峰入场）→ 播放页（加载态）
# → 上滑进全屏（首次手势导览）→ 双击快进涟漪 → 长按倍速 → 亮度 → 下滑退出全屏，
# 每一步截图到 e2e-out/ui_v2_*.png，并保留录屏与 logcat。
set -u
PKG=io.github.disenthrallclaude.miru
APK=${APK:-build/app/outputs/flutter-apk/app-release.apk}
OUT=${OUT:-e2e-out}
SPEC=${SPEC:-"FQDM|凡人修仙传"}
mkdir -p "$OUT"
adb wait-for-device
# 打开系统动画（runner 默认关闭，关闭时 Flutter 会跳过过渡与微动效）。
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  adb shell settings put global $k 1
done
adb logcat -v time > "$OUT/logcat_all.txt" 2>&1 &
adb install -r -g "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 1; }

shot() { timeout 20 adb exec-out screencap -p > "$OUT/ui_v2_$1.png" || true; echo "  shot $1 $(date +%T)"; }

# 在 uiautomator 树里按文字/无障碍描述找控件中心并点击。
tap_text() {
  local label="$1"
  timeout 20 adb shell uiautomator dump /sdcard/u.xml > /dev/null 2>&1
  timeout 10 adb shell cat /sdcard/u.xml > "$OUT/ui_dump.xml" 2>/dev/null
  local xy
  xy=$(python3 - "$label" "$OUT/ui_dump.xml" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
try:
    xml = open(path, encoding='utf-8', errors='ignore').read()
except Exception:
    sys.exit(0)
for m in re.finditer(r'<node [^>]*>', xml):
    n = m.group(0)
    t = re.search(r'text="([^"]*)"', n); d = re.search(r'content-desc="([^"]*)"', n)
    txt = (t.group(1) if t else '') + ' ' + (d.group(1) if d else '')
    if label in txt:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
PY
)
  if [ -n "$xy" ]; then
    echo "  tap '$label' at $xy"
    adb shell input tap $xy
    return 0
  fi
  echo "  '$label' not found"
  return 1
}

size=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1)
W=${size%x*}; H=${size#*x}
echo "screen ${W}x${H}"

(timeout 400 adb shell screenrecord --time-limit 180 --bit-rate 2000000 /sdcard/ui_tour.mp4 >/dev/null 2>&1) &

# ---- 1. 首页 / 详情 / 源选择（autotest 指向不存在的规则 = 停在首页）----
timeout 20 adb shell am force-stop $PKG
timeout 30 adb shell pm clear $PKG > /dev/null
adb shell "setprop debug.miru.autotest 'none|none'"
timeout 20 adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 18
shot 01_home
# 点开「凡人修仙传」卡片（找不到就点第二列首张卡片的大致位置）
if ! tap_text "凡人修仙传"; then adb shell input tap $((W/2)) $((H*60/100)); fi
sleep 0.15; shot 02_route_transition
sleep 4; shot 03_info
tap_text "开始观看" || tap_text "观看" || adb shell input tap $((W*80/100)) $((H*88/100))
sleep 0.35; shot 04_source_sheet_enter
sleep 8; shot 05_source_sheet
adb shell input keyevent KEYCODE_BACK; sleep 1
adb shell input keyevent KEYCODE_BACK; sleep 1

# ---- 2. 播放页 ----
timeout 20 adb shell am force-stop $PKG
adb shell "setprop debug.miru.autotest '$SPEC'"
timeout 20 adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 9; shot 06_player_loading
sleep 4; shot 07_player_loading_late
sleep 32; shot 08_player_portrait
PH=$((W*9/16))            # 竖屏播放器高度（16:9）
PY=$((PH/2 + 60))         # 播放器中线（含状态栏偏移的近似）
# 中部上滑 → 进入全屏（新手势），首次进入会出现手势导览
adb shell input swipe $((W/2)) $((PY+120)) $((W/2)) $((PY-200)) 350
sleep 1.2; shot 09_fullscreen_coach
sleep 5;  shot 10_fullscreen
size2=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1)
# 全屏后为横屏：宽高互换
LW=$H; LH=$W
# 双击右侧 → 快进涟漪（两次 tap 同一 shell 内连发，间隔 <300ms）
adb shell "input tap $((LW*85/100)) $((LH/2)); input tap $((LW*85/100)) $((LH/2))"
sleep 0.15; shot 11_double_tap_ripple
sleep 2
# 长按 → 倍速
(adb shell input swipe $((LW/2)) $((LH/2)) $((LW/2)) $((LH/2)) 2500 &) ; sleep 1.4; shot 12_long_press_speed
sleep 2
# 左侧上滑 → 亮度 HUD
(adb shell input swipe $((LW*15/100)) $((LH*70/100)) $((LW*15/100)) $((LH*30/100)) 1800 &) ; sleep 1.2; shot 13_brightness
sleep 2
# 横滑 → 快进预览
(adb shell input swipe $((LW*30/100)) $((LH/2)) $((LW*60/100)) $((LH/2)) 1800 &) ; sleep 1.2; shot 14_seek_preview
sleep 3
# 中部下滑（慢）→ 跨过阈值的「松手退出全屏」提示，松手后退出
(adb shell input swipe $((LW/2)) $((LH*25/100)) $((LW/2)) $((LH*75/100)) 1600 &) ; sleep 1.3; shot 15_swipe_exit_hint
sleep 3; shot 16_after_exit
sleep 2
adb shell pkill -INT screenrecord || true
sleep 3
timeout 60 adb pull /sdcard/ui_tour.mp4 "$OUT/" > /dev/null 2>&1 || true
timeout 30 adb logcat -d -v time > "$OUT/ui_tour_logcat.txt"
grep -E "MIRU_AUTOTEST|E/flutter|FATAL|AndroidRuntime|Exception" "$OUT/ui_tour_logcat.txt" | cut -c1-400 > "$OUT/ui_tour_key.txt" || true
echo "ui tour done"
exit 0
