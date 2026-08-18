<div align="center">

<img src="assets/images/logo/logo_rounded.png" width="140"></img>

# Miru

**面向国漫用户的 Kazumi 修改版 · 仅 Android**

<img src="https://img.shields.io/badge/platform-Android-3DDC84?style=flat-square&logo=android&logoColor=white"></img>
<img src="https://img.shields.io/badge/Flutter-3.47-03A9F4?style=flat-square&logo=flutter&logoColor=white"></img>
<img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square"></img>

[**⬇ 下载最新版本**](https://github.com/DisenthrallClaude/Miru/releases/latest)

</div>

---

## 这是什么

Miru 基于开源项目 [Kazumi](https://github.com/Predidit/Kazumi) 修改而来。

原项目是一个通用的番剧采集与在线观看程序。Miru 在它的基础上做了两件事：**把内容面向国漫收敛**，以及**把界面整个重做一遍**。

**只提供 Android 版本。** 其他平台的代码虽然还在仓库里，但不做适配、不做测试、不提供构建。

## 截图

<div align="center">
<img src="docs/screenshots/home.png" width="30%"></img>
&nbsp;
<img src="docs/screenshots/timeline.png" width="30%"></img>
&nbsp;
<img src="docs/screenshots/settings.png" width="30%"></img>
</div>

## 改了什么

### 内容：只推国漫

- **推荐页与时间表按产地标签过滤**，只出国产动画，不再混入日番。想切回去只需改 `ApiEndpoints.bangumiRegionTag` 一个常量。
- **首页顶部固定横幅**，用内置的 16:9 官方主视觉图，不再拿竖版海报硬裁成横图。
- **置顶片单**：指定的国漫排在推荐流最前，顺序可在 `lib/request/config/featured_bangumi.dart` 里调整。

### 网络：解决国内直连不通

Bangumi 官方 API 在中国大陆无法直连。原项目通过自建 mirror 解决，但那个 mirror 需要签名密钥，**自建包拿不到密钥，会导致搜索、评论、热门、时间表全部失效**。

Miru 改用无需鉴权的社区公共反代：

| 官方域名 | 反代 |
| --- | --- |
| `api.bgm.tv` | `bgmapi.anibt.net` |
| `next.bgm.tv` | `next.bangumi.lol` |

> ⚠️ 这两个反代是社区个人维护的公共服务，可能限流或停服。真出问题时，改 `lib/request/config/api_endpoints.dart` 里的域名常量即可切换。

### 界面：重做

- **衬线排印**：全局使用思源宋体（Noto Serif SC），中英文统一。
- **液态玻璃材质**：导航条、顶栏、弹窗、选中态。页签滑块由弹簧模拟驱动，并按实时速度做拉伸压扁。
- **中性化配色**：参考 iOS 的表面色阶体系，强调色只出现在交互元素上，不铺满背景。
- **首页版式**：大横幅轮播 + 竖版海报网格。

### 体验

- **首启自动装规则**：不必再逐条点「安装」。
- **推荐页与时间表本地持久化**：加载一次后，之后启动直接读本地，不再联网。
- **播放源平铺**：选播放源时直接列出所有搜到的结果，不用先选来源再选结果。

## 安装

1. 到 [Releases](https://github.com/DisenthrallClaude/Miru/releases/latest) 下载 `Miru-android.apk`
2. 安装（首次需允许「安装未知来源应用」）
3. 首启跟着引导走完，规则会自动装好

**要求 Android 10 及以上。** APK 内含 `arm64-v8a` / `armeabi-v7a` / `x86_64` 三种架构，绝大多数机型可直接安装。

## 已知问题

**本项目仍有大量 bug 和待优化之处，不是成熟产品。** 已知的有：

- **弹幕功能失效**。弹幕依赖弹弹play 的签名密钥，自建包同样拿不到，所以弹幕拉不到内容。相关的失败提示已经移除，不再反复打扰。
- **部分番剧播放失败**。播放依赖第三方站点的采集规则，站点改版规则就会失效，表现为「播放器内部错误」。可以换个数据源试试。
- 只在少数机型上测过，兼容性未知。
- 界面在横屏与平板上的适配不完整。

## 反馈

遇到问题或有建议：**zero100610@gmail.com**

## 自行构建

```bash
flutter --version   # 需要 Flutter 3.47.0
flutter pub get
flutter build apk --release
```

产物位于 `build/app/outputs/flutter-apk/app-release.apk`。

> 弹幕与原版 Kazumi 自建 mirror 需要密钥（`DANDANAPI_APPID` / `DANDANAPI_KEY` / `KAZUMI_APPID` / `KAZUMI_KEY`），
> 由原项目 CI 通过 `--dart-define` 注入。自行构建拿不到这些密钥，因此弹幕不可用；
> 搜索与番剧数据已改走公共反代，不受影响。

## 致谢

- 原项目 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 及其所有贡献者
- 内测用户 **@灯塔上的雾**
- 赞助商 **@小圆猪**

## 开源声明

本项目基于 [Kazumi](https://github.com/Predidit/Kazumi) 修改，遵循原项目的开源许可证（见 [LICENSE](LICENSE)）发布，**不用于商业用途**。原项目版权归原作者所有。

番剧数据来自 [Bangumi 番组计划](https://bangumi.tv/)，播放源由用户自行配置的采集规则提供。本项目不存储、不分发任何影视内容，所有内容均来自用户自行添加的第三方站点。请在下载后 24 小时内删除，勿用于任何商业用途。
