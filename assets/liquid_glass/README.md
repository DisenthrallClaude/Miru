# Liquid Glass 欢迎页资源说明

本目录的背景图与贴纸来自开源项目
[Appllama/liquid-glass-screens](https://github.com/Appllama/liquid-glass-screens)
（GPL-3.0，与 Miru 同协议），用于 v1.6.1 起的首次启动欢迎屏（v1.6.2 大修）。

- `sky/`：白天主题 —— 循环云海视频（sky.mp4）、海报帧与旅行贴纸。
- `astro/`：夜晚主题 —— 星空两层背景（stars/glow）与应用贴纸。

wordmark（品牌字标）为 Miru 自备的 chrome 气球字位图
（wordmark_day.png / wordmark_night.png，昼夜两个色调变体，
由 AI 生成原图去投影、抠白底、按原版亮度分布校准），
屏幕文案全部改写为 Miru 追番语境。交互与动效参数
（玻璃穹顶、上滑开屏、贴纸羽流、色散焦散等）参照原项目
`docs/MOTION_SPEC.md` 用 Flutter 重新实现。

致敬并感谢原作者的教育性分享。
