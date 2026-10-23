#!/usr/bin/env bash
# GitHub Actions 模拟器 UI 巡检（v1.8.1：分类/时间表/播放/更新下载）：开启系统动画，按真实触控走一遍
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

shot() { timeout 20 adb exec-out screencap -p > "$OUT/ui_v181_$1.png" || true; echo "  shot $1 $(date +%T)"; }

# 在 uiautomator 树里按文字/无障碍描述找控件中心并点击。
tap_text() {
  local label="$1"
  timeout 20 adb shell uiautomator dump /sdcard/u.xml > /dev/null 2>&1
  timeout 10 adb shell cat /sdcard/u.xml > "$OUT/ui_dump.xml" 2>/dev/null
  local xy
  xy=$(EXACT="${EXACT:-0}" python3 - "$label" "$OUT/ui_dump.xml" <<'PY'
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
    exact = __import__('os').environ.get('EXACT') == '1'
    vals = [(t.group(1) if t else ''), (d.group(1) if d else '')]
    if (exact and any(v.replace('&#10;','\n').split('\n')[0].strip() == label for v in vals)) or (not exact and label in txt):
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


tap_exact() { EXACT=1 tap_text "$1"; }
dump() { timeout 20 adb shell uiautomator dump /sdcard/u.xml > /dev/null 2>&1; timeout 10 adb shell cat /sdcard/u.xml > "$OUT/dump_$1.xml" 2>/dev/null || true; }
launch() {
  timeout 20 adb shell am force-stop $PKG
  adb shell "setprop debug.miru.autotest '$1'"
  timeout 20 adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
}
size=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1)
W=${size%x*}; H=${size#*x}
echo "screen ${W}x${H}"
(timeout 600 adb shell screenrecord --time-limit 180 --bit-rate 2000000 /sdcard/ui_tour.mp4 >/dev/null 2>&1) &

# ---- 1. 首页 + 分类 ----
timeout 30 adb shell pm clear $PKG > /dev/null
launch 'none|none'
sleep 20; shot 01_home; dump home
tap_exact "奇幻" && { sleep 7; shot 02_category_qihuan; dump cat_qihuan; }
tap_exact "武侠" && { sleep 7; shot 03_category_wuxia; dump cat_wuxia; }
tap_exact "推荐" && sleep 3

# ---- 2. 时间表（冷启动无缓存：骨架 → 数据） ----
tap_exact "时间表"
sleep 1.2; shot 04_timeline_loading
sleep 14; shot 05_timeline; dump timeline_today
for d in 一 二 三 四 五 六 日; do tap_exact "$d" > /dev/null && sleep 1.5 && dump "timeline_$d"; done
shot 06_timeline_sunday
# 二次进入：先显缓存（秒开）
launch 'none|none'; sleep 12; tap_exact "时间表"; sleep 0.8; shot 07_timeline_cached
dump timeline_cached

# ---- 3. 详情 / 播放页 ----
tap_exact "推荐"; sleep 2
if tap_text "凡人修仙传"; then sleep 4; shot 08_info; fi
launch "$SPEC"
sleep 12; shot 09_player_loading
sleep 35; shot 10_player

# ---- 4. 应用内更新下载（真实镜像测速 + 分块下载 v1.8.0 APK）----
launch 'update|demo'
sleep 22; shot 11_update_dialog; dump update_dialog
tap_exact "立即更新"
sleep 1.5; shot 12_update_probe
sleep 8; shot 13_update_downloading; dump update_dl
for i in $(seq 1 36); do
  sleep 5
  timeout 20 adb shell uiautomator dump /sdcard/u.xml > /dev/null 2>&1
  if timeout 10 adb shell cat /sdcard/u.xml 2>/dev/null | grep -q "下载完成\|下载失败"; then break; fi
  [ $i = 3 ] && shot 14_update_downloading_late
done
shot 15_update_done; dump update_done

adb shell pkill -INT screenrecord || true
sleep 3
timeout 60 adb pull /sdcard/ui_tour.mp4 "$OUT/" > /dev/null 2>&1 || true
timeout 30 adb logcat -d -v time > "$OUT/ui_tour_logcat.txt"
grep -E "MIRU_AUTOTEST|Update:|Schedule:|E/flutter|FATAL|AndroidRuntime|Exception" "$OUT/ui_tour_logcat.txt" | cut -c1-600 > "$OUT/ui_tour_key.txt" || true
echo "ui tour done"
exit 0
