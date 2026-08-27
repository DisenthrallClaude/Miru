/**
 * Miru 云端视频解析层（Cloudflare Workers + KV）
 * ================================================================
 *
 * 作用：把「播放页 URL → 视频直链」的解析工作从手机端（WebView 嗅探，
 * 5~30 秒）搬到 Cloudflare 边缘节点（fetch + 模板提取，1~3 秒），
 * 结果写入 KV 短期缓存，热门内容二次解析 <100ms。
 *
 * APP 端（HybridVideoSourceService）按以下优先级解析：
 *   本地解析缓存 → 云端解析（本 Worker）→ 本地 WebView 嗅探（兜底）
 * 任何一层失败都会自动降级，Worker 挂掉不影响可播放性。
 *
 * 接口：
 *   GET /resolve?url=<encoded episode url>&ua=<optional>&referer=<optional>
 *   GET /health
 *
 * 响应（JSON）：
 *   { ok: true, videoUrl, format: "hls"|"mp4"|"auto", source: "kv"|"remote",
 *     referer, elapsedMs }
 *   { ok: false, error: "reason" }   // 解析失败，APP 端会降级本地解析
 *
 * 解析策略（对 MacCMS V10 / 苹果 CMS 系国漫模板站）：
 *   1. KV 缓存命中直接返回（TTL 由 CACHE_TTL_SECONDS 控制，默认 45 分钟）
 *   2. fetch 播放页 HTML（带调用方传入的 UA）
 *   3. 提取（多策略并行尝试）：
 *      a. player_aaaa / player_data 等 MacCMS 标准播放器变量的 url 字段
 *      b. HTML / 内联 JS 中的 m3u8 / mp4 直链正则（排除广告域）
 *      c. iframe src 提取 → 二跳 fetch iframe 页 → 对子页面再跑 a/b
 *   4. 相对路径补全为绝对地址
 *   5. 结果写 KV（expirationTtl），同时维护一个简易的条目索引做 LRU 淘汰
 *
 * 注意：Worker 出口 IP 与手机不同，个别源站的防盗链可能绑定 IP/会话。
 * 这类直链 APP 端拿到后会在起播前做可达性探测（Range 0-1024），
 * 探测失败自动降级本地解析，因此无需 Worker 端兜底。
 */

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const NEG_TTL = 90; // 解析失败负缓存：90 秒内不重复打源站
const INDEX_KEY = '__miru_index__'; // LRU 索引：{ [cacheKey]: lastUsed }

// vars 里的配置项（wrangler.toml [vars]），在 fetch 时从 env 读取
function cacheTtlSeconds(env) {
  return parseInt(env.CACHE_TTL_SECONDS || '2700', 10);
}

function maxCacheEntries(env) {
  return parseInt(env.MAX_CACHE_ENTRIES || '500', 10);
}

// 广告/统计域黑名单（与 APP 端 WebView 嗅探的过滤规则保持一致）
const AD_HOST_HINTS = [
  'googleads', 'googlesyndication', 'adtrafficquality', 'doubleclick',
  'prestrain.html', 'prestrain%2Ehtml',
];

// 常见视频直链扩展
const VIDEO_EXT_RE = /\.(m3u8|mp4|flv|ts|mkv|mov|webm)(?=$|[?#])/i;

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
      return jsonResponse({ ok: true, service: 'miru-resolver', now: Date.now() }, cors);
    }

    if (url.pathname === '/resolve') {
      const episodeUrl = url.searchParams.get('url');
      if (!episodeUrl || !/^https?:\/\//i.test(episodeUrl)) {
        return jsonResponse({ ok: false, error: 'missing or invalid "url" param' }, cors, 400);
      }
      const ua = url.searchParams.get('ua') || undefined;
      const referer = url.searchParams.get('referer') || undefined;
      const started = Date.now();
      try {
        const result = await resolveEpisode(episodeUrl, ua, referer, env, ctx);
        return jsonResponse(
          { ok: true, ...result, elapsedMs: Date.now() - started },
          cors,
        );
      } catch (err) {
        // 失败也写入负缓存，防止短时间反复打源站
        try {
          await env.RESOLVE_CACHE.put(cacheKeyFor(episodeUrl), JSON.stringify({
            ok: false, error: String(err && err.message || err), at: Date.now(),
          }), { expirationTtl: NEG_TTL });
        } catch (_) {}
        return jsonResponse(
          { ok: false, error: String(err && err.message || err), elapsedMs: Date.now() - started },
          cors,
        );
      }
    }

    return jsonResponse({ ok: false, error: 'not found' }, cors, 404);
  },
};

// ---------------------------------------------------------------------------
// 解析主流程
// ---------------------------------------------------------------------------

async function resolveEpisode(episodeUrl, ua, referer, env, ctx) {
  const key = cacheKeyFor(episodeUrl);

  // 1) KV 缓存
  const cachedRaw = await env.RESOLVE_CACHE.get(key);
  if (cachedRaw) {
    try {
      const cached = JSON.parse(cachedRaw);
      if (cached.ok) {
        // 命中即续期 LRU 索引（异步，不阻塞响应）
        ctx.waitUntil(touchIndex(env, key));
        return { ...pickCacheFields(cached), source: 'kv' };
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

  // 2) 远程解析
  const result = await extractFromPage(episodeUrl, ua, referer, 0);

  // 3) 写 KV + LRU 淘汰（异步）
  const record = { ok: true, ...result, at: Date.now() };
  ctx.waitUntil(persistCache(env, key, record));

  return { ...result, source: 'remote' };
}

/**
 * 从播放页提取视频直链。depth 控制递归层级（iframe 二跳最多 1 层）。
 */
async function extractFromPage(pageUrl, ua, referer, depth) {
  const html = await fetchText(pageUrl, ua, referer || pageUrl);
  const base = new URL(pageUrl);

  // 策略 a：MacCMS 播放器变量（player_aaaa = {"url":"...","link":"..."}）
  const playerVar = extractMaccmsPlayerVar(html);
  if (playerVar) {
    const resolved = absolutize(playerVar.url, base);
    if (resolved && VIDEO_EXT_RE.test(stripQuery(resolved)) && !isAdUrl(resolved)) {
      return {
        videoUrl: resolved,
        format: formatOf(resolved),
        referer: referer || pageUrl,
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
// 提取器（纯函数，便于本地单测）
// ---------------------------------------------------------------------------

/** MacCMS V10 标准变量：player_aaaa={"flag":"...","url":"..."} */
function extractMaccmsPlayerVar(html) {
  const varRe = /(?:var\s+)?(player_[a-z0-9]+)\s*=\s*(\{[^}]*\})\s*[,;]?/gi;
  let m;
  while ((m = varRe.exec(html)) !== null) {
    try {
      const obj = JSON.parse(m[2]);
      const url = obj.url || obj.link || '';
      if (typeof url === 'string' && url.trim() && VIDEO_EXT_RE.test(stripQuery(url))) {
        return { url: url.trim(), varName: m[1] };
      }
    } catch (_) {
      // JSON 里可能含单引号或未转义字符，尝试宽松修复一次
      try {
        const fixed = m[2].replace(/'/g, '"').replace(/,(\s*[}\]])/g, '$1');
        const obj = JSON.parse(fixed);
        const url = obj.url || obj.link || '';
        if (typeof url === 'string' && url.trim() && VIDEO_EXT_RE.test(stripQuery(url))) {
          return { url: url.trim(), varName: m[1] };
        }
      } catch (_) {}
    }
  }
  return null;
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
// 工具函数
// ---------------------------------------------------------------------------

function cacheKeyFor(episodeUrl) {
  // FNV-1a 32 位：Worker 里没有 node:crypto，够用且快
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

async function persistCache(env, key, record) {
  try {
    await env.RESOLVE_CACHE.put(key, JSON.stringify(record), {
      expirationTtl: cacheTtlSeconds(env),
    });
    await touchIndex(env, key, true);
  } catch (_) {}
}

/** LRU 索引：超上限时删除最久未用的缓存条目。 */
async function touchIndex(env, key, mayEvict = false) {
  try {
    const raw = await env.RESOLVE_CACHE.get(INDEX_KEY);
    const index = raw ? JSON.parse(raw) : {};
    index[key] = Date.now();
    const maxEntries = maxCacheEntries(env);
    if (mayEvict && Object.keys(index).length > maxEntries) {
      const sorted = Object.entries(index).sort((a, b) => a[1] - b[1]);
      const victims = sorted.slice(0, sorted.length - maxEntries);
      for (const [k] of victims) {
        delete index[k];
        await env.RESOLVE_CACHE.delete(k);
      }
    }
    // 索引本身 7 天滚动
    await env.RESOLVE_CACHE.put(INDEX_KEY, JSON.stringify(index), {
      expirationTtl: 7 * 24 * 3600,
    });
  } catch (_) {}
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
    // 仅信任同协议重定向（http→https 跟随，其余按默认）
  });
  if (!res.ok) {
    throw new Error(`page fetch failed: ${res.status}`);
  }
  const text = await res.text();
  if (!text) throw new Error('empty page body');
  return text;
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
