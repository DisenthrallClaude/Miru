# v1.7.0 播放性能专项 — 工程交付文档

> 工单目标：**用户随便点一部动漫、随便点一集，都能快速出画面。**
> 范围：`lib/` + `test/` + `cloudflare-worker/`；不重做 UI 视觉、不删现有功能。
> 规模：52 个文件，+5442 / −809 行；P0×9 + P1×13 + P2×18 + §5 埋点，全部落地。

---

## 1. 验收 KPI 与达成路径

| 场景 | 验收线 | 达成手段（对应修复点） |
|---|---|---|
| 同集二刷首帧 | ≤ 1.0s | 缓存命中 + `verified` 门控免探测（P0-4）+ 预连接（P1-5）+ 起播瘦身（P1-4） |
| 静态站首播 | ≤ 2.5s | 快解层正则收紧（P2-1~3）+ Cookie 透传（P0-8）+ 层级记忆命中即先试快解（P1-3） |
| JS 站首播 | P50 ≤ 6s / P90 ≤ 10s | WebView 池常驻（P1-1）+ 失败即晋级（P1-3）+ 嗅探打分选优（P1-13）+ 去阻塞（P1-2） |
| 换下一集 | ≤ 1.2s | 解析单飞（P1-6）+ buffer≥20s 预解析（P1-12）+ softStop 世代号（P0-2） |
| 自动连播后 | 进度/历史/弹幕正常 | 定时器复活 + completed 流事件驱动（P0-1） |
| 全线路失败 | ≤ 1s 出错误页 | 选集 12s 超时可取消（P0-9）+ 熔断名额修正（P2）+ 波次失败即晋级（P1-3） |

真实数值以 **设置 → 诊断 → 播放诊断** 的 P50/P90 实测为准（§5 埋点）。

## 2. 解析链架构（v1.7.0 后）

四级对冲竞速，波次固定延迟 0 / 600 / 1500ms，任一层胜出即短路其余：

```
点按选集
  │
  ├─ L1 本地缓存（ResolutionResultCache，verified+fresh 才免探测直用）
  ├─ L2 快解层（FastVideoSourceResolver，正则提取直链，携带插件 Cookie）
  ├─ L3 云端 Worker（miru-resolver，host 白名单 + HMAC 防滥用）
  └─ L4 无头 WebView 嗅探（WebViewPool 常驻池，JS PerformanceObserver 打分选优）
  │
  ▼
本地媒体代理（LocalMediaProxy，边播边缓存，HLS 清单截断防御）
  │
  ▼
mpv（media_kit）— demuxer-lavf-o 按格式分离，HLS 与 MP4 直链各得其所
```

调度策略：**失败即晋级**（不等满波次延迟）+ **LevelWinMemory**（per-host 胜出层级记忆，Hive 持久化，TTL 7 天——上次哪层赢，这次先试哪层）。

## 3. 修复点明细

### 3.1 P0（正确性致命，9 项）

| # | 问题 | 根因 | 修复 | 主要文件 | 测试 |
|---|---|---|---|---|---|
| P0-1 | 自动连播后进度冻结/历史不写/弹幕停/连播断链 | v1.6.7 起 PlayerItem 常驻挂载，initState 不再执行，`playerTimer.cancel()` 后无人重建 | `_autoNextInFlight` 防重入 + `player.stream.completed` 事件订阅 + roadList 边界检查 | `lib/pages/player/player_item.dart` | `player_playback_signals_test.dart` |
| P0-2 | 换集/初始化双发 softStop 竞态→有声黑屏/遮罩永转 | 第一次 softStop 尾部清状态落在 openMedia 之后 | 单飞复用 + `_openMediaGeneration` 世代号守卫，每个 await 后校验 | `video_controller.dart` / `player_controller.dart` / `player_playback_controller.dart` | `player_playback_signals_test.dart` |
| P0-3 | 长集只播一部分/被当直播 | `_readAll` 64KB 截断的 m3u8 被当完整清单 seed 给代理 | truncated 标志 + `#EXT-X-ENDLIST` 校验，截断即弃 | `hybrid_video_source_service.dart` / `local_media_proxy.dart` | `hybrid_hls_truncation_test.dart` |
| P0-4 | 首播打开 HTML，「播放器初始化失败」 | 预取写未验证候选，新鲜即免探测直用 | 免探测条件改 `!force && entry.verified && isFresh`；缓存命中也并行轻探测 | `hybrid_video_source_service.dart` | `resolution_result_cache_test.dart` |
| P0-5 | MP4 直链无法 seek/续播失效 | `http_seekable=0` 全局下发 | `demuxer-lavf-o` 按格式分离，仅 HLS 带 `http_seekable=0` | `player_playback_controller.dart` | `player_mpv_params_contract_test.dart` |
| P0-6 | CF 重验证后 403 换源循环 | 缓存持久化 cookie 且解析层头覆盖插件实时值 | put() 只留 referer/origin + `mergePlaybackHeaders` 纯函数（referer 解析层优先、cookie 插件实时优先） | `resolution_result_cache.dart` / `lib/utils/http_headers.dart` | `http_headers_merge_test.dart` |
| P0-7 | 严格 CDN 拒绝（间歇性） | 嗅探 headers 遍历顺序不定，Origin 覆盖 Referer | Origin/Referer 分开收集、分开上报 | `video_webview_android_impl.dart` | `hybrid_playback_headers_test.dart` |
| P0-8 | CF 类站点快解必败，白等 1.5s | 快解层不带插件 cookie | `resolveCandidates` 增 `extraHeaders` 透传 | `fast_video_source_resolver.dart` | `fast_resolver_cookie_test.dart` |
| P0-9 | 源站挂起用户被困 | queryChapterRoads 无超时 + loading 不可取消 | `.timeout(12s)` + 可取消 | `lib/pages/info/source_sheet.dart` | —（UI 层，e2e 范畴） |

### 3.2 P1（性能与体验，13 项）

| # | 内容 | 主要文件 | 测试 |
|---|---|---|---|
| P1-1 | WebViewPool 进程级常驻预热，替代每页冷启动 Chromium | `lib/services/video_source/webview_pool.dart`（新） | `resolve_session_test.dart` |
| P1-2 | `useShouldInterceptRequest:false` 默认 + JS `PerformanceObserver(resource)` 嗅探（不再同步阻塞 WebView IO 线程）+ per-host 开关 | `video_webview_android_impl.dart` | `webview_sniff_scoring_test.dart` |
| P1-3 | 竞速「失败即晋级」+ LevelWinMemory（Hive，TTL 7 天）+ 竞速后 abort 快解请求 | `resolve_session.dart` / `level_win_memory.dart`（新） | `level_win_memory_test.dart` / `resolve_session_test.dart` |
| P1-4 | 起播关键路径瘦身 | `player_playback_controller.dart` | `player_mpv_params_contract_test.dart` |
| P1-5 | 投机解析（进详情页即预热当前集）+ 预连接 + 微任务级起播 | `info_page.dart` / `video_controller.dart` | `speculative_prefetch_contract_test.dart` |
| P1-6 | 解析单飞（同集连点只发一次） | `hybrid_video_source_service.dart` | `resolve_session_test.dart` |
| P1-7 | `extractCandidatesFromHtml` 顶层纯函数 + `Isolate.run` 卸载重正则 | `fast_video_source_resolver.dart` | `ui_isolate_offload_contract_test.dart` |
| P1-8 | `webviewLogLines` 改 ValueNotifier 增量刷新，去整页 setState | `video_page.dart` / `playback_mask_logic.dart` | `ui_isolate_offload_contract_test.dart` |
| P1-9 | 进度直订 `stream.position` | `player_item.dart` | `player_playback_signals_test.dart` |
| P1-10 | 分级缓冲：计量网络 32MB + 8MB 回看 | `playback_cache_policy.dart` | `metered_network_service_test.dart` |
| P1-11 | 健康探测让位首播（延后 5s、并发降 2、`_probing` 改 Set、recordOutcome 真实反馈） | `road_health.dart` | `road_health_test.dart` |
| P1-12 | 下一集预解析改 hasVideoParams + buffer≥20s 触发 | `video_controller.dart` | `speculative_prefetch_contract_test.dart` |
| P1-13 | 嗅探 400ms 收集窗口打分选候选（非先到先得） | `video_webview_android_impl.dart` | `webview_sniff_scoring_test.dart` |

### 3.3 P2（健壮性，18 项）

核心条目：

- **P2-1~3** 快解层正则与 URL 判定收紧（.m3u8/.mp4 后缀、query 提参、排除内嵌播放器页误报）— `fast_video_source_resolver.dart`
- **P2-5~8** 缓存四修复：`.tmp+rename` 原子写 / putNegative 过期条目允许覆写 / WebView 结果不探测不写缓存 / TTL 治理 — `resolution_result_cache.dart`
- **P2-9** 本地代理接受 2xx 全家（201/206 等）— `local_media_proxy.dart`
- **P2-13** `_switchToFallbackSource` 失败候选不占线路熔断名额 — `player_playback_controller.dart`
- **P2-14** `network_security_config.xml` 精确放行替代全局 `cleartext` — `android/app/src/main/res/xml/`（配合 `AndroidManifest.xml`）
- **P2-16** `VideoWebviewController` 增 `onPageFinished` Stream — `video_webview_controller.dart`
- 其余条目（边界检查、空安全、异常吞没治理等）以 `robustness_p2_contract_test.dart` 契约锁定。

### 3.4 Worker 安全加固（cloudflare-worker/miru-resolver）

- `ALLOWED_HOSTS` 白名单：仅已知动漫源站域名可解析；
- HMAC 签名校验：防第三方白嫖 Worker 当开放抓取器；
- KV 写入带 `expirationTtl`：不留永久垃圾；
- 已通过 wrangler 部署上线。

### 3.5 规则

- 新增内置规则 **LMM**（`assets/plugins/LMM.json`，31 行）；
- 14+1 条内置规则全量离线校验（搜索→选集→线路结构断言）— `test/bundled_rules_offline_test.dart`，进 CI 门禁。

## 4. 可观测性（§5 埋点）

`lib/services/player/playback_timeline.dart`（262 行）：

- **分段**：tTap → tResolveStart → tWinner（+胜出层级/host）→ tOpen → tFirstFrame → tFirstBufferEnd，失败记录原因；
- **存储**：内存环形缓冲最近 50 条，纯本地不上报不落盘；
- **查看**：设置 → 诊断 → 播放诊断（`player_settings.dart`）——「点按→首帧」P50/P90 + 样本数 + 每条可展开分段耗时；
- **回写联动**：胜出层级回写 LevelWinMemory、RoadHealthTracker 拿到真实探测反馈。

## 5. 验证结果

| 项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found**（零 error 零 warning） |
| `flutter test --exclude-tags=live` | **452 项全部通过** |
| 新增专项测试 | 11 个文件（时间线、mpv 参数契约、嗅探打分、层级记忆、Cookie 透传、头合并、截断防御、P2 契约、UI isolate 卸载、投机预取、离线规则校验） |
| live 实测 | 按工单豁免（构建环境 IP 被 Cloudflare 拦截，真机不受影响） |

## 6. 真机验收指引

1. 装包后随便进一部番 → 点第一集 → 记录首帧时间；
2. 退出重进同集（二刷）→ 首帧应明显缩短（缓存直用）；
3. 播到片尾触发自动连播 → 确认进度条走动、历史记录写入、弹幕正常；
4. 手动点下一集 → 应在 1~2s 内起播；
5. 设置 → 诊断 → 播放诊断 → 看 P50/P90 是否落在验收线内；
6. 断网/源站挂掉 → 确认 1s 级出错误页而非无限转圈。

## 7. 提交记录（11 个 commit）

```
a712542 v1.7.0 步骤9: 内置规则+1(LMM) + 离线规则校验测试
121c6a2 v1.7.0 步骤8补充: 移除误提交的worker测试临时产物
222808d v1.7.0 步骤8: P2全量健壮性条目 + Worker安全加固并部署上线
08c596d v1.7.0 步骤7补充: 修正P1-8契约测试的setState匹配
8f56585 v1.7.0 步骤7: P1-7重解析移出UI isolate + P1-8播放页日志去整页setState
522484a v1.7.0 步骤6: P0-9选集超时可取消 + P1-5投机解析 + P1-11/12
c6690f9 v1.7.0 步骤5: P1-3竞速失败即晋级+层级记忆 + P1-6单飞 + P1-1 WebView池
2978b8f v1.7.0 步骤4: P0-7 Origin/Referer分离 + P0-8快解Cookie + P1-2/13
f375e96 v1.7.0 步骤3: P0-5撤销http_seekable=0 + P1-4/9/10
07ec0dc v1.7.0 步骤2: P0-1自动连播定时器复活 + P0-2 softStop单飞世代号
d2d215d v1.7.0 步骤1: §5埋点+诊断页 + P0-3/4/6 + P2-5~8
（+ 步骤10 本文档与 README changelog、版本号 1.7.0+10700）
```
