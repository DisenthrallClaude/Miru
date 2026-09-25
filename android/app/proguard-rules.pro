# Miru 混淆规则
# Flutter 3.47 起构建插件默认对 release 开启 R8 代码收缩
# (FlutterPlugin.shouldShrinkResources 默认 true)，并在
# android/app/proguard-rules.pro 存在时自动加载本文件。

# androidx.window 的 extensions/sidecar 接口是「编译期存根」：由设备
# 厂商在运行时提供（折叠屏/多窗口特性），任何 APK 里都不该打包真实
# 实现。Jetpack WindowManager 引用它们属正常现象，R8 把「找不到类」
# 当错误会直接终止构建。以下 -dontwarn 与 AGP 自动生成的
# missing_rules.txt 完全一致（build/outputs/mapping/release/）。
-dontwarn androidx.window.extensions.WindowExtensions
-dontwarn androidx.window.extensions.WindowExtensionsProvider
-dontwarn androidx.window.extensions.area.ExtensionWindowAreaPresentation
-dontwarn androidx.window.extensions.layout.DisplayFeature
-dontwarn androidx.window.extensions.layout.FoldingFeature
-dontwarn androidx.window.extensions.layout.WindowLayoutComponent
-dontwarn androidx.window.extensions.layout.WindowLayoutInfo
-dontwarn androidx.window.sidecar.SidecarDeviceState
-dontwarn androidx.window.sidecar.SidecarDisplayFeature
-dontwarn androidx.window.sidecar.SidecarInterface$SidecarCallback
-dontwarn androidx.window.sidecar.SidecarInterface
-dontwarn androidx.window.sidecar.SidecarProvider
-dontwarn androidx.window.sidecar.SidecarWindowLayoutInfo
