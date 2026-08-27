# Miru 云端解析层（Cloudflare Workers + KV）部署说明

## 这是什么

把「播放页 URL → 视频直链」的解析从手机端 WebView 嗅探（5~30 秒）搬到
Cloudflare 边缘节点（1~2 秒），KV 短期缓存让热门内容的解析低至毫秒级。
**Worker 挂掉或解析失败时，APP 会自动降级回本地 WebView 解析，不影响可播放性。**

## 官方端点（v1.5.1 起内置，无需自建）

App 从 v1.5.1 起**默认启用官方解析端点**（项目方维护，免费额度运行）：

```
https://miru-resolver.3127467219.workers.dev
```

不需要做任何事——装完 App 即享 1~2 秒云端解析。本目录的代码就是官方
端点部署的那份；自建一套属于自己的解析层时才需要按下文步骤部署，
然后在「设置 → 播放 → 播放加速 → 自建 Worker 地址」填入你的地址。

官方端点内置**匿名用户统计与动态配额**（应对免费额度）：

- APP 每天发一次匿名心跳（随机 16 位 ID，无任何个人信息）；
- Worker 按当日活跃人数把每日解析预算均摊成每用户配额（默认
  预算 4000 次/天，单人下限 30 次、上限 800 次）；
- 不活跃的用户不占额度；配额用尽返回 429，APP 自动降级本地解析，
  **任何情况下都能播**；
- 访问 `/stats` 可随时查看当日活跃人数与用量。

免费额度也做了写放大治理：KV 写入只在「同一边缘节点第二次被请求」的
热门内容上发生，用户计数器每 25 次落盘一次——远低于免费版每天
1000 次写的限额。

## 部署步骤（约 5 分钟）

### 1. 注册 / 登录 Cloudflare

打开 https://dash.cloudflare.com/sign-up （免费套餐即可）。

### 2. 安装 wrangler 命令行（本机有 Node.js 即可）

```bash
npm install -g wrangler
wrangler login      # 会弹浏览器授权
```

### 3. 创建 KV 命名空间

在本目录（`cloudflare-worker/miru-resolver/`）执行：

```bash
wrangler kv namespace create RESOLVE_CACHE
```

输出形如：

```
[[kv_namespaces]]
binding = "RESOLVE_CACHE"
id = "abcd1234xxxx..."
```

把其中的 `id` 填进 `wrangler.toml`，替换
`REPLACE_WITH_YOUR_KV_NAMESPACE_ID`。

### 4. 部署

```bash
wrangler deploy
```

部署成功后输出类似：

```
Published miru-resolver (x.xx sec)
  https://miru-resolver.<你的子域>.workers.dev
```

### 5. 验证

```bash
# 健康检查
curl 'https://miru-resolver.<你的子域>.workers.dev/health'
# 期望: {"ok":true,"service":"miru-resolver",...}

# 实测一条播放页（换成任意源的任意一集播放页 URL）
curl 'https://miru-resolver.<你的子域>.workers.dev/resolve?url=<encoded播放页URL>'
# 期望: {"ok":true,"videoUrl":"https://....m3u8","format":"hls","source":"remote",...}
```

### 6. 填进 APP

打开 Miru → 设置 → 播放 → **云端解析加速**：

- 打开开关；
- Worker 地址填 `https://miru-resolver.<你的子域>.workers.dev`（不带末尾斜杠）；
- 点「测试连接」，提示可用即生效。

生效后解析优先级：**本地解析缓存 → 云端 Worker → 本地 WebView 嗅探**。

## 常用配置（wrangler.toml [vars]）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CACHE_TTL_SECONDS` | `2700` | KV 缓存时长（秒）。视频直链多带时效签名，不建议超过 3600 |
| `MAX_CACHE_ENTRIES` | `500` | LRU 上限，超出淘汰最久未用条目 |
| `ALLOWED_ORIGINS` | `*` | CORS 允许来源，`*` 即全放行 |

## 解析失败怎么办

- 返回 `{"ok":false,...}` 即失败，APP 端自动降级本地解析，无需处理；
- 源站把播放页藏得很深（JS 运行时拼接、多层加密 iframe）时 Worker 可能
  提取不到，这类源会一直走本地解析，属预期行为；
- 查日志：`wrangler tail` 实时查看请求与错误。
