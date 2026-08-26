# 方案构思:封面海报自定义与跳转

> 状态:**仅构思,本期不实施**。本文档描述后续版本如何让首页顶部 5 张 16:9 海报图可由你随时更新,并自定义每张图的点击跳转目标。

## 一、现状与目标

**现状**(`lib/request/config/hero_banners.dart`):

- `kHeroBanners` 是**编译期常量**:5 张内置图(assets/images/hero/*.jpg) + 标题 + Bangumi subjectId,顺序固定。
- 点击行为固定:跳转 `/info/<subjectId>` 番剧详情页。
- 想换图/换跳转必须改代码重新出包。

**目标**:

- 海报的**图片与跳转目标**改为远端 JSON 配置,改文件即生效,无需发版。
- 配置不可达时自动回落到内置默认(保持现在的开箱体验)。
- 支持你随时增删海报(建议 3-6 张,轮播组件自适应)。

## 二、配置源设计(hero.json)

与公告系统同一套静态托管思路(单 JSON + jsDelivr/raw 双源),两个系统可共用一个仓库甚至一个文件的不同字段。

```json
{
  "banners": [
    {
      "id": "jianlai",
      "image": "https://example.com/banners/jianlai-1280x720.jpg",
      "title": "剑来",
      "action": { "type": "bangumi", "subjectId": 345825 }
    },
    {
      "id": "newyear-activity",
      "image": "https://example.com/banners/activity.jpg",
      "title": "春节活动",
      "action": { "type": "route", "value": "/tab/popular/" }
    },
    {
      "id": "external",
      "image": "https://example.com/banners/partner.jpg",
      "title": "合作页",
      "action": { "type": "url", "value": "https://example.com/xxx" }
    }
  ]
}
```

跳转类型(`action.type`)按优先级支持:

| type | 行为 | 典型场景 |
|---|---|---|
| `bangumi` | `context.pushNamed('/info/<subjectId>')`,与现状一致 | 常规番剧推荐位(点图看某部动漫) |
| `route` | 应用内任意命名路由 | 跳活动聚合页/分类页 |
| `url` | `url_launcher` 外部浏览器打开 | 外部合作页/问卷 |
| `none` | 只展示不跳转 | 纯视觉氛围图 |

## 三、客户端改造点

### 3.1 数据层

- `lib/request/config/hero_banners.dart` 保留为**默认回落配置**(改名为 `kDefaultHeroBanners`)。
- 新增 `lib/services/hero_banner/hero_banner_service.dart`:
  - 启动时异步拉取 `hero.json`(jsDelivr → raw 回退,15 分钟缓存,失败静默回落默认)。
  - 输出一个 `ValueNotifier<List<HeroBannerConfig>>` 给推荐页消费。
  - 单条校验:`image` 可达性不预检(展示时 cached_network_image 自带失败占位),但 `type=bangumi` 时 `subjectId` 必须为正整数,否则该条丢弃。
- 模型上**新增字段与默认值**:`HeroBannerConfig.fromRemote(json)` / `.builtin(HeroBanner)` 两个工厂,内置条目转换为 `action.type=bangumi`。

### 3.2 UI 层

- `lib/bean/card/bangumi_hero_carousel.dart`(轮播组件)改动最小化:
  - 数据源从 `kHeroBanners` 改为 listen 上述 ValueNotifier;轮播数量 1-N 自适应(组件本身支持任意长度,只是常量写死了 5)。
  - 点击回调从写死的 `pushNamed('/info/$subjectId')` 改为按 `action.type` 分发。
  - 图片加载失败占位:现有 `NetworkImgLayer` 已具备,复用即可。
- **图片规格约定**:与现有内置图一致,1280×720 JPEG(≤300KB),避免轮播首帧内存压力。

### 3.3 预留编辑能力(可选,二期)

远端 JSON 已解决"随时更新";若还想在手机上直接改(不上传文件),二期可在 `设置 → 界面设置` 里加"自定义封面"入口:
- 从相册选图(复用 `image_picker`,已是依赖) → 本地存储 → 写入本地覆盖层,本地优先级高于远端。
- 该能力纯本地,不影响他人。

## 四、你以后的日常操作

1. 制作 1280×720 海报图,上传到图床/GitHub 仓库。
2. 修改 `hero.json` 的 `banners` 数组(换图/换 subjectId/增删条目)。
3. push 后 1-5 分钟生效,用户冷启动或 15 分钟缓存过期后看到新海报。

**换一张海报图的全部成本 = 上传图片 + 改 5 行 JSON。**

## 五、风险与对策

| 风险 | 对策 |
|---|---|
| 远端配置拉不下来 | 回落内置 `kDefaultHeroBanners`,行为与现在完全一致 |
| 图片 URL 失效/被防盗链 | cached_network_image 失败占位 + 图片床建议用 GitHub raw/jsDelivr(与公告图同床) |
| 恶意 JSON | 单条 try-catch 跳过 + 条数上限(≤10)防御 |
| 用户觉得海报变了很奇怪 | 首版可以在海报角落加极小的"活动"角标,标记非常规推荐位 |

## 六、实施工作量预估

- 客户端:约 250-350 行(服务类 + 模型 + 轮播组件改造),无新依赖
- 测试:模型解析/回落逻辑单测约 80 行;轮播 widget 测试改造现有 golden
- 预计 0.5-1 个开发日
