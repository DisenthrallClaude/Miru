# 方案构思:弹幕功能修复

> 状态:**构思完成,待选型后实施**。本文档回答「弹幕为什么坏了」以及三条修复路线的成本与收益。

## 一、根因诊断(已实证)

弹幕链路本身完好:匹配逻辑(`DanmakuApi.getBangumiIDByTitle` 相似度匹配)、分集解析(`getDanDanEpisodesByDanDanBangumiID`)、弹幕渲染(`player_danmaku_controller`)、设置项全套都在。坏的是**第一环:API 鉴权**。

DanDanPlay 开放 API 要求每个客户端有独立的 AppId + Secret,请求头需携带:

```
X-AppId:    <AppId>
X-Timestamp: <Unix秒>
X-Signature: Base64(SHA256(AppId + Timestamp + API路径 + Secret))
```

上游 Kazumi 的凭据通过 CI 注入(`--dart-define=DANDANAPI_APPID/KEY`),闭源保管。Miru 自建包没有这对凭据,`dandanCredentials` 是空字符串 → 每个请求都 401 → 弹幕永远拉不到。**这不是 bug,是上游有意闭源的密钥。**

实测确认:`curl https://api.dandanplay.net/api/v2/search/anime?keyword=斗破苍穹` 无签名时返回 401「unauthorized app」;说明服务端在鉴权层就拒绝了,绕不过去。

## 二、三条修复路线

### 路线 A:申请自己的 DanDanPlay 开发者凭据(正道,推荐)

DanDanPlay 官方开放平台接受第三方客户端注册(联系弹弹play团队/查看其 GitHub 文档 `RegZey/wiki`/api.dandanplay.net 说明)。拿到自己的 AppId/Secret 后:

- 客户端零改动(凭据注入通道已存在:`dandan_credentials.dart` + `--dart-define`)
- 出包命令改为带 `--dart-define=DANDANAPI_APPID=xxx --dart-define=DANDANAPI_KEY=xxx`
- 全部现有弹幕功能立即复活(搜索匹配/分集/弹幕/屏蔽词/时间轴偏移)

**成本**:注册申请周期不可控(可能数天到数周,需人工审核);**收益**:完整体验,长期稳定。
**风险**:申请可能被拒(非活跃项目);凭据一旦打进 APK 就公开了(客户端密钥无法保密,需接受滥用风险——上游 Kazumi 同样如此,其凭据也早已可从发行包中提取)。

### 路线 B:本地弹幕文件导入(零外部依赖,立即可做)

播放器已支持弹幕渲染管线,只差数据源。新增「从本地导入 .xml/.json 弹幕文件」:

- 入口:播放页菜单 →「导入弹幕」→ 文件选择器(`file_picker` 已在依赖树)
- 格式:B 站导出的 XML(`<d p="时间,类型,颜色,...">文本</d>`)与弹弹play JSON
- 解析为现有 `DanmakuEntry` 结构,直接喂给 `playerDanmakuController`
- 额外收益:弹幕可离线、可自校对、可二次加工

**成本**:1 天开发;**收益**:对肯自己找弹幕文件的用户立刻可用;**风险**:普通用户找不到弹幕文件,体验门槛高。

### 路线 C:第三方免鉴权弹幕源(灰色,不推荐)

存在一些公共 B 站弹幕转换接口(输入番剧名/集数返回 B 站弹幕 XML)。法律与稳定性双风险:接口随时失效、弹幕版权归属不明、且把用户流量导给不可控第三方。不建议进入正式版本。

## 三、建议的落地顺序

1. **立即做路线 B**(本地导入):不依赖任何外部审批,下个版本就能上线;
2. **并行申请路线 A**:拿到凭据后出一版带签名的包,弹幕体验一步到位;
3. 路线 C 仅作为个人分支实验,不进主线。

## 四、路线 B 的技术要点(若实施)

- `pubspec.yaml` 确认 `file_picker` 依赖
- 新建 `lib/services/danmaku/danmaku_file_importer.dart`:XML 解析用 `xml` 包或手写正则(上游已有 `danmaku_episode_response` 的 JSON 模式可参考)
- 导入的弹幕挂到当前播放实例(`playerDanmakuController.addDanmaku` 或等价入口),不持久化(会话级),避免污染原匹配管线
- 弹幕设置里的「弹幕来源」枚举增加「本地文件」一项,选择后禁用自动匹配
