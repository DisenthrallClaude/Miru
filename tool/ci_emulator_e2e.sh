#!/usr/bin/env bash
# GitHub Actions 模拟器端到端自测：逐源自动搜索→选集→播放，
# 每个源截图 3 张 + 录屏 + logcat，产物落 e2e-out/。
set -u
PKG=io.github.disenthrallclaude.miru
APK=${APK:-build/app/outputs/flutter-apk/app-release.apk}
OUT=${OUT:-e2e-out}
SPECS=${SPECS:-"FQDM|凡人修仙传;MXdm|凡人修仙传;AGE|凡人修仙传;blbl|凡人修仙传;fcdm|凡人修仙传"}
mkdir -p "$OUT"
adb wait-for-device
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb install -r -g "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 1; }
i=0
IFS=';' read -ra ARR <<< "$SPECS"
for spec in "${ARR[@]}"; do
  i=$((i+1))
  name=$(echo "$spec" | cut -d'|' -f1)
  tag="${i}_${name}"
  echo "=== [$tag] $spec"
  adb shell am force-stop $PKG
  adb shell pm clear $PKG > /dev/null
  adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true
  adb shell mkdir -p /sdcard/Android/data/$PKG/files
  printf '%s' "$spec" > /tmp/autotest.txt
  adb push /tmp/autotest.txt /sdcard/Android/data/$PKG/files/autotest.txt > /dev/null
  adb logcat -c
  adb shell "screenrecord --time-limit 100 --bit-rate 2000000 /sdcard/rec_${tag}.mp4" &
  REC=$!
  adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
  for t in 15 40 70 95; do
    sleep $(( t - ${prev:-0} )); prev=$t
    adb exec-out screencap -p > "$OUT/${tag}_t${t}s.png"
  done
  prev=0
  wait $REC 2>/dev/null || true
  sleep 2
  adb pull /sdcard/rec_${tag}.mp4 "$OUT/" > /dev/null 2>&1 || true
  adb shell rm -f /sdcard/rec_${tag}.mp4
  adb logcat -d > "$OUT/${tag}_logcat.txt"
  grep -E "MIRU_AUTOTEST|HybridResolver|PlayerController|VideoPageController|mpv|LocalMediaProxy|FastResolver|E/flutter|FATAL" "$OUT/${tag}_logcat.txt" | cut -c1-400 > "$OUT/${tag}_key.txt" || true
  # 播放判定：首帧钩子/时间线记录
  if grep -qE "first ?frame|recordFirstFrame|FirstFrame|hasVideoParams|video-params" "$OUT/${tag}_logcat.txt"; then echo "[$tag] FIRST_FRAME_SEEN" | tee -a "$OUT/summary.txt"; else echo "[$tag] NO_FIRST_FRAME" | tee -a "$OUT/summary.txt"; fi
done
exit 0
