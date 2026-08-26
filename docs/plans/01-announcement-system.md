# 方案构思:公告与活动弹窗系统

> 状态:**仅构思,本期不实施**。本文档描述后续版本如何在 APP 中自由发布公告与活动(弹窗形式),并支持随时更新内容与开关。

## 一、目标与场景

- **发布者(你自己)**:无需发版,即可向全体用户推送公告(版本说明、站点失效通知)或运营活动(新番上线、节假日活动),可随时更新、随时下线。
- **用户**:打开 APP 时看到弹窗,可关闭、可"不再提示",不打扰不愿看的用户。
- **非目标**:不做推送(需要接入厂商推送通道,复杂且需要审核);不做定向人群;本期只做"启动弹窗 + 手动刷新"。

## 二、总体架构

```
┌─────────────┐   HTTPS (带缓存与超时)   ┌──────────────────┐
│  远端公告源   │ ─────────────────────> │  APP 内 AnnouncementService │
│ (单个 JSON)  │                        │  拉取/缓存/去重/展示判定      │
└─────────────┘                        └────────┬─────────┘
                                                │ 命中需要展示的公告
                                                v
                                       ┌──────────────────┐
                                       │ AnnouncementDialog│
                                       │ 图片/富文本 + 按钮组 │
                                       └──────────────────┘
```

核心决策:**单个 JSON 文件即全部后端**。公告源就是一个放在任意静态托管(GitHub Pages / jsDelivr / 自己的服务器)上的 `announcement.json`,与现在规则仓库的托管方式完全同构,零服务器成本,零运维。

## 三、公告源数据结构(announcement.json)

```json
{
  "announcements": [
    {
      "id": "2026-08-newyear",
      "enabled": true,
      "priority": 10,
      "title": "春节活动上线",
      "coverImage": "https://example.com/newyear.jpg",
      "body": "支持 Markdown 的正文...",
      "bodyType": "markdown",
      "actions": [
        { "label": "去看看", "type": "route", "value": "/tab/popular/" },
        { "label": "复制链接", "type": "clipboard", "value": "https://..." }
      ],
      "minAppVersion": "1.1.0",
      "maxAppVersion": "",
      "startAt": "2026-02-10T00:00:00+08:00",
      "endAt": "2026-02-25T23:59:59+08:00",
      "showFrequency": "once",
      "dismissible": true
    }
  ]
}
```

字段说明(判定逻辑在客户端执行,服务端只给数据):

| 字段 | 作用 |
|---|---|
| `enabled` | 总开关:改一个字段即可整体下线,立即生效(下次拉取后) |
| `priority` | 多条命中时只展示优先级最高的一条,避免弹窗轰炸 |
| `minAppVersion/maxAppVersion` | 版本区间过滤,老版本不弹不兼容的活动 |
| `startAt/endAt` | 活动有效期,过期自动消失,无需手动下线 |
| `showFrequency` | `once`(看过一次不再弹)/ `everyLaunch`(每次启动)/ `daily`(每天一次) |
| `actions[].type` | `route`(应用内跳转)/`url`(外部浏览器)/`clipboard`(复制口令) |

## 四、客户端模块设计

### 4.1 新增文件与职责

- `lib/services/announcement/announcement_service.dart`
  - `fetchAndMaybeShow(BuildContext)`:启动后延迟 2 秒调用(避开首帧卡顿)。
  - 拉取策略:本地缓存 15 分钟;缓存过期才请求网络;网络失败用上次缓存兜底,**绝不在启动路径上阻塞**。
  - 展示判定链:enabled → 版本区间 → 时间窗 → 频控(读 Hive) → 取 priority 最高者。
- `lib/services/announcement/announcement_models.dart`:上述 JSON 的数据类 + `fromJson` 容错(单条损坏跳过,参考 `PluginCatalogApi.parsePluginList` 的既有模式)。
- `lib/pages/announcement/announcement_dialog.dart`:弹窗 UI,复用现有 `FrostedSurface` 玻璃语言;封面图 16:9 用 `cached_network_image`,正文 Markdown 用 `flutter_markdown`(需新增依赖)。
- 存储键(Hive `setting` box):`lastAnnouncementShownAt:<id>` 记录频控状态。

### 4.2 托管地址与镜像

- 主源:`https://raw.githubusercontent.com/<你的仓库>/announcements/main/announcement.json`
- 镜像:`https://fastly.jsdelivr.net/gh/<你的仓库>@main/announcement.json`
- 客户端按"jsDelivr 优先 → raw 兜底"逐级回退,与 `CommunityRulesSync._mirrors` 的既有模式完全一致(可参考其实现)。
- 常量落在 `lib/request/config/api_endpoints.dart`(与 `pluginShop` 并列)。

### 4.3 交互细节

- 弹窗只出现在**主界面就绪后**(首帧渲染完成 + 2s 延迟),绝不打断引导流程(Onboarding 期间不弹)。
- 弹窗期间用户按返回 = 关闭,不退出应用(PopScope 处理)。
- "今日不再提示"选项 = `showFrequency: daily` 的用户侧加强;隐藏入口 `我的 → 关于 → 公告记录` 可回看历史公告(本期可不做,预留 id 列表存储即可)。

## 五、发布操作流程(你以后的日常)

1. 改 `announcement.json`(新建条目或把 `enabled` 置 false 下线)。
2. push 到 GitHub,jsDelivr 1-5 分钟内生效,raw 立即生效。
3. 用户侧最长 15 分钟缓存 + 下次冷启动后可见。

**发布新活动约 1 分钟,全程不需要重新打包发版。**

## 六、风险与对策

| 风险 | 对策 |
|---|---|
| 公告图片加载慢/失败 | 图片容器给固定高度 + loading 占位(骨架屏),失败显示标题文字版 |
| 恶意/错误 JSON 导致崩溃 | 单条 try-catch 跳过(规则目录同款容错),整体解析失败则静默放弃本次展示 |
| 弹窗打扰用户 | 默认 `once` 频控 + 全局"关闭公告弹窗"开关(设置 → 界面设置) |
| 托管被墙 | jsDelivr + raw 双源回退,与规则仓库同架构,已被验证可行 |

## 七、实施工作量预估

- 服务端:0(纯静态 JSON)
- 客户端:约 400-500 行 Dart + 1 个新依赖(flutter_markdown)
- 测试:announcement_models 解析单测 + 展示判定单测(频控/版本/时间窗),约 150 行
- 预计 1 个开发日完成
