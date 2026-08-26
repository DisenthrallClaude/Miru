# 方案构思:GitHub 登录与云同步

> 状态:**仅构思,本期不实施**。本文档如实说明技术边界,并给出可行的实现路径。

## 一、要解决的痛点

APP 删除重装后,**观看历史/追番收藏全部丢失**。期望通过账号体系把数据放到云端,重装后登录同一账号自动同步回来。

**硬性约束(必须遵守)**:

- 入口放在「我的」页面,**全程不强制登录**,不登录也完整可用(只影响云同步能力)。

## 二、技术边界如实告知(先说结论)

**"只输入 GitHub 账号 + 密码、不发验证码、不跳转授权"的直登方式在技术上不存在,任何应用都无法做到。**

这不是实现难度问题,而是 GitHub 官方策略的硬性限制:

- GitHub 自 **2020 年 11 月 13 日**起废弃了 REST API 的账号密码认证(`DELETE /applications/grant` 等密码通道全部关闭);
- 自 **2021 年 8 月 13 日**起,Git 操作的密码认证也被彻底移除;
- 之后全球所有第三方应用访问 GitHub 用户数据只剩两条合法通道:
  1. **OAuth 授权流程**(跳转 GitHub 官网页面,用户点一次"Authorize");
  2. **Personal Access Token(PAT)**(用户自己在 GitHub 网页上生成令牌,粘贴进 APP)。
- 任何声称能"只输账号密码"的第三方实现,本质是**抓取 GitHub 登录页模拟表单提交 + 过人机验证**,这属于违反 GitHub ToS 的爬虫行为,且 2FA/风控随时会使其失效,还存在账号密码被明文经手的严重安全问题,不可用于正式产品。

**决策建议(按用户给定的规则)**:既然纯账号密码直登无法做到——

- 若"跳转 GitHub 点一次授权"或"粘贴 Token"**可以接受** → 按下文第四节实施(推荐 PAT 方案,见对比);
- 若**完全不能接受**任何非密码形式 → 本功能不做。且请注意:**当前版本已有 WebDAV 同步**(设置 → 同步设置),把观看历史与追番收藏同步到任意 WebDAV 网盘(坚果云等),已可解决"重装丢数据"的核心痛点,GitHub 方案只是"免自备网盘"的便利层,并非必需。

## 三、现状盘点(与该痛点相关的既有能力)

| 能力 | 现状 |
|---|---|
| 观看历史本地存储 | Hive `histories` box + 事件日志(`HistorySyncService`,含设备号/序列号/合并语义),已为同步设计 |
| 追番收藏本地存储 | Hive `collectibles` box + 变更队列(`CollectedBangumiChange`) |
| 云同步通道 | **WebDAV**(`webdav_client` 依赖已引入),历史与收藏的完整上传/下载/合并已实现(`设置 → 同步设置`) |
| Bangumi 账号 | 已支持(Bangumi OAuth),用于收藏双向同步 |
| GitHub 账号 | **无任何接入** |

结论:同步引擎(数据序列化、双向合并、冲突处理)已就绪,GitHub 方案只需要**新增一个"云端适配器"**,把现有 WebDAV 读写替换/并列成 GitHub 读写。

## 四、可行方案对比

| 维度 | 方案 A:Personal Access Token(推荐) | 方案 B:OAuth Device Flow | 方案 C:OAuth Web 跳转 |
|---|---|---|---|
| 用户操作 | 在 GitHub 网页生成 Token → 粘贴进 APP | APP 显示 8 位码 → 用户打开 github.com/login/device 输入 | 点按钮 → 跳 GitHub 网页 → 点一次授权 → 回 APP |
| 需要注册 OAuth App | 否(fine-grained PAT 权限最小) | 是 | 是 |
| 回跳协议 | 无需(纯粘贴) | 无需(device flow 无回调) | 需要 deep link(`miru://callback`) |
| Token 权限范围 | 用户可限定单仓库(fine-grained) | 由 OAuth App scope 决定 | 同左 |
| 审核风险 | 无 | 低 | 中(deep link 配置) |
| 实现复杂度 | **低**(一个设置页 + 一个 API client) | 中(轮询 device code) | 中高(回调处理) |
| 适合人群 | 能按文档操作的开发者用户 | 普通用户 | 普通用户 |

**推荐方案 A(PAT)**,理由:实现最简单、权限最小化(fine-grained PAT 只授权一个私有仓库)、无回调/轮询等易错环节,和 Miru 的极客用户画像匹配。方案 B 可作为二期叠加(同一套云端适配器,只换取 Token 的方式)。

## 五、方案 A 详细设计(PAT + 私有仓库即数据库)

### 5.1 数据存放形态

用户在自己 GitHub 账号下建一个**私有仓库**(例如 `miru-sync`),APP 用 PAT 读写其中的同步文件:

```
miru-sync/
└── data/
    ├── history.json      # 观看历史(与现有 WebDAV history 同构)
    ├── collectibles.json # 追番收藏
    └── device-<id>.json  # 设备清单(多设备合并用)
```

- 读写走 GitHub Contents API(`GET/PUT /repos/{owner}/{repo}/contents/{path}`,PUT 携带 `sha` 做乐观锁,409 冲突时拉新重试,与现有 WebDAV remote file commit 的合并策略一致)。
- 私有仓库保证只有用户本人可见;PAT 用 fine-grained 类型且只授权该仓库,权限最小。

### 5.2 客户端模块

- `lib/services/sync/github_sync_service.dart`:实现与 `HistorySyncService`/collectibles 同步相同的接口约定,内部把 WebDAV 读写替换为 GitHub Contents API dio 调用;复用现有合并逻辑(`CollectSyncMerger` 等),**不重写同步语义**。
- `lib/pages/settings/github/github_settings_page.dart`:Token 粘贴框(密码框 + 显示/隐藏)、连接测试按钮、仓库不存在时引导一键创建(`POST /user/repos` 用 Token 权限)、同步开关组(历史/收藏分开)、立即同步按钮。
- Token 存储:`flutter_secure_storage` 或继续用现有 Hive 加密方式(**不要**明文存 setting box)。
- 「我的」页面:登录入口只在"数据同步"卡片内出现,不登录时显示"本地模式(数据仅存本机)"文案,核心功能不受任何影响。

### 5.3 同步时机(与现有 WebDAV 完全对齐)

- 打开 APP:后台拉远端 → 与本地合并;
- 观看进度变化:防抖 30 秒批量上传;
- 手动:设置页"立即同步"。

### 5.4 需要的新依赖

- `flutter_secure_storage`(Token 加密存储)——唯一新增依赖;GitHub API 用现有 dio 封装即可。

## 六、风险与对策

| 风险 | 对策 |
|---|---|
| Token 泄露 | fine-grained PAT + 仅单仓库权限 + secure storage;UI 提供"撤销并清除 Token" |
| GitHub API 限流(未登录 60 次/时,Token 5000 次/时) | 防抖批量上传 + ETag 条件请求 |
| 多设备并发写冲突 | Contents API sha 乐观锁 + 现有设备号/序列号合并逻辑 |
| 用户误建公有仓库泄露数据 | 创建仓库 API 显式 `private: true`;检测到远端为公有时在同步页红色警告 |
| 仓库被删/改名 | 同步失败时明确提示,本地数据永不删除 |

## 七、实施工作量预估(方案 A)

- GitHub API client(Contents + 创建仓库 + 连接测试):约 300 行
- 同步服务适配器(对接现有合并逻辑):约 250 行
- 设置页 + 我的页入口 UI:约 300 行
- 单测(合并/冲突/限流重试):约 200 行
- **合计约 2 个开发日**;方案 B 叠加约再 +1 天
