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

**只提供 Android 版本。** 本仓库已移除 iOS、Web、Windows、Linux、macOS 等其他平台的源码与构建配置，仅保留 Android 相关的内容，不再提供其他平台的构建。

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

1. 到 [Releases](https://github.com/DisenthrallClaude/Miru/releases/latest) 下载 APK（直链：[Miru-1.2.0-android-arm64-release.apk](https://github.com/DisenthrallClaude/Miru/releases/download/v1.2.0/Miru-1.2.0-android-arm64-release.apk)），每个版本附 `.sha1` 校验文件
2. 安装（首次需允许「安装未知来源应用」）
3. 首启跟着引导走完，规则会自动装好

**要求 Android 10 及以上，设备为 arm64 架构（2018 年后的主流机型基本都是）。** APK 只包含 `arm64-v8a` 单架构，体积更小；模拟器 / x86 平板不在支持范围内。

## 更新记录

### 1.3.0（本次）

> 安装包：[Releases v1.3.0](https://github.com/DisenthrallClaude/Miru/releases/tag/v1.3.0)
>
> ⚠️ 本版起启用固定发布签名：**从 1.2.0 升级需要先卸载再安装**（仅此一次；收藏与观看历史可先用 GitHub 云同步或 WebDAV 备份）。从 1.3.0 起所有版本永久支持直接覆盖升级。

**新功能：远程公告**

- 启动时自动拉取仓库内的公告配置，以液态玻璃弹窗展示（可带封面图与链接按钮）。
- 支持定时生效/失效、目标版本区间、弹出频率（仅一次/每天/每次）控制；一条公告改一个字段即可上下线，无需发版。
- 公告由仓库根目录的 `announcement.json` 驱动，配套网页版管理后台。

**新功能：搜索联想与个人资料**

- 搜索输入时实时给出 Bangumi 联想（封面缩略图 + 评分 + 上映日期），本地历史前缀匹配零延迟先行；点击建议直接搜索。
- 「我的追番」卡片支持自定义用户名与头像（点击资料行编辑，头像压缩存储在本机）。

**界面：**

- 筛选按钮（搜索页）改为液态玻璃材质，带按压形变回弹。
- 热门页分类选择器（「热门番组 ▾」）改为轻玻璃药丸。
- 修复设置项「点一下只出玻璃效果、再点一下才进入」：按压时不再切换玻璃容器结构，点击一次直接进入。

### 1.2.0

> 安装包：[Releases v1.2.0](https://github.com/DisenthrallClaude/Miru/releases/tag/v1.2.0)

**播放链路强化（对齐上游 Kazumi 最新实现）：**

- 同步上游 `84043d5`：Android 后台时挂起 demuxer 预取，修复「切后台再回来播放卡死」。
- 同步上游 `43e0fe8` 思路：嗅探到 `.m3u8` 时强制 HLS demuxer，避开 mpv 内容深测失误导致的打开失败（Android 上与 Windows 同样受益）。
- 嗅探回调对协议相对地址（`//cdn/...`）补全 `https:`，避免被拒收。
- `decodeVideoSource` 容错：输入含非法百分号编码时不再抛异常炸断整条解析链路。

**界面修复：**

- 修复玻璃效果「要点击一下才显现」：路由转场（渐隐动画）期间 `BackdropFilter` 采样到空白层，转场结束后图层不会自动重新采样。现在在首帧与转场完成后各强制重挂一次玻璃图层，模糊从进页起就稳定可见。

### 1.1.0

- 玻璃亮度 / 页签对比度 / 顶栏高度等界面批量修复；规则精简为国漫优先；新增欧乐影院、淘片动漫两个源；新增 GitHub 登录与云同步（PAT 方案）。

## 已知问题

**本项目仍有大量 bug 和待优化之处，不是成熟产品。** 已知的有：

- **弹幕功能失效**。弹幕依赖弹弹play 的签名密钥，自建包拿不到（上游 Kazumi 的凭据随 CI 闭源注入）。修复路线已梳理（申请自有凭据 / 本地弹幕文件导入），见 `docs/plans/04-danmaku-fix.md`。相关的失败提示已经移除，不再反复打扰。
- **部分番剧播放失败**。播放依赖第三方站点的采集规则，站点改版规则就会失效，表现为「播放器内部错误」。可以换个数据源试试。1.2.0 已对齐上游 Kazumi 的最新播放修复并加固了解析链路，命中率比 1.1.0 高，但站点侧的失效仍无法根治。
- 只在少数机型上测过，兼容性未知。
- 界面在横屏与平板上的适配不完整。

## 常见问题与解决方法

Miru 继承自 [Kazumi](https://github.com/Predidit/Kazumi)，很多麻烦其实来自「规则 / 播放源」这套第三方生态，而不是 App 本身。站点一改版、规则一失效，就会出现「某部番放不了」。遇到时按下面的顺序排查：

### 播放失败 / 提示「播放器内部错误」

1. **多刷新几遍。** 规则和搜索结果大多是动态拉取的，网络抖动或源临时抽风时，多刷几次往往就能恢复。
2. **切换播放源 / 线路。** 同一部番通常有多个播放源（选集页的「播放线路」），这个源打不开就换下一个，命中率会高很多。
3. **更新或重建规则。** 在「规则」页找到对应站点，删除后重新添加，让 App 重新拉取该站点的最新规则。
4. **自己去找规则配置。** 社区维护的规则合集（Kazumi 生态的规则地址）有很多，在 App 里「添加规则」粘贴规则地址即可接入更多播放源。规则装得越多、可用性越高，一个失效就换另一个。

### 搜索 / 推荐 / 时间表打不开

列表数据走 Bangumi 官方 API 的社区反代（见上文「网络」一节）。反代是个人维护的公共资源，可能限流或停服：

- 先多刷新几遍；
- 若长期打不开，去 `lib/request/config/api_endpoints.dart` 换一个反代域名即可。

### 弹幕不显示

弹幕依赖[弹弹play](https://www.dandanplay.com/)的签名密钥，自建包拿不到密钥，因此弹幕功能不可用（详见上文「已知问题」）。

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
