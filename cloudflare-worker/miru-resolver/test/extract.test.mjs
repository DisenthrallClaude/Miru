/**
 * Worker 解析引擎纯函数测试（Node 直跑，无需部署）。
 * 用法: node cloudflare-worker/miru-resolver/test/extract.test.mjs
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const workerSrc = readFileSync(join(here, '../src/worker.js'), 'utf8');

// 整文件加载（顶层无副作用），追加导出行暴露内部纯函数。
// 不做函数体文本提取：正则字面量中的花括号会破坏括号配对。
const code =
  workerSrc +
  '\nexport { extractMaccmsPlayerVar, extractDirectVideoUrl, extractIframeSrc, absolutize, formatOf, stripQuery, isAdUrl, cacheKeyFor };\n';

const tmp = join(here, '.extracted.mjs');
writeFileSync(tmp, code);
const mod = await import(`file://${tmp}`);

let pass = 0;
let fail = 0;
function t(name, fn) {
  try {
    fn();
    pass++;
    console.log(`  ok  ${name}`);
  } catch (e) {
    fail++;
    console.error(`FAIL  ${name}\n      ${e.message}`);
  }
}

console.log('extractMaccmsPlayerVar:');
t('MacCMS 标准变量提取 url 字段', () => {
  const html = '<script>var player_aaaa={"flag":"play","encrypt":"0","sign":"","url":"https://v.example.com/2024/abc.m3u8","url_next":""}</script>';
  const r = mod.extractMaccmsPlayerVar(html);
  if (!r || r.url !== 'https://v.example.com/2024/abc.m3u8') {
    throw new Error(`got ${JSON.stringify(r)}`);
  }
});
t('单引号 JSON 宽松修复', () => {
  const html = "<script>player_data={'url':'https://v.example.com/x.mp4'}</script>";
  const r = mod.extractMaccmsPlayerVar(html);
  if (!r || r.url !== 'https://v.example.com/x.mp4') {
    throw new Error(`got ${JSON.stringify(r)}`);
  }
});
t('非视频 url 不误报', () => {
  const html = '<script>var player_aaaa={"url":"https://v.example.com/page.html"}</script>';
  const r = mod.extractMaccmsPlayerVar(html);
  if (r !== null) throw new Error(`expected null, got ${JSON.stringify(r)}`);
});

console.log('extractDirectVideoUrl:');
t('优先 m3u8', () => {
  const html = 'var x="https://a.com/1.mp4";var y="https://b.com/hls/index.m3u8?token=1";';
  const r = mod.extractDirectVideoUrl(html);
  if (r !== 'https://b.com/hls/index.m3u8?token=1') throw new Error(`got ${r}`);
});
t('排除广告域', () => {
  const html = 'https://googleads.g.doubleclick.net/x.mp4 https://cdn.ok.com/v.mp4';
  const r = mod.extractDirectVideoUrl(html);
  if (r !== 'https://cdn.ok.com/v.mp4') throw new Error(`got ${r}`);
});
t('转义斜杠还原', () => {
  const html = 'src:"https:\\/\\/cdn.example.com\\/v\\/a.m3u8"';
  const r = mod.extractDirectVideoUrl(html);
  if (r !== 'https://cdn.example.com/v/a.m3u8') throw new Error(`got ${r}`);
});
t('无直链返回 null', () => {
  if (mod.extractDirectVideoUrl('<div>hello</div>') !== null) throw new Error('expected null');
});

console.log('extractIframeSrc:');
t('提取第一个 iframe src', () => {
  const html = '<iframe src="https://player.example.com/embed/1"></iframe>';
  const r = mod.extractIframeSrc(html);
  if (r !== 'https://player.example.com/embed/1') throw new Error(`got ${r}`);
});
t('跳过广告 iframe', () => {
  const html = '<iframe src="https://googleads.example.com/x"></iframe><iframe src="/play"></iframe>';
  const r = mod.extractIframeSrc(html);
  if (r !== '/play') throw new Error(`got ${r}`);
});

console.log('absolutize / formatOf:');
t('相对路径补全', () => {
  const r = mod.absolutize('seg1.ts', 'https://c.com/v/i.m3u8');
  if (r !== 'https://c.com/v/seg1.ts') throw new Error(`got ${r}`);
});
t('协议相对补全', () => {
  const r = mod.absolutize('//cdn.com/a.m3u8', 'https://c.com/p');
  if (r !== 'https://cdn.com/a.m3u8') throw new Error(`got ${r}`);
});
t('formatOf 判定', () => {
  if (mod.formatOf('https://c.com/a.m3u8?x=1') !== 'hls') throw new Error('m3u8 应为 hls');
  if (mod.formatOf('https://c.com/a.mp4') !== 'mp4') throw new Error('mp4 应为 mp4');
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
