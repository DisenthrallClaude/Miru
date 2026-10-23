#!/usr/bin/env python3
"""对 e2e_sources_live_test 产出的候选直链，用 mpv 真实播放 N 秒（带 App 会传给 mpv 的 headers），
输出逐源成功率表（Markdown + JSON）。用法: e2e_play.py result.json out_prefix [seconds]"""
import json, subprocess, sys, time, os
src, outp = sys.argv[1], sys.argv[2]
secs = int(sys.argv[3]) if len(sys.argv) > 3 else 10
rows = json.load(open(src))

MODE = os.environ.get('E2E_MODE', 'app')  # app = 复刻 App v1.7.0 的 mpv 属性；plain = 裸 mpv

def app_props(url):
    common = ['--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=3,timeout=10000000',
              '--demuxer-lavf-analyzeduration=1', '--demuxer-lavf-probesize=1048576', '--network-timeout=8',
              '--cache-pause-initial=no', '--cache-pause-wait=1', '--video-sync=audio']
    if '.m3u8' in url.lower() or 'm3u8' in url.lower():
        return common + ['--demuxer-lavf-format=hls', '--hls-bitrate=no',
            '--demuxer-lavf-o=http_persistent=1,http_multiple=1,seg_max_retry=3,max_reload=5,reconnect=1,reconnect_streamed=1,reconnect_delay_max=3',
            '--demuxer-lavf-probe-info=nostreams']
    return common + ['--demuxer-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=3', '--demuxer-lavf-probe-info=auto']

def play(url, headers):
    hdr = []
    ua = None
    for k, v in headers.items():
        if k.lower() == 'user-agent':
            ua = v
        else:
            hdr.append(f"{k}: {v}")
    cmd = ['mpv', '--no-config', '--ytdl=no', '--vo=null', '--ao=null', '--really-quiet=no', '--msg-level=all=warn',
           f'--length={secs}', '--script=' + os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pos.lua')]
    cmd += app_props(url) if MODE == 'app' else ['--network-timeout=15']
    if ua: cmd.append(f'--user-agent={ua}')
    if hdr: cmd.append('--http-header-fields=' + ','.join(h.replace(',', '\\,') for h in hdr))
    cmd.append(url)
    t = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=secs + 30)
        out = (p.stdout + p.stderr)
    except subprocess.TimeoutExpired as e:
        return False, 'mpv timeout(>%ds)' % (secs + 30), time.time() - t
    import re
    m = re.findall(r'E2EPOS=(-?[0-9.]+)', out)
    pos = float(m[-1]) if m else -1
    ok = pos >= secs - 1.5
    # 播放够时长：mpv --length 到点退出 rc=0
    tail = [l for l in out.splitlines() if l.strip() and 'E2EPOS' not in l and 'ytdl' not in l][-3:]
    return ok, f'pos={pos:.1f}s ' + ' | '.join(tail)[:300], time.time() - t

table = []
for r in rows:
    name = r.get('name') or r['file']
    if r.get('stage') != 'resolved':
        table.append({'name': name, 'stage': r.get('stage') or 'error', 'ok': False,
                      'detail': r.get('error') or r.get('searchError') or 'search/chapters empty'})
        continue
    best = None
    for ep in r.get('episodes', []):
        cands = [(c['url'], c['mpvHeaders'], 'fast:' + c['strategy']) for c in ep.get('fast', [])]
        if ep.get('cloud'):
            cands.append((ep['cloud']['url'], ep['cloud']['mpvHeaders'], 'cloud'))
        if not cands:
            best = best or {'name': name, 'stage': 'resolve', 'ok': False, 'road': ep['road'],
                            'detail': f"fast={ep.get('fastFailure') or ep.get('fastError')} cloud={ep.get('cloudFailure') or ep.get('cloudError')}"}
            continue
        for url, h, how in cands[:3]:
            ok, msg, dt = play(url, h)
            res = {'name': name, 'stage': 'play', 'ok': ok, 'road': ep['road'], 'via': how,
                   'url': url[:140], 'detail': msg, 'playSec': round(dt, 1)}
            print(json.dumps(res, ensure_ascii=False), flush=True)
            if ok:
                best = res; break
            best = best if (best and best.get('ok')) else res
        if best and best.get('ok'):
            break
    table.append(best)

json.dump(table, open(outp + '.json', 'w'), ensure_ascii=False, indent=1)
okn = sum(1 for t in table if t and t.get('ok'))
with open(outp + '.md', 'w') as f:
    f.write(f"| 源 | 结果 | 阶段 | 线路 | 方式 | 说明 |\n|---|---|---|---|---|---|\n")
    for t in table:
        f.write(f"| {t['name']} | {'✅' if t['ok'] else '❌'} | {t['stage']} | {t.get('road','')} | {t.get('via','')} | {str(t.get('detail',''))[:120].replace('|','/')} |\n")
    f.write(f"\n成功 {okn}/{len(table)}\n")
print(f"SUMMARY {okn}/{len(table)}")
