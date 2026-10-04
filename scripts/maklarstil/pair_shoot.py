#!/usr/bin/env python3
"""pair_shoot.py <shootdir> <destdir> <n|all>
Parar red-leveranser med NEF-bracketgrupper (tidsglapp <= 6 s, samma brännvidd) och kopierar
NEF-gruppen, gruppens skicka-DNG och red-JPG till destdir/{nef,skicka,red}. Läser bara från shootdir."""
import sys, os, json, subprocess, datetime, glob, shutil
shoot, dest, n = sys.argv[1], sys.argv[2], sys.argv[3]
name = os.path.basename(shoot.rstrip('/'))
def find_sub(suffix):
    c = [d for d in glob.glob(os.path.join(shoot, '*')) if os.path.isdir(d) and d.lower().endswith(suffix)]
    return c[0] if c else None
red, skicka = find_sub(' red'), find_sub(' skicka')
nefs = sorted(glob.glob(os.path.join(shoot, '*.NEF')) + glob.glob(os.path.join(shoot, '*.nef')))
assert red and nefs, f'saknar red eller NEF i {shoot}'
reds = sorted(f for f in glob.glob(os.path.join(red, '*')) if f.lower().endswith(('.jpg', '.jpeg')))
pres = subprocess.run(['exiftool', '-T', '-FileName', '-PreservedFileName'] + reds, capture_output=True, text=True).stdout
redmap = {}
for l in pres.splitlines():
    fn, pf = l.split('\t')
    base = (pf if pf != '-' else fn).rsplit('.', 1)[0]
    if base.upper().startswith('DSC'): redmap[base] = os.path.join(red, fn)
rows = [l.split('\t') for l in subprocess.run(['exiftool', '-T', '-FileName', '-SubSecDateTimeOriginal', '-DateTimeOriginal', '-ExposureTime', '-FocalLength'] + nefs, capture_output=True, text=True).stdout.splitlines()]
def ts(r):
    s = r[1] if r[1] != '-' else r[2]
    try: return datetime.datetime.strptime(s[:22], '%Y:%m:%d %H:%M:%S.%f')
    except ValueError: return datetime.datetime.strptime(s[:19], '%Y:%m:%d %H:%M:%S')
rows.sort(key=ts)
groups, prev = [], None
for r in rows:
    t = ts(r)
    if prev is None or (t - prev).total_seconds() > 6 or r[4] != groups[-1][-1][4]: groups.append([])
    groups[-1].append(r); prev = t
sk = {os.path.basename(f).rsplit('.', 1)[0]: f for f in glob.glob(os.path.join(skicka, '*')) if f.lower().endswith('.dng')} if skicka else {}
pairs = []
for g in groups:
    names = [r[0].rsplit('.', 1)[0] for r in g]
    for d in names:
        if d in redmap: pairs.append({'delivery': d, 'frames': names, 'skicka': [x for x in names if x in sk]})
if n != 'all':
    k = int(n); pairs = [pairs[int(i * len(pairs) / k)] for i in range(min(k, len(pairs)))] if len(pairs) > k else pairs
for sub in ('nef', 'skicka', 'red'): os.makedirs(os.path.join(dest, sub), exist_ok=True)
for p in pairs:
    for f in p['frames']: 
        src = os.path.join(shoot, f + '.NEF')
        if not os.path.exists(src): src = os.path.join(shoot, f + '.nef')
        dst = os.path.join(dest, 'nef', os.path.basename(src))
        if not os.path.exists(dst): shutil.copy2(src, dst)
    for f in p['skicka']:
        dst = os.path.join(dest, 'skicka', f + '.dng')
        if not os.path.exists(dst): shutil.copy2(sk[f], dst)
    dst = os.path.join(dest, 'red', p['delivery'] + '.jpg')
    if not os.path.exists(dst): shutil.copy2(redmap[p['delivery']], dst)
json.dump({'shoot': shoot, 'pairs': pairs}, open(os.path.join(dest, 'pairs.json'), 'w'), indent=1)
print(name, 'grupper', len(groups), 'leveranser', len(redmap), 'kopierade par', len(pairs))
