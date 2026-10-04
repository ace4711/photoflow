"""analyze.py <pairs.json> <out.json> [--save DIR]
pairs.json: [{"id":..., "delivery": path, "sources": {"namn": path, ...}}]
Registrerar varje källa mot leveransen och mäter receptet (källa → leverans)."""
import sys, json, os, numpy as np, cv2
import pf

WORK = 1600

def bandpass_std(L, s1, s2, mask):
    a = cv2.GaussianBlur(L, (0, 0), s1) if s1 > 0 else L
    b = cv2.GaussianBlur(L, (0, 0), s2)
    return float(np.std((a - b)[mask]))

def robust_std(x):
    return float(1.4826 * np.median(np.abs(x - np.median(x)))) if x.size else float('nan')

def tone_curve(ls, ld, mask, nb=32):
    edges = np.linspace(0, 1, nb + 1)
    xs, ys = [], []
    s, d = ls[mask], ld[mask]
    for i in range(nb):
        m = (s >= edges[i]) & (s < edges[i + 1])
        if m.sum() > 200:
            xs.append(float((edges[i] + edges[i + 1]) / 2)); ys.append(float(np.median(d[m])))
    return xs, ys

def interp_curve(xs, ys, x):
    return np.interp(x, xs, ys) if xs else x

def pair_metrics(src, dst, H, valid, src_full=None, dst_full=None, H_full=None):
    r = {}
    ws = src  # registrerad
    ls, ld = pf.luma(ws), pf.luma(dst)
    labs, labd = pf.srgb_to_lab(ws), pf.srgb_to_lab(dst)
    m = valid
    de = pf.de2000(labs, labd)
    r['dE_median'] = float(np.median(de[m])); r['dE_p90'] = float(np.percentile(de[m], 90))
    # luminanshistogramavstånd (EMD i luma, 0..1)
    hs = np.histogram(ls[m], 256, (0, 1))[0].astype(float); hd = np.histogram(ld[m], 256, (0, 1))[0].astype(float)
    r['hist_emd'] = float(np.sum(np.abs(np.cumsum(hs / hs.sum()) - np.cumsum(hd / hd.sum()))) / 256)
    for q in (1, 5, 25, 50, 75, 95, 99):
        r[f'src_p{q}'] = float(np.percentile(ls[m], q)); r[f'dst_p{q}'] = float(np.percentile(ld[m], q))
    xs, ys = tone_curve(ls, ld, m)
    r['curve_x'], r['curve_y'] = xs, ys
    for x in (0.05, 0.1, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9, 0.95):
        r[f'curve_{x}'] = float(interp_curve(xs, ys, x))
    # neutrala ytor (enligt leveransen)
    Cd = np.hypot(labd[..., 1], labd[..., 2]); Cs = np.hypot(labs[..., 1], labs[..., 2])
    neu = m & (Cd < 6) & (labd[..., 0] > 50) & (labd[..., 0] < 97)
    r['neutral_frac'] = float(neu.mean())
    if neu.sum() > 500:
        r['neutral_dst_a'], r['neutral_dst_b'] = float(np.mean(labd[..., 1][neu])), float(np.mean(labd[..., 2][neu]))
        r['neutral_src_a'], r['neutral_src_b'] = float(np.mean(labs[..., 1][neu])), float(np.mean(labs[..., 2][neu]))
    wall = m & (Cd < 8) & (labd[..., 0] > 80) & (labd[..., 0] < 99)
    r['wall_frac'] = float(wall.mean())
    if wall.sum() > 500:
        r['wall_dst_L'] = float(np.median(labd[..., 0][wall])); r['wall_src_L'] = float(np.median(labs[..., 0][wall]))
        r['wall_dst_a'], r['wall_dst_b'] = float(np.mean(labd[..., 1][wall])), float(np.mean(labd[..., 2][wall]))
        r['wall_src_a'], r['wall_src_b'] = float(np.mean(labs[..., 1][wall])), float(np.mean(labs[..., 2][wall]))
    # mättnad per nyans (källans nyans)
    hue = np.degrees(np.arctan2(labs[..., 2], labs[..., 1])) % 360
    hued = np.degrees(np.arctan2(labd[..., 2], labd[..., 1])) % 360
    col = m & (Cs > 10) & (labs[..., 0] > 20) & (labs[..., 0] < 92) & (Cd > 3)
    r['sat_mean_src'] = float(np.mean(Cs[m])); r['sat_mean_dst'] = float(np.mean(Cd[m]))
    centers = [c for _, c in pf.LAB_HUE_CENTERS]
    for i, (name, c) in enumerate(pf.LAB_HUE_CENTERS):
        lo = (c + centers[i - 1] - (360 if i == 0 else 0)) / 2
        hi = (c + (centers[(i + 1) % 8] + (360 if i == 7 else 0))) / 2
        hh = (hue - lo) % 360
        sel = col & (hh < (hi - lo))
        if sel.sum() > 300:
            r[f'hsl_{name}_frac'] = float(sel.mean())
            r[f'hsl_{name}_sat'] = float(np.median(Cd[sel] / Cs[sel]))
            dh = ((hued[sel] - hue[sel] + 180) % 360) - 180
            r[f'hsl_{name}_hue'] = float(np.median(dh))
            r[f'hsl_{name}_lum'] = float(np.median(labd[..., 0][sel] - labs[..., 0][sel]))
    # lokal kontrast (1600 px): textur 1–4 px, clarity 4–16 px, stor 16–64 px
    Ls, Ld = labs[..., 0], labd[..., 0]
    mm = cv2.erode(m.astype(np.uint8), np.ones((65, 65), np.uint8)).astype(bool)
    if mm.sum() > 1000:
        for name, s1, s2 in (('texture', 1, 4), ('clarity', 4, 16), ('large', 16, 64)):
            r[f'bp_{name}_ratio'] = bandpass_std(Ld, s1, s2, mm) / max(bandpass_std(Ls, s1, s2, mm), 1e-6)
    # vinjettering: residual efter tonkurvan vs radie
    h, w = ld.shape
    yy, xx = np.mgrid[0:h, 0:w]
    rad = np.hypot((xx - w / 2) / (w / 2), (yy - h / 2) / (h / 2)) / np.sqrt(2)
    res = ld - interp_curve(xs, ys, ls)
    ok = m & (ls > 0.1) & (ls < 0.9)
    c0 = ok & (rad < 0.3); c1 = ok & (rad > 0.8)
    if c0.sum() > 200 and c1.sum() > 200:
        r['vignette_corner_minus_center'] = float(np.median(res[c1]) - np.median(res[c0]))
    # geometri ur H (källa → leverans), i normerade koordinater
    r['H'] = H.tolist()
    # brus och skärpa på full upplösning
    if src_full is not None:
        lsF, ldF = pf.srgb_to_lab(src_full)[..., 0], pf.srgb_to_lab(dst_full)[..., 0]
        vF = H_full
        base = cv2.GaussianBlur(ldF, (0, 0), 3)
        gx, gy = cv2.Sobel(base, cv2.CV_32F, 1, 0), cv2.Sobel(base, cv2.CV_32F, 0, 1)
        gm = np.hypot(gx, gy)
        baseS = cv2.GaussianBlur(lsF, (0, 0), 3)
        gmS = np.hypot(cv2.Sobel(baseS, cv2.CV_32F, 1, 0), cv2.Sobel(baseS, cv2.CV_32F, 0, 1))
        flat = vF & (gm < np.percentile(gm[vF], 20)) & (gmS < np.percentile(gmS[vF], 20)) & (base > 30) & (base < 95)
        hpd = ldF - cv2.GaussianBlur(ldF, (0, 0), 1.5); hps = lsF - cv2.GaussianBlur(lsF, (0, 0), 1.5)
        if flat.sum() > 2000:
            r['noise_dst'] = robust_std(hpd[flat]); r['noise_src'] = robust_std(hps[flat])
            abd = pf.srgb_to_lab(dst_full); abs_ = pf.srgb_to_lab(src_full)
            cd = [robust_std((abd[..., k] - cv2.GaussianBlur(abd[..., k], (0, 0), 1.5))[flat]) for k in (1, 2)]
            cs = [robust_std((abs_[..., k] - cv2.GaussianBlur(abs_[..., k], (0, 0), 1.5))[flat]) for k in (1, 2)]
            r['chroma_noise_dst'] = float(np.mean(cd)); r['chroma_noise_src'] = float(np.mean(cs))
        edge = vF & (gm > np.percentile(gm[vF], 95)) & (gmS > np.percentile(gmS[vF], 90))
        if edge.sum() > 2000:
            bd = cv2.GaussianBlur(ldF, (0, 0), 0.7) - cv2.GaussianBlur(ldF, (0, 0), 2.0)
            bs = cv2.GaussianBlur(lsF, (0, 0), 0.7) - cv2.GaussianBlur(lsF, (0, 0), 2.0)
            # normera med kantens kontrast (grov skala) så att tonkurvan inte räknas som skärpa
            cdn = cv2.GaussianBlur(ldF, (0, 0), 2.0) - cv2.GaussianBlur(ldF, (0, 0), 6.0)
            csn = cv2.GaussianBlur(lsF, (0, 0), 2.0) - cv2.GaussianBlur(lsF, (0, 0), 6.0)
            r['sharp_dst'] = float(np.std(bd[edge]) / max(np.std(cdn[edge]), 1e-6))
            r['sharp_src'] = float(np.std(bs[edge]) / max(np.std(csn[edge]), 1e-6))
    return r

def tilt_stats(im):
    ang, ln, xm = pf.vertical_tilts(im)
    if ang.size < 4:
        return {}
    wgt = ln
    out = {'vert_n': int(ang.size), 'vert_abs_median': float(np.median(np.abs(ang))),
           'vert_weighted_abs': float(np.sum(np.abs(ang) * wgt) / np.sum(wgt))}
    # konvergens: vinkel ≈ a + b·x  (b = keystone, a = rotation)
    A = np.stack([np.ones_like(xm), xm], 1) * np.sqrt(wgt)[:, None]
    sol = np.linalg.lstsq(A, ang * np.sqrt(wgt), rcond=None)[0]
    out['vert_rotation'] = float(sol[0]); out['vert_keystone'] = float(sol[1])
    return out

def main():
    pairs = json.load(open(sys.argv[1])); out_path = sys.argv[2]
    save = sys.argv[sys.argv.index('--save') + 1] if '--save' in sys.argv else None
    full = '--full' in sys.argv
    results = json.load(open(out_path)) if os.path.exists(out_path) else {}
    for p in pairs:
        pid = p['id']
        if pid in results and '--force' not in sys.argv:
            continue
        dst_path = p['delivery']
        dst = pf.load(dst_path, WORK)
        res = {'delivery': dst_path, 'dst_tilt': tilt_stats(dst), 'sources': {}}
        dst_full = pf.load(dst_path) if full else None
        for name, sp in p['sources'].items():
            if not sp or not os.path.exists(sp):
                continue
            src = pf.load(sp, WORK)
            H, n, rms = pf.register(src, dst)
            entry = {'path': sp, 'inliers': n, 'rms': rms, 'src_tilt': tilt_stats(src)}
            if H is None:
                entry['failed'] = True; res['sources'][name] = entry; continue
            ws, valid = pf.warp(src, H, dst.shape)
            hs, ws_ = src.shape[:2]
            corners = np.float32([[0, 0], [dst.shape[1], 0], [dst.shape[1], dst.shape[0]], [0, dst.shape[0]]])
            back = cv2.perspectiveTransform(corners[None], np.linalg.inv(H))[0]
            entry['visible_fraction'] = float(cv2.contourArea(back) / (hs * ws_))
            sf = df = Hf = None
            if full and name != 'skicka':
                sfull = pf.load(sp)
                S1 = np.diag([sfull.shape[1] / src.shape[1], sfull.shape[0] / src.shape[0], 1])
                S2 = np.diag([dst_full.shape[1] / dst.shape[1], dst_full.shape[0] / dst.shape[0], 1])
                Hfull = S2 @ H @ np.linalg.inv(S1)
                sf, Hf = pf.warp(sfull, Hfull, dst_full.shape)
                df = dst_full
                del sfull
            entry.update(pair_metrics(ws, dst, H, valid, sf, df, Hf))
            if save:
                os.makedirs(save, exist_ok=True)
                cv2.imwrite(os.path.join(save, f'{pid.replace("/", "__")}__{name}.png'), cv2.cvtColor((ws * 65535).astype(np.uint16), cv2.COLOR_RGB2BGR))
                cv2.imwrite(os.path.join(save, f'{pid.replace("/", "__")}__{name}__valid.png'), valid.astype(np.uint8) * 255)
            res['sources'][name] = entry
            print(pid, name, 'inl', n, 'rms %.2f' % rms, 'dE %.1f' % entry['dE_median'], flush=True)
        if save:
            cv2.imwrite(os.path.join(save, f'{pid.replace("/", "__")}__delivery.png'), cv2.cvtColor((dst * 65535).astype(np.uint16), cv2.COLOR_RGB2BGR))
        results[pid] = res
        json.dump(results, open(out_path, 'w'), indent=1)

if __name__ == '__main__':
    main()
