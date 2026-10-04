"""windows.py — hur redigeraren behandlar fönstren jämfört med källexponeringarna och vår window pull."""
import json, os, glob, subprocess, numpy as np, cv2
import pf

ANA = os.path.dirname(os.path.abspath(__file__))
SHOOTS = {'': os.path.expanduser('~/PhotoFlowBenchmark/pilvinge')}
for s in ['bergstigen-105', 'pilottorget-3', 'ballonggatan-7', 'varmfrontsgatan-11']:
    SHOOTS[s] = os.path.expanduser(f'~/PhotoFlowBenchmark/shoots/{s}')
R = {}
for f in ['res-pilvinge-base.json', 'res-train3-base.json', 'res-test-base.json']:
    R.update(json.load(open(os.path.join(ANA, f))))
N = json.load(open(os.path.join(ANA, 'res-all-new.json'))) if os.path.exists(os.path.join(ANA, 'res-all-new.json')) else {}

def ring(mask, r0, r1):
    k1 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r1 + 1, 2 * r1 + 1))
    out = cv2.dilate(mask.astype(np.uint8), k1) > 0
    if r0 > 0:
        k0 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r0 + 1, 2 * r0 + 1))
        out &= ~(cv2.dilate(mask.astype(np.uint8), k0) > 0)
    return out

def stats(im, W, wall):
    lab = pf.srgb_to_lab(im); y = pf.luma(im)
    L = lab[..., 0]
    bp = cv2.GaussianBlur(L, (0, 0), 1) - cv2.GaussianBlur(L, (0, 0), 6)
    d = dict(win_median=float(np.median(y[W])), win_p99=float(np.percentile(y[W], 99)), win_p5=float(np.percentile(y[W], 5)),
             win_clip=float((im.max(2)[W] > 0.985).mean()), win_std=float(np.std(L[W])), win_detail=float(np.std(bp[W])),
             win_a=float(np.mean(lab[..., 1][W])), win_b=float(np.mean(lab[..., 2][W])),
             win_chroma=float(np.mean(np.hypot(lab[..., 1], lab[..., 2])[W])),
             win_blue_frac=float(((lab[..., 2] < -6) & (L > 40))[W].mean()))
    if wall is not None and wall.sum() > 300:
        d['wall_luma'] = float(np.median(y[wall])); d['win_rel_wall'] = d['win_median'] / max(d['wall_luma'], 1e-3)
        d['wall_b'] = float(np.mean(lab[..., 2][wall]))
    # halo: luma i ringar utanför fönstret relativt 24–48 px bort
    ref = ring(W, 24, 48)
    if ref.sum() > 200:
        base = np.median(L[ref])
        for r0, r1 in ((0, 4), (4, 10), (10, 24)):
            rr = ring(W, r0, r1)
            if rr.sum() > 100:
                d[f'halo_{r0}_{r1}'] = float(np.median(L[rr]) - base)
    return d

def main():
    out = {}
    tmp = '/tmp/claude-501/winframes'; os.makedirs(tmp, exist_ok=True)
    for k, r in R.items():
        shoot = k.split('/')[0] if '/' in k else ''
        root = SHOOTS[shoot]
        pre = r['sources'].get('ours_pre', {})
        if 'H' not in pre or 'hdr_group_' not in pre['path']:
            continue
        gid = os.path.basename(pre['path']).replace('.tiff', '')
        maskp = glob.glob(os.path.join(root, 'out-base', 'hdr_masks', gid + '.png'))
        if not maskp:
            continue
        m = cv2.imread(maskp[0], cv2.IMREAD_GRAYSCALE).astype(np.float32) / 255
        dst = pf.load(r['delivery'], 1600)
        src = pf.load(pre['path'], 1600)
        m = cv2.resize(m, (src.shape[1], src.shape[0]), interpolation=cv2.INTER_LINEAR)
        H = np.array(pre['H'])
        mw = cv2.warpPerspective(m, H, (dst.shape[1], dst.shape[0]))
        W = cv2.erode((mw > 0.5).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
        if W.mean() < 0.003:
            continue
        labd = pf.srgb_to_lab(dst)
        Cd = np.hypot(labd[..., 1], labd[..., 2])
        wall = (Cd < 8) & (labd[..., 0] > 70) & ~ring(W, 0, 30) & ~W
        e = {'mask_frac': float(W.mean()), 'group': gid}
        e['dst'] = stats(dst, W, wall)
        for name, path, Hs in (('ours_enh', r['sources']['ours_enh']['path'], r['sources']['ours_enh'].get('H')),
                               ('ours_pre', pre['path'], pre['H']),
                               ('ours_new', N.get(k, {}).get('sources', {}).get('ours_new', {}).get('path'), N.get(k, {}).get('sources', {}).get('ours_new', {}).get('H'))):
            if not path or Hs is None:
                continue
            im = pf.load(path, 1600)
            ws, valid = pf.warp(im, np.array(Hs), dst.shape)
            WW = W & valid
            if WW.sum() > 200:
                e[name] = stats(ws, WW, wall & valid)
        # Källexponeringar: vilken ram liknar utsikten mest?
        frames = []
        nefdir = os.path.join(root, 'nef')
        pair = json.load(open(os.path.join(ANA, 'pairs-pilvinge.json' if shoot == '' else f'pairs-{shoot}.json')))
        fr = None
        for p in pair:
            if p['id'] == k:
                fr = p
        bg = json.load(open(os.path.join(root, 'out-base', 'bracket_groups.json')))['groups']
        g = next((g for g in bg if f"hdr_group_{g['group_id']}" == gid), None)
        if g:
            ev = []
            for f in g['files']:
                tif = os.path.join(tmp, f"{shoot}_{f}.tif")
                if not os.path.exists(tif):
                    subprocess.run([os.path.join(ANA, 'render-raw'), '1600', os.path.join(nefdir, f), tif], capture_output=True)
                im = pf.load(tif, 1600)
                Hf, n, _ = pf.register(im, dst, min_inliers=25)
                if Hf is None:
                    Hf = H  # samma kamerastativ: HDR-geometrin duger
                ws, valid = pf.warp(im, Hf, dst.shape)
                WW = W & valid
                if WW.sum() < 200:
                    continue
                ld = np.log(pf.luma(dst)[WW] + 0.01); lf = np.log(pf.luma(ws)[WW] + 0.01)
                gd = cv2.Laplacian(pf.luma(dst), cv2.CV_32F)[WW]; gf = cv2.Laplacian(pf.luma(ws), cv2.CV_32F)[WW]
                ev.append(dict(file=f, median=float(np.median(pf.luma(ws)[WW])), clip=float((ws.max(2)[WW] > 0.985).mean()),
                               corr=float(np.corrcoef(ld, lf)[0, 1]) if lf.std() > 1e-4 else 0.0,
                               gcorr=float(np.corrcoef(gd, gf)[0, 1]) if gf.std() > 1e-6 else 0.0))
            e['frames'] = ev
            if ev:
                best = max(ev, key=lambda x: x['gcorr'] - 2 * x['clip'])
                order = sorted(ev, key=lambda x: x['median'])
                e['best_frame_rank_from_dark'] = order.index(best)
                e['n_frames'] = len(ev)
                e['best_frame'] = best['file']
        out[k] = e
        print(k, gid, 'mask %.3f' % e['mask_frac'], 'dst win %.2f/%.2f rel %.2f' % (e['dst']['win_median'], e['dst']['win_p99'], e['dst'].get('win_rel_wall', float('nan'))),
              'enh %.2f' % e.get('ours_enh', {}).get('win_median', float('nan')), 'best', e.get('best_frame_rank_from_dark'), '/', e.get('n_frames'), flush=True)
    json.dump(out, open(os.path.join(ANA, 'windows.json'), 'w'), indent=1)

if __name__ == '__main__':
    main()
