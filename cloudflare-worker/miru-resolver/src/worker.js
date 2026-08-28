/**
 * Miru 云端视频解析层 v3（Cloudflare Workers + KV）
 * ================================================================
 *
 * v3 相比 v2 的关键变化：
 *
 * 1. **fetch 加超时与体积上限**：fetchText 带 AbortSignal.timeout +
 *    2MB 截断——慢源站不再能把 Worker 拖过客户端 4s 上限，
 *    超大响应也不再能撑爆 128MB 内存。
 * 2. **全局每日硬顶**：uid 客户端自报可伪造（随机 uid 即可绕过个人
 *    配额），全局当日计数是最后防线（GLOBAL_DAILY_HARD_CAP，默认 6 万）。
 * 3. **提取器 v3**（括号配平，与 APP 端同源）+ 宽松 base64
 *    （URL-safe/缺 padding 的 encrypt=2 也能解，与 APP 对齐）。
 *
 * v2 的长期运营设计（KV 写节流 / 匿名统计 / 动态配额）全部保留：
 *
 * 1. **KV 写节流**：结果只在「同一 isolate 内第二次被请求」（跨用户
 *    热门内容）时才落 KV，用户计数器每 [WRITE_EVERY] 次请求才写一次。
 * 2. **匿名用户统计**：APP 端生成随机匿名 ID，/resolve 带 uid、每天
 *    一次 /ping 心跳（心跳打到用户配置的端点）。Worker 记录每日
 *    活跃人数（只计数，不存任何可识别信息），/stats 可随时查看。
 * 3. **动态配额**：免费版每天 10 万请求 / 1000 次 KV 写。全局
 *    [DAILY_RESOLVE_BUDGET] 按当日活跃人数均摊出每用户配额：
 *    active 越少每人越多，inactive 用户不占额度；
 *    超限返回 429，APP 自动降级本地解析——任何情况下都能播。
 *
 * 接口：
 *   GET /resolve?url=<encoded>&ua=<optional>&referer=<optional>&uid=<optional>
 *   GET /ping?uid=<optional>          每日心跳（记录活跃用户）
 *   GET /stats                        当日统计（活跃数/解析数/配额）
 *   GET /health
 *
 * 响应（JSON）：
 *   { ok: true, videoUrl, format: "hls"|"mp4"|"auto", source: "kv"|"remote",
 *     quota: {used, limit}, elapsedMs }
 *   { ok: false, error: "reason" }   // APP 端会降级本地解析
 *   429 { ok: false, error: "quota", limit, used }  // 今日配额用尽
 *
 * 解析策略（对 MacCMS V10 / 苹果 CMS 系国漫模板站，与 v2 相同）：
 *   1. KV 缓存命中直接返回（TTL 由 CACHE_TTL_SECONDS 控制，默认 45 分钟）
 *   2. fetch 播放页 HTML（带调用方传入的 UA，8s 超时 + 2MB 截断）
 *   3. 提取（多策略并行尝试）：
 *      a. player_aaaa / player_data 等 MacCMS 标准播放器变量的 url 字段
 *      b. HTML / 内联 JS 中的 m3u8 / mp4 直链正则（排除广告域）
 *      c. iframe src 提取 → 二跳 fetch iframe 页 → 对子页面再跑 a/b
 *   4. 相对路径补全为绝对地址
 *   5. 热门结果写 KV（expirationTtl 淘汰，无 LRU 索引）
 *
 * 注意：Worker 出口 IP 与手机不同，个别源站的防盗链可能绑定 IP/会话。
 * 这类直链 APP 端拿到后会在起播前做三态可达性探测（仅明确 4xx 才判死），
 * 探测失败自动降级本地解析，因此无需 Worker 端兜底。
 */

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const NEG_TTL = 90; // 解析失败负缓存：90 秒内不重复打源站
const USER_TTL = 2 * 24 * 3600; // 每用户每日计数器：保留 2 天
const DAY_TTL = 9 * 24 * 3600; // 每日统计：保留 9 天（看一周趋势）
const WRITE_EVERY = 25; // 用户计数器落盘间隔（省 KV 写）
const POPULARITY_THRESHOLD = 2; // 同一 isolate 内第 2 次被请求才写 KV
const MAX_TRACKED_KEYS = 3000; // isolate 内热门追踪表上限（防内存增长）
const ANON_DAILY_BUDGET = 60; // 未带 uid 的请求（旧版 APP / 路人）共享额度
const MIN_UID_LEN = 8;
const MAX_UID_LEN = 64;
const FETCH_TIMEOUT_MS = 8000; // 回源抓页超时（客户端 4s 就放弃，拖久了纯浪费）
const MAX_PAGE_BYTES = 2 * 1024 * 1024; // 单页体积上限（超过即截断）

// vars 里的配置项（wrangler.toml [vars]），在 fetch 时从 env 读取
function cacheTtlSeconds(env) {
  return parseInt(env.CACHE_TTL_SECONDS || '2700', 10);
}
function dailyResolveBudget(env) {
  return parseInt(env.DAILY_RESOLVE_BUDGET || '4000', 10);
}
function minPerUser(env) {
  return parseInt(env.MIN_PER_USER || '30', 10);
}
function maxPerUser(env) {
  return parseInt(env.MAX_PER_USER || '800', 10);
}
function globalDailyHardCap(env) {
  return parseInt(env.GLOBAL_DAILY_HARD_CAP || '60000', 10);
}

// 广告/统计域黑名单（与 APP 端 WebView 嗅探的过滤规则保持一致）
const AD_HOST_HINTS = [
  'googleads', 'googlesyndication', 'adtrafficquality', 'doubleclick',
  'prestrain.html', 'prestrain%2Ehtml',
];

// 常见视频直链扩展
const VIDEO_EXT_RE = /\.(m3u8|mp4|flv|ts|mkv|mov|webm)(?=$|[?#])/i;

// ---------------------------------------------------------------------------
// isolate 级内存状态（Worker 实例存活期间有效，重启即失，仅作近似加速）
// ---------------------------------------------------------------------------

/** 热门追踪：key → 本 isolate 内被请求次数（≥2 才写 KV）。 */
const seenKeys = new Map();
/** 全局请求近似计数（每 WRITE_EVERY 次落一次盘）。 */
let resolveCountInIsolate = 0;
/** 活跃用户数缓存：{ day, n, at }，10 分钟刷一次，省每请求一次 KV 读。 */
let activeCache = null;

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // CORS：默认全开（APP 无 Origin 头，浏览器调试也放行）
    const cors = {
      'Access-Control-Allow-Origin': env.ALLOWED_ORIGINS || '*',
      'Access-Control-Allow-Methods': 'GET,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: cors });
    }

    if (url.pathname === '/health') {
      return jsonResponse({ ok: true, service: 'miru-resolver', version: 3, now: Date.now() }, cors);
    }

    if (url.pathname === '/ping') {
      return handlePing(url, env, cors);
    }

    if (url.pathname === '/stats') {
      return handleStats(env, cors);
    }

    if (url.pathname === '/resolve') {
      const episodeUrl = url.searchParams.get('url');
      if (!episodeUrl || !/^https?:\/\//i.test(episodeUrl)) {
        return jsonResponse({ ok: false, error: 'missing or invalid "url" param' }, cors, 400);
      }
      const ua = url.searchParams.get('ua') || undefined;
      const referer = url.searchParams.get('referer') || undefined;
      const uid = sanitizeUid(url.searchParams.get('uid'));
      const started = Date.now();
      try {
        const result = await resolveEpisode(episodeUrl, ua, referer, uid, env, ctx);
        return jsonResponse(
          { ok: true, ...result, elapsedMs: Date.now() - started },
          cors,
        );
      } catch (err) {
        const message = String((err && err.message) || err);
        // 配额超限：429 + 明确语义，APP 端自动降级本地解析，不影响播放
        if (err && err.quota) {
          return jsonResponse(
            { ok: false, error: 'quota', quota: err.quota, elapsedMs: Date.now() - started },
            cors,
            429,
          );
        }
        // 负缓存也走热门门槛：单次失败不写，反复失败才写
        if (popularityOf(cacheKeyFor(episodeUrl)) >= POPULARITY_THRESHOLD) {
          ctx.waitUntil(putNegative(env, cacheKeyFor(episodeUrl), message));
        }
        return jsonResponse(
          { ok: false, error: message, elapsedMs: Date.now() - started },
          cors,
        );
      }
    }

    return jsonResponse({ ok: false, error: 'not found' }, cors, 404);
  },
};

// ---------------------------------------------------------------------------
// 每日心跳 / 统计
// ---------------------------------------------------------------------------

async function handlePing(url, env, cors) {
  const uid = sanitizeUid(url.searchParams.get('uid'));
  const day = dayKey();
  try {
    if (uid) {
      // 已有当日计数 → 已是活跃用户，零写返回
      const uRaw = await env.RESOLVE_CACHE.get(userKey(uid, day));
      if (uRaw) {
        return jsonResponse({ ok: true, active: await activeCount(env, day) }, cors);
      }
      // 新活跃用户：创建计数器 + 活跃数 +1（共 2 次写）
      await env.RESOLVE_CACHE.put(userKey(uid, day), JSON.stringify({ c: 0 }), {
        expirationTtl: USER_TTL,
      });
      await bumpActive(env, day);
    }
    return jsonResponse({ ok: true, active: await activeCount(env, day) }, cors);
  } catch (err) {
    // 心跳失败对 APP 无影响（fire-and-forget），静默成功即可
    return jsonResponse({ ok: true, active: -1 }, cors);
  }
}

async function handleStats(env, cors) {
  const day = dayKey();
  try {
    const [activeRaw, usageRaw] = await Promise.all([
      env.RESOLVE_CACHE.get(dayKeyActive(day)),
      env.RESOLVE_CACHE.get(dayKeyUsage(day)),
    ]);
    const active = activeRaw ? (JSON.parse(activeRaw).n || 0) : 0;
    const used = usageRaw ? (JSON.parse(usageRaw).r || 0) : 0;
    const perUser = perUserBudget(env, active);
    return jsonResponse(
      {
        ok: true,
        day,
        activeUsers: active,
        resolveRequests: used,
        dailyBudget: dailyResolveBudget(env),
        perUserBudget: perUser,
        anonBudget: ANON_DAILY_BUDGET,
        globalHardCap: globalDailyHardCap(env),
      },
      cors,
    );
  } catch (err) {
    return jsonResponse({ ok: false, error: String(err) }, cors, 500);
  }
}

// ---------------------------------------------------------------------------
// 解析主流程
// ---------------------------------------------------------------------------

async function resolveEpisode(episodeUrl, ua, referer, uid, env, ctx) {
  const key = cacheKeyFor(episodeUrl);
  const day = dayKey();

  // 1) KV 缓存（命中不受配额限制——KV 读很便宜，已超限用户也照常享受缓存）
  const cachedRaw = await env.RESOLVE_CACHE.get(key);
  if (cachedRaw) {
    try {
      const cached = JSON.parse(cachedRaw);
      if (cached.ok) {
        const quota = await countUsage(uid, day, env, ctx);
        return { ...pickCacheFields(cached), source: 'kv', quota };
      }
      // 负缓存未过期：直接放弃
      if (Date.now() - (cached.at || 0) < NEG_TTL * 1000) {
        throw new Error('negative cache hit');
      }
    } catch (e) {
      if (String(e && e.message) === 'negative cache hit') throw e;
      // 缓存损坏视为未命中，走远程解析
    }
  }

  // 2) 配额检查（只限制「打源站」的次数；超限抛出，外层转 429，
  //    APP 端对非 ok 一律降级本地解析，不影响播放）
  const gate = await checkQuota(uid, day, env);
  if (!gate.allowed) {
    const err = new Error('quota exceeded');
    err.quota = gate;
    throw err;
  }

  // 3) 远程解析
  const result = await extractFromPage(episodeUrl, ua, referer, 0);

  // 4) 计一次使用（成功才计；失败不扣用户的额度）
  const quota = await countUsage(uid, day, env, ctx);

  // 热门门槛：本 isolate 内第 2 次被请求的条目才值得占一次 KV 写
  if (popularityOf(key) >= POPULARITY_THRESHOLD) {
    const record = { ok: true, ...result, at: Date.now() };
    ctx.waitUntil(
      env.RESOLVE_CACHE.put(key, JSON.stringify(record), {
        expirationTtl: cacheTtlSeconds(env),
      }),
    );
  }

  return { ...result, source: 'remote', quota };
}

// ---------------------------------------------------------------------------
// 配额与用户计数
// ---------------------------------------------------------------------------

function sanitizeUid(raw) {
  if (!raw) return null;
  const uid = String(raw).trim().toLowerCase();
  if (uid.length < MIN_UID_LEN || uid.length > MAX_UID_LEN) return null;
  return /^[a-z0-9_-]+$/.test(uid) ? uid : null;
}

function dayKey() {
  // 用户群体以中国为主，按 UTC+8 的自然日滚动
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

function userKey(uid, day) {
  return `u:${uid}:${day}`;
}
function dayKeyActive(day) {
  return `d:${day}`;
}
function dayKeyUsage(day) {
  return `w:${day}`;
}

/** 每用户预算 = 总预算 / 当日活跃人数，动态伸缩。 */
function perUserBudget(env, active) {
  const n = Math.max(1, active || 1);
  const budget = dailyResolveBudget(env);
  const per = Math.floor(budget / n);
  return Math.min(Math.max(per, minPerUser(env)), maxPerUser(env));
}

async function activeCount(env, day) {
  const now = Date.now();
  if (activeCache && activeCache.day === day && now - activeCache.at < 10 * 60 * 1000) {
    return activeCache.n;
  }
  try {
    const raw = await env.RESOLVE_CACHE.get(dayKeyActive(day));
    const n = raw ? (JSON.parse(raw).n || 0) : 0;
    activeCache = { day, n, at: now };
    return n;
  } catch (_) {
    return activeCache ? activeCache.n : 1;
  }
}

async function bumpActive(env, day) {
  try {
    const raw = await env.RESOLVE_CACHE.get(dayKeyActive(day));
    const n = (raw ? (JSON.parse(raw).n || 0) : 0) + 1;
    await env.RESOLVE_CACHE.put(dayKeyActive(day), JSON.stringify({ n }), {
      expirationTtl: DAY_TTL,
    });
    activeCache = { day, n, at: Date.now() };
    return n;
  } catch (_) {
    return 0;
  }
}

/**
 * 配额检查：读用户当日计数，超预算则拒绝。
 * 计数为近似值（节流写盘 + KV 最终一致），作软限制足够；
 * 全局硬顶是兜底——uid 客户端自报可伪造（随机 uid 即可绕过个人
 * 配额白嫖官方端点），全局当日计数（含缓存命中，近似值）
 * 是唯一可信的最后防线（B9）。
 */
async function checkQuota(uid, day, env) {
  const active = await activeCount(env, day);
  const limit = uid ? perUserBudget(env, active) : ANON_DAILY_BUDGET;
  let used = 0;
  let globalUsed = 0;
  try {
    const raw = await env.RESOLVE_CACHE.get(dayKeyUsage(day));
    globalUsed = raw ? (JSON.parse(raw).r || 0) : 0;
  } catch (_) {}
  if (globalUsed >= globalDailyHardCap(env)) {
    return { allowed: false, used, limit, active, globalUsed };
  }
  if (uid) {
    try {
      const raw = await env.RESOLVE_CACHE.get(userKey(uid, day));
      used = raw ? (JSON.parse(raw).c || 0) : 0;
    } catch (_) {}
  } else {
    // 未带 uid：共享匿名桶，读共享计数
    try {
      const raw = await env.RESOLVE_CACHE.get(userKey('anon', day));
      used = raw ? (JSON.parse(raw).c || 0) : 0;
    } catch (_) {}
  }
  return { allowed: used < limit, used, limit, active, globalUsed };
}

/**
 * 计一次使用（缓存命中与远程解析成功都计）。
 * 写盘节流：首次（新用户，顺带活跃 +1）与每 WRITE_EVERY 次；
 * 全局当日总量的落盘同样节流（每 WRITE_EVERY 次写一次近似值）。
 */
async function countUsage(uid, day, env, ctx) {
  const key = uid ? userKey(uid, day) : userKey('anon', day);
  let prevCount;
  try {
    const raw = await env.RESOLVE_CACHE.get(key);
    prevCount = raw ? (JSON.parse(raw).c || 0) : null;
  } catch (_) {
    prevCount = 0;
  }
  // prevCount === null 表示该计数器今天还不存在（ping 已建过计数器的不会重复 bump）
  const isNewCounter = prevCount === null;
  const used = (prevCount ?? 0) + 1;
  const active = await activeCount(env, day);
  const limit = uid ? perUserBudget(env, active) : ANON_DAILY_BUDGET;

  if (isNewCounter || used % WRITE_EVERY === 0) {
    ctx.waitUntil((async () => {
      try {
        await env.RESOLVE_CACHE.put(key, JSON.stringify({ c: used }), {
          expirationTtl: USER_TTL,
        });
        // 只有真实 uid 才计入活跃人数；匿名桶不占「用户数」
        if (isNewCounter && uid) {
          await bumpActive(env, day);
        }
      } catch (_) {}
    })());
  }

  // 全局近似计数：每 WRITE_EVERY 次落盘
  resolveCountInIsolate += 1;
  if (resolveCountInIsolate % WRITE_EVERY === 0) {
    ctx.waitUntil((async () => {
      try {
        const k = dayKeyUsage(day);
        const raw = await env.RESOLVE_CACHE.get(k);
        const prev = raw ? (JSON.parse(raw).r || 0) : 0;
        await env.RESOLVE_CACHE.put(
          k,
          JSON.stringify({ r: prev + WRITE_EVERY }),
          { expirationTtl: DAY_TTL },
        );
      } catch (_) {}
    })());
  }

  return { used, limit, active };
}

// ---------------------------------------------------------------------------
// 热门追踪（isolate 内存）
// ---------------------------------------------------------------------------

function popularityOf(key) {
  const n = (seenKeys.get(key) || 0) + 1;
  if (seenKeys.size > MAX_TRACKED_KEYS) seenKeys.clear();
  seenKeys.set(key, n);
  return n;
}

async function putNegative(env, key, message) {
  try {
    await env.RESOLVE_CACHE.put(key, JSON.stringify({
      ok: false, error: message, at: Date.now(),
    }), { expirationTtl: NEG_TTL });
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// 提取器（纯函数，便于本地单测；与 v1 完全一致）
// ---------------------------------------------------------------------------

/**
 * MacCMS 播放器变量提取（v3，2026-08 配平修复）。
 *
 * 旧版正则 `(\{[^}]*\})` 在 player_aaaa 含嵌套对象（如 vod_data）
 * 时会被第一个 `}` 提前截断，JSON.parse 必然失败——blbl/lblb/淘片
 * 等一大批 MacCMS 站的云端解析全挂就是这个原因。新版改括号配平提取。
 */
function extractMaccmsPlayerVar(html) {
  const varRe = /(?:var\s+)?(player_[a-z0-9]+)\s*=\s*\{/g;
  let m;
  while ((m = varRe.exec(html)) !== null) {
    const raw = balancedJsonAt(html, m.index + m[0].length - 1);
    if (!raw) continue;
    let obj = null;
    try {
      obj = JSON.parse(raw);
    } catch (_) {
      try {
        const fixed = raw.replace(/'/g, '"').replace(/,(\s*[}\]])/g, '$1');
        obj = JSON.parse(fixed);
      } catch (_) {}
    }
    if (!obj) continue;
    // MacCMS 官方编码（maccms10 All.php）：
    // encrypt=1 → escape()；encrypt=2 → base64(escape())；0 → 原文
    const decoded = resolvePlayerAaaaUrl(obj);
    if (decoded && VIDEO_EXT_RE.test(stripQuery(decoded))) {
      return { url: decoded, varName: m[1], referer: obj.referer || '' };
    }
  }
  return null;
}

/** 从 openIdx（指向 `{`）括号配平截取 JSON（跳过字符串字面量与转义）。 */
function balancedJsonAt(html, openIdx) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = openIdx; i < html.length && i < openIdx + 20000; i++) {
    const c = html[i];
    if (escaped) { escaped = false; continue; }
    if (c === '\\' && inString) { escaped = true; continue; }
    if (c === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return html.slice(openIdx, i + 1);
    }
  }
  return null;
}

/** JS escape() 解码：%uXXXX（UTF-16）与 %XX。 */
function macUnescape(s) {
  return String(s).replace(/%u([0-9A-Fa-f]{4})|%([0-9A-Fa-f]{2})/g,
    (_, u, b) => String.fromCharCode(parseInt(u || b, 16)));
}

/** 按官方 encrypt 字段解码 player_aaaa.url。 */
function resolvePlayerAaaaUrl(a) {
  let u = (a && a.url) || (a && a.link) || '';
  if (typeof u !== 'string' || !u.trim()) return '';
  u = u.trim();
  try {
    const enc = a.encrypt | 0;
    if (enc === 2) u = macUnescape(lenientAtob(u));
    else if (enc === 1) u = macUnescape(u);
    else {
      try {
        const d = decodeURIComponent(u);
        if (d.startsWith('http')) u = d;
      } catch (_) {}
    }
  } catch (_) {
    return '';
  }
  return u;
}

/**
 * 宽松 base64（与 APP 端 normalizedBase64Decode 对齐）：atob 遇
 * URL-safe 字符（-/_）或缺 padding 直接抛——部分源的 encrypt=2 产物
 * 是 URL-safe 形态，只在 Worker 侧解不开，统一替换补齐后再解。
 */
function lenientAtob(input) {
  let s = String(input).trim();
  if (s.includes('-') || s.includes('_')) {
    s = s.replaceAll('-', '+').replaceAll('_', '/');
  }
  const pad = (4 - (s.length % 4)) % 4;
  if (pad > 0) s += '='.repeat(pad);
  return atob(s);
}

/** 从 HTML / 内联 JS 中提取 m3u8 / mp4 直链（排除广告与统计域）。 */
function extractDirectVideoUrl(html) {
  // 贪婪匹配到引号/空白边界，保留完整 query（带签名的直链截断即 403）；
  // 内联 JS 中的转义斜杠（\/）在候选阶段统一还原。
  const candidates = [];
  const urlRe = /https?:\\?\/\\?\/[^\s"'<>`]+/gi;
  let m;
  while ((m = urlRe.exec(html)) !== null) {
    const raw = m[0].replace(/\\\//g, '/').replace(/\\+/g, '');
    if (!isAdUrl(raw) && VIDEO_EXT_RE.test(stripQuery(raw))) {
      candidates.push(raw);
    }
  }
  if (candidates.length === 0) return null;
  // m3u8 优先；同级取第一个出现的（通常首个即主源）
  const hls = candidates.find((c) => /\.m3u8/i.test(stripQuery(c)));
  return hls || candidates[0];
}

/** 提取第一个可用 iframe src（排除 about:blank 与广告域）。 */
function extractIframeSrc(html) {
  const iframeRe = /<iframe[^>]+src=["']([^"']+)["']/gi;
  let m;
  while ((m = iframeRe.exec(html)) !== null) {
    const src = m[1].trim();
    if (!src || src === 'about:blank' || src.startsWith('javascript:')) continue;
    if (isAdUrl(src)) continue;
    return src;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 解析（远程抓取）
// ---------------------------------------------------------------------------

async function extractFromPage(pageUrl, ua, referer, depth) {
  const html = await fetchText(pageUrl, ua, referer || pageUrl);
  const base = new URL(pageUrl);

  // 策略 a：MacCMS 播放器变量（括号配平 + encrypt 解码，v3）
  const playerVar = extractMaccmsPlayerVar(html);
  if (playerVar) {
    const resolved = absolutize(playerVar.url, base);
    if (resolved && VIDEO_EXT_RE.test(stripQuery(resolved)) && !isAdUrl(resolved)) {
      return {
        videoUrl: resolved,
        format: formatOf(resolved),
        referer: playerVar.referer || referer || pageUrl,
      };
    }
  }

  // 策略 b：正文/内联 JS 中的直链
  const direct = extractDirectVideoUrl(html);
  if (direct) {
    const resolved = absolutize(direct, base);
    if (resolved && !isAdUrl(resolved)) {
      return {
        videoUrl: resolved,
        format: formatOf(resolved),
        referer: referer || pageUrl,
      };
    }
  }

  // 策略 c：iframe 二跳（限一层，避免深递归把 CPU 时间烧完）
  if (depth < 1) {
    const iframeSrc = extractIframeSrc(html);
    if (iframeSrc) {
      const iframeUrl = absolutize(iframeSrc, base);
      if (iframeUrl && !isAdUrl(iframeUrl)) {
        try {
          return await extractFromPage(iframeUrl, ua, pageUrl, depth + 1);
        } catch (_) {
          // iframe 拉取失败继续走下面的兜底
        }
      }
    }
  }

  throw new Error('no video source found in page');
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

function cacheKeyFor(episodeUrl) {
  // 完整 URL 作 key（防 32 位 FNV 碰撞被刻意构造跨用户毒缓存，
  // 返回错集直链）；超长（>400 字符）或含非 ASCII 的 URL 退回
  // FNV-1a+长度（KV key 上限 512 字节）。
  if (episodeUrl.length <= 400 && !/[^\x00-\x7F]/.test(episodeUrl)) {
    return `r:${episodeUrl}`;
  }
  let h = 0x811c9dc5;
  for (let i = 0; i < episodeUrl.length; i++) {
    h ^= episodeUrl.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return `r:${(h >>> 0).toString(36)}:${episodeUrl.length}`;
}

function pickCacheFields(cached) {
  return {
    videoUrl: cached.videoUrl,
    format: cached.format || 'auto',
    referer: cached.referer,
  };
}

async function fetchText(url, ua, referer) {
  const res = await fetch(url, {
    headers: {
      'user-agent': ua || DEFAULT_UA,
      'referer': referer || undefined,
      'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'accept-language': 'zh-CN,zh;q=0.9',
    },
    redirect: 'follow',
    // B8：慢源站不得把 Worker 拖过客户端 4s 上限（拖过了也是白拖）
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`page fetch failed: ${res.status}`);
  }
  const text = await readTextLimited(res, MAX_PAGE_BYTES);
  if (!text) throw new Error('empty page body');
  return text;
}

/**
 * 读取响应体并截断到 maxBytes（B8：res.text() 无上限，超大响应能
 * 撑爆 isolate 的 128MB 内存；截断后的 HTML 足够提取直链）。
 */
async function readTextLimited(res, maxBytes) {
  if (!res.body) return res.text();
  const reader = res.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: false });
  let out = '';
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    out += decoder.decode(value, { stream: true });
    if (received >= maxBytes) {
      try { await reader.cancel(); } catch (_) {}
      break;
    }
  }
  out += decoder.decode();
  return out;
}

const DEFAULT_UA =
  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36';

function absolutize(url, base) {
  if (!url) return null;
  const trimmed = url.trim();
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  if (trimmed.startsWith('//')) return `https:${trimmed}`;
  try {
    return new URL(trimmed, base).toString();
  } catch (_) {
    return null;
  }
}

function formatOf(url) {
  return /\.m3u8/i.test(stripQuery(url)) ? 'hls' : 'mp4';
}

function stripQuery(url) {
  return String(url).split('#')[0].split('?')[0];
}

function isAdUrl(url) {
  const lower = String(url).toLowerCase();
  return AD_HOST_HINTS.some((hint) => lower.includes(hint));
}

function jsonResponse(obj, cors, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...cors,
    },
  });
}
