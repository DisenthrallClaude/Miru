#!/usr/bin/env python3
"""汇总 emulator-e2e 产物（e2e-out/）→ 逐源一行 Markdown 表。
用法：python3 tool/ci_summarize.py <e2e-out 目录>"""
import glob, os, re, sys

d = sys.argv[1]
rows = []
for key in sorted(glob.glob(os.path.join(d, '*_logcat.txt'))):
    tag = os.path.basename(key)[:-len('_logcat.txt')]
    t = open(key, errors='ignore').read()
    fl = [l for l in t.splitlines() if 'I/flutter' in l or 'W/flutter' in l or 'E/flutter' in l]
    txt = '\n'.join(fl)
    def has(p): return re.search(p, txt) is not None
    search = 'hit' if has('MIRU_AUTOTEST search-hit') else ('empty' if has('search-empty') else ('?'))
    m = re.search(r'resolved video URL: (\S+)', txt)
    url = m.group(1) if m else ''
    w = re.search(r'HybridResolver: \d+ (\w+) winner', txt)
    winner = w.group(1) if w else ''
    pre = txt[:m.start()] if m else ''
    if 'WebViewResolver:' in pre and 'fast winner' in pre[pre.rfind('WebViewResolver:'):]:
        winner = 'webview'
    lvl = ''
    for l in ('cache', 'fast', 'cloud', 'webview'):
        if re.search(rf'{l} wave-yield|{l} winner', txt): pass
    playing = has('buffer promoted') or has('first frame')
    dead = has('playback dead')
    codec = len(re.findall('Could not open codec', txt))
    ads = len(re.findall(r'hls_ad_filter|ad segment|skip ad', txt, re.I))
    errs = re.findall(r'Player intent error \S+ \| (.{0,80})', txt)
    first = ''
    t0 = re.search(r'(\d\d:\d\d:\d\d\.\d+) \S*\s*\S*INFO\S*\s*\S* MIRU_AUTOTEST open-video', txt)
    tp = re.search(r'(\d\d:\d\d:\d\d\.\d+) \S*\s*\S* PlayerController: buffer promoted', txt)
    def sec(s):
        h, m_, x = s.split(':'); return int(h)*3600+int(m_)*60+float(x)
    o = re.search(r' (\d\d:\d\d:\d\d\.\d+) .{0,20}MIRU_AUTOTEST open-video', txt)
    p = re.search(r' (\d\d:\d\d:\d\d\.\d+) .{0,20}PlayerController: buffer promoted', txt)
    if o and p: first = f'{sec(p.group(1))-sec(o.group(1)):.1f}s'
    verdict = '可播' if playing and not dead else ('失败' if dead or search != 'hit' or not url else '未出帧')
    rows.append((tag, search, winner, url[:70], first, codec, '; '.join(sorted(set(errs)))[:120], verdict))
print('| 源 | 搜索 | 胜出层 | 直链 | 起播耗时 | codec错误 | 播放错误 | 结论 |')
print('|---|---|---|---|---|---|---|---|')
for r in rows:
    print('| ' + ' | '.join(str(x) for x in r) + ' |')
