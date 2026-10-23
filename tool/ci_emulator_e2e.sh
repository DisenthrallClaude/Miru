#!/usr/bin/env bash
# GitHub Actions 模拟器端到端自测：逐源自动搜索→选集→播放，
# 每个源截图 4 张 + 录屏 + logcat，产物落 e2e-out/。
set -u
PKG=io.github.disenthrallclaude.miru
APK=${APK:-build/app/outputs/flutter-apk/app-release.apk}
OUT=${OUT:-e2e-out}
SPECS=${SPECS:-"FQDM|凡人修仙传;MXdm|凡人修仙传;AGE|凡人修仙传;fcdm|凡人修仙传"}
WAIT=${WAIT:-90}
mkdir -p "$OUT"
adb wait-for-device
adb logcat -v time > "$OUT/logcat_all.txt" 2>&1 &
adb install -r -g "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 1; }
adb shell getprop ro.build.version.sdk > "$OUT/device.txt"
i=0
IFS=';' read -ra ARR <<< "$SPECS"
for spec in "${ARR[@]}"; do
  i=$((i+1))
  name=$(echo "$spec" | cut -d'|' -f1)
  tag="${i}_${name}"
  echo "=== [$tag] $spec  $(date +%T)"
  adb get-state || { echo "device lost"; break; }
  timeout 20 adb shell am force-stop $PKG
  timeout 30 adb shell pm clear $PKG > /dev/null
  timeout 10 adb shell "setprop debug.miru.autotest '$spec'"
  echo "prop=$(adb shell getprop debug.miru.autotest)"
  timeout 10 adb logcat -c
  (timeout $((WAIT+15)) adb shell screenrecord --time-limit $WAIT --bit-rate 1500000 /sdcard/rec_${tag}.mp4 >/dev/null 2>&1) &
  REC=$!
  timeout 20 adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
  # v2 去广告验收：App 打出「可观看」信号（片头水印跳过结束）后 +3s/+10s 截图，
  # 这两张必须是正片（后台进行，不影响下面的固定时刻截图）。
  (
    for k in $(seq 1 $((WAIT*2))); do
      if timeout 5 adb logcat -d -s flutter:I 2>/dev/null | grep -q "MIRU_AUTOTEST ready"; then
        echo "  ready at ~$((k/2))s"
        sleep 3; timeout 20 adb exec-out screencap -p > "$OUT/${tag}_ready_t3.png"
        sleep 7; timeout 20 adb exec-out screencap -p > "$OUT/${tag}_ready_t10.png"
        break
      fi
      sleep 0.5
    done
  ) &
  READYW=$!
  prev=0
  for t in 12 35 60 $WAIT; do
    sleep $(( t - prev )); prev=$t
    timeout 20 adb exec-out screencap -p > "$OUT/${tag}_t${t}s.png" || true
    echo "  shot t=${t}s"
  done
  wait $REC 2>/dev/null || true
  kill $READYW 2>/dev/null || true
  sleep 3
  timeout 60 adb pull /sdcard/rec_${tag}.mp4 "$OUT/" > /dev/null 2>&1 || true
  timeout 10 adb shell rm -f /sdcard/rec_${tag}.mp4
  timeout 30 adb logcat -d -v time > "$OUT/${tag}_logcat.txt"
  grep -E "MIRU_AUTOTEST|MIRU_AD|HybridResolver|FastResolver|PlayerController|VideoPageController|LocalMediaProxy|WebView|mpv|E/flutter|FATAL|AndroidRuntime" "$OUT/${tag}_logcat.txt" | cut -c1-500 > "$OUT/${tag}_key.txt" || true
  echo "  key lines: $(wc -l < "$OUT/${tag}_key.txt")"
done
adb shell getprop sys.boot_completed > /dev/null 2>&1 && echo "device alive at end" || echo "device dead at end"
exit 0
