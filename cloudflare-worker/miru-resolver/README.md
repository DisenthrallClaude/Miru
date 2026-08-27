# Miru 云端解析层（Cloudflare Workers + KV）部署说明

## 这是什么

把「播放页 URL → 视频直链」的解析从手机端 WebView 嗅探（5~30 秒）搬到
Cloudflare 边缘节点（1~3 秒），KV 短期缓存让热门内容的解析低至毫秒级。
**Worker 挂掉或解析失败时，APP 会自动降级回本地 WebView 解析，不影响可播放性。**

免费额度完全够个人使用：Workers 免费版每天 10 万次请求，KV 免费版每天
10 万次读 + 1000 次写，Miru 每次播放最多消耗 1 读 + 1 写。

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
