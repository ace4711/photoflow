"""build_pairs.py <shootroot> <outdir-name> <dst.json> [enh-dir-name ...]
shootroot har red/, skicka/, <outdir>/ ; pre-renderingar för enskilda bilder hamnar i shootroot/pre/."""
import sys, json, os, glob, subprocess
root, outname, dstjson = sys.argv[1], sys.argv[2], sys.argv[3]
extra = sys.argv[4:]  # fler outputmappar: namn=mapp
ana = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(root, outname)
groups = json.load(open(os.path.join(out, 'bracket_groups.json')))['groups']
def find(outdir, name):
    r = glob.glob(os.path.join(outdir, '**', name), recursive=True)
    r = [x for x in r if 'bracket_groups' not in x]
    return r[0] if r else None
pairs = []
os.makedirs(os.path.join(root, 'pre'), exist_ok=True)
for red in sorted(glob.glob(os.path.join(root, 'red', '*'))):
    d = os.path.splitext(os.path.basename(red))[0]
    g = next((g for g in groups if d + '.NEF' in g['files'] or d + '.nef' in g['files']), None)
    if g is None: continue
    if g.get('is_bracket'):
        stem = f"hdr_group_{g['group_id']}"
        pre = find(out, stem + '.tiff')
    else:
        stem = d
        pre = os.path.join(root, 'pre', d + '.tif')
        if not os.path.exists(pre):
            subprocess.run([os.path.join(ana, 'render-raw'), '6000', os.path.join(out, 'dng', d + '.dng'), pre], capture_output=True)
    srcs = {'skicka': os.path.join(root, 'skicka_render', d + '.tif'), 'ours_pre': pre, 'ours_enh': find(out, stem + '_enh.tiff')}
    for e in extra:
        k, v = e.split('=')
        srcs[k] = find(os.path.join(root, v), stem + '_enh.tiff')
    pairs.append({'id': d, 'delivery': red, 'group': g['group_id'], 'bracket': bool(g.get('is_bracket')), 'sources': srcs})
json.dump(pairs, open(dstjson, 'w'), indent=1)
print(len(pairs), sum(1 for p in pairs if all(p['sources'].values())))
