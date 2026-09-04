# 05 · 播放链路全面升级（v1.6.0）

> 目标：**秒开、稳开、换集秒切**。点线路→首帧 P50 ≤ 1.5s / P95 ≤ 6s；
> 换集 P50 ≤ 0.8s；失败弹窗率降 60%；任何路径硬上限 12s。

## 总览

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 止血：fast 多候选解析、正向探测语义、负缓存分级、WebView 强化、共享 HttpClient、mpv 起播参数 | ✅ v1.5.4-dev 随 1.6.0 发布 |
| 1 | 单例播放器 + 代理可靠化：ensurePlayer/softStop、sha1 token、seedManifest、滑窗预取、事件流 | ✅ 同上 |
| 2 | 对冲竞速：波次调度（0ms/600ms/1500ms）、并发 3 验证、12s 硬上限、签名感知 TTL | ✅ v1.6.0 |
| 3 | 线路健康探测、徽标、自动选路、下一集预取（v1.5.3 已带缓冲退避） | ✅ v1.6.0 |
| 4 | 网络底座（Cronet/DNS 预热/反代竞速） | ⏸ 部分跳过（见下） |

## 阶段 0 · 止血（要点）

- `fast_video_source_resolver.dart`：播放页一次 GET 提取 ≤4 个候选
  （直链/解析器二跳 `/static/player/{from}.js`/内联/iframe），
  `thirdPartyParserHints` 识别第三方解析器不再误当直链；
  广告 URL 去噪。
- `hybrid_video_source_service.dart` 探测改**正向确认**：alive 必须有
  内容证据（#EXTM3U / ftyp / 0x47 / FLV / EBML），dead = 4xx 或
  HTML 伪装页；清单文本交 `LocalMediaProxy.seedManifest()`。
- 负缓存分级：extractFailed → host 级 10min；network → 不写；
  probeDead → URL 级 5min；`force` 重试忽略全部记忆。
- `cloud_video_source_resolver.dart` 超时 4s→2.5s + 健康持久化。
- WebView（`video_webview_android_impl.dart`）：cacheEnabled、
  mediaPlaybackRequiresUserGesture=false、双脚本一次注入、
  网络层嗅探（onLoadResource/shouldInterceptRequest）、
  ContentBlocker 屏蔽广告/图片/字体、嗅探成功即关停。
- 新增 `shared_http_client.dart`：全局单例 HttpClient
  （maxConnectionsPerHost=6），全部解析/探测/代理复用。
- mpv（`player_playback_controller.dart`）：`demuxer-lavf-o`
  分片级重试重连组、`network-timeout=8`、起播 cache-secs=10 →
  首帧稳定后提升 120（`_promoteBufferingAfterStable`）。

## 阶段 1 · 单例播放器 + 代理可靠化（要点）

- `ensurePlayer()`（幂等）+ `openMedia()`（每集）拆分：换集不再销毁
  重建 mpv 实例（省 300~900ms 黑屏）；`softStop()` 停流不销毁。
- `LocalMediaProxy`：token 升级 sha1 前 10 字节（80bit，FNV32 碰撞
  不可再用）；缓存目录迁 `getApplicationSupportDirectory()`（系统
  磁盘清理杀手不再误杀）；`seedManifest`（探测文本复用）；
  **滑窗预取**（领先播放头 4 片、并发 3、退避 200/600/1500ms）；
  事件流 `events`（segmentOk/segmentFail/upstream4xx/upstream5xx/
  timeout）供播放层精确决策——4xx 换候选、timeout 原地重开。

## 阶段 2 · 对冲竞速（v1.6.0 新增）

新增 `resolve_session.dart`：

- `ResolveSession<T>`：波次竞速协调器。t=0 fast、t=600ms cloud、
  t=1500ms webview；首个产出者胜出，其余波次不再启动；层级故障
  不终止竞速；**12s 硬上限**抛 `TimeoutException` 交上层兜底换源；
  `cancel()` 响应用户换集退出。
- `ResolveTrace`：环形日志（500 条，时间相对毫秒 + 阶段 + 事件），
  每波次启动/放弃/胜出全记录，逐条透传 MiruLogger。
- `ttlFor(url)`：从 exp/expire/expires/e 提取签名剩余寿命，
  clamp 1min~6h——带签名直链的缓存条目按真实寿命过期。

`hybrid_video_source_service.dart` 串行漏斗 → 竞速：

- 第 2/3/4 级重构为 `_runFastLevel/_runCloudLevel/_runWebViewLevel`
  三个波次任务，负缓存/短窗失败记忆语义原样保留；
- fast 层候选探测改**并发 3 取首个 alive**（原串行最坏 4×1.5s=6s
  → ~1.5s）；`ResolutionResultCache.put` 支持签名感知
  `positiveTtl`（`pt` 字段，旧缓存向后兼容）；
- `cancel()` 联动：先取消竞速会话（上层 await 立即结束）再停
  WebView。

## 阶段 3 · 线路健康 + 自动选路（v1.6.0 新增）

新增 `road_health.dart`（`RoadHealthTracker` 单例）：

- `probeAll()`：页面级可达性探测（线路第 1 集 URL，2xx/3xx = ok），
  并发 4、单条 3s、总预算 4s；结果 JSON 持久化
  （`road_health.json`，10min TTL，原子写）；
- `bestRoadIndex()`：健康分选路（存活 > 延迟），无数据回退默认；
- 二次进页新鲜期内**零重复探测**（不打扰源站）。

`video_page.dart` 集成：

- 进页后台 fire-and-forget 探测，永不阻塞首播；
- 线路菜单每项显示健康徽标（⚡+ms 绿/琥珀，☁ 红 = 死线；
  未知不显示——不猜疑未探测的线路）；
- 无播放历史时自动选健康最优线路（有历史尊重历史）；
- 下一集预解析（v1.5.3 已有：8s 后发起、缓冲中顺延三轮）。

## 阶段 4 取舍说明

- ✅ Bangumi 图片 `lain.bgm.tv` 优先 / `wsrv.nl` 回退（此前版本已带）；
- ✅ 连接复用由 `SharedHttpClient` 覆盖（阶段 0）；
- ⏸ **Cronet 跳过**：原生依赖体积与构建风险相对收益不成比例
  （核心痛点已由共享连接池解决），待真实弱网数据证明必要时再评估。

## 测试

- `test/stage0_stopbleed_test.dart`（阶段 0 全量）
- `test/p1_parse_test.dart`（阶段 1 解析）
- `test/resolve_session_test.dart`（阶段 2：波次/硬上限/cancel/
  异常容错/ttlFor，13 用例）
- `test/road_health_test.dart`（阶段 3：健康分/选路/回环探测/
  持久化/防重复，5 用例）
- 全量 248 passed / 0 failed，`flutter analyze` 零问题。
