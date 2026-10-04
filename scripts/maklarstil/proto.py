"""Prototyp av Mäklarstil på registrerade bilder (ours_pre → leverans)."""
import json, sys, os, numpy as np, cv2
import pf

REG = os.path.expanduser('~/PhotoFlowBenchmark/pilvinge/reg')
QS = [0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99]

def load_png(p):
    im = cv2.imread(p, cv2.IMREAD_UNCHANGED)
    if im.ndim == 3:
        return cv2.cvtColor(im, cv2.COLOR_BGR2RGB).astype(np.float32) / 65535
    return im > 127

def dec(v): return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
def enc(v):
    v = np.clip(v, 0, 1); return np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)

def wb(im, frac=0.9, lim_t=0.5, lim_n=0.25, warm=0.0):
    y = pf.luma(im); mx, mn = im.max(2), im.min(2)
    sat = np.where(mx > 1e-3, (mx - mn) / np.maximum(mx, 1e-3), 0)
    m = (y > 0.30) & (y < 0.92) & (sat <= 0.25)
    if m.mean() < 0.02: return im
    lin = dec(im)
    r, g, b = [np.log2(max(lin[..., c][m].mean(), 1e-6)) for c in range(3)]
    k = 0.5
    conf = min(max((m.mean() - 0.02) / 0.08, 0), 1)
    t = np.clip((b - r) / (2 * k) * frac * conf, -lim_t, lim_t) + warm
    n = np.clip((g - (r + b) / 2) / k * frac * conf, -lim_n, lim_n)
    gains = np.array([2 ** (t * k), 2 ** (-n * k), 2 ** (-t * k)])
    return enc(lin * gains)

def curve_from_percentiles(src_q, targets, strength, top=0.97):
    xs = [0.0] + list(src_q) + [1.0]
    ys = [0.0] + [s + (t - s) * strength for s, t in zip(src_q, targets)] + [top]
    xs, ys = np.array(xs), np.array(ys)
    # strikt växande x; monotona y
    for i in range(1, len(xs)):
        xs[i] = max(xs[i], xs[i - 1] + 1e-3)
        ys[i] = max(ys[i], ys[i - 1] + 1e-4)
    # begränsa lutningar
    return xs, np.minimum(ys, top)

def pchip(xs, ys, x):
    from scipy.interpolate import PchipInterpolator
    return PchipInterpolator(xs, ys)(np.clip(x, 0, 1))

def apply_curve(im, xs, ys, mode):
    if mode == 'rgb':
        return np.clip(pchip(xs, ys, im), 0, 1)
    y = pf.luma(im)
    fy = pchip(xs, ys, y)
    ratio = fy / np.maximum(y, 1e-4)
    out = im * ratio[..., None]
    # mjuk överflödshantering: blanda mot per-kanal där ratio driver över 1
    pc = pchip(xs, ys, im)
    over = np.clip((out.max(2) - 0.98) / 0.1, 0, 1)[..., None]
    return np.clip(out * (1 - over) + pc * over, 0, 1)

def saturate(im, sat, hue_sat=None):
    lab = pf.srgb_to_lab(im)
    a, b = lab[..., 1], lab[..., 2]
    f = np.full(a.shape, sat, np.float32)
    if hue_sat is not None:
        h = np.degrees(np.arctan2(b, a)) % 360
        centers = np.array([c for _, c in pf.LAB_HUE_CENTERS], np.float32)
        w = np.zeros(a.shape + (8,), np.float32)
        for i, c in enumerate(centers):
            d = np.abs(((h - c + 180) % 360) - 180)
            w[..., i] = np.clip(1 - d / 45, 0, 1)
        ws = w.sum(-1, keepdims=True) + 1e-6
        f = f * ((w * np.array(hue_sat, np.float32)).sum(-1) / ws[..., 0] * (ws[..., 0] > 0.01) + (ws[..., 0] <= 0.01))
    lab[..., 1] *= f; lab[..., 2] *= f
    return np.clip(cv2.cvtColor(lab, cv2.COLOR_LAB2RGB), 0, 1)

def dE(a, b, m):
    d = pf.de2000(pf.srgb_to_lab(a), pf.srgb_to_lab(b))[m]
    return float(np.median(d)), float(np.percentile(d, 90))

def main():
    pairs = json.load(open(sys.argv[1]))
    ids = [p['id'] for p in pairs]
    test = set(ids[2::3]); train = [i for i in ids if i not in test]
    data = {}
    for i in ids:
        src = load_png(f'{REG}/{i}__ours_pre.png'); dst = load_png(f'{REG}/{i}__delivery.png')
        m = load_png(f'{REG}/{i}__ours_pre__valid.png')
        enh = load_png(f'{REG}/{i}__ours_enh.png'); me = load_png(f'{REG}/{i}__ours_enh__valid.png')
        data[i] = (src, dst, m, enh, m & me)
    # mål: median av leveransernas percentiler (träning)
    T = np.median([[np.quantile(pf.luma(data[i][1])[data[i][2]], q) for q in QS] for i in train], 0)
    print('mål-percentiler', np.round(T, 3))
    configs = {
        'rgb_s0.8': dict(mode='rgb', strength=0.8, sat=0.85),
        'lum_s0.8': dict(mode='lum', strength=0.8, sat=0.9),
        'lum_s1.0': dict(mode='lum', strength=1.0, sat=0.9),
        'rgb_s1.0': dict(mode='rgb', strength=1.0, sat=0.85),
        'lum_s0.8_sat1': dict(mode='lum', strength=0.8, sat=1.0),
        'lum_s0.8_sat0.8': dict(mode='lum', strength=0.8, sat=0.8),
    }
    rows = {k: [] for k in ['enh'] + list(configs)}
    for i in ids:
        src, dst, m, enh, mm = data[i]
        rows['enh'].append((i, *dE(enh, dst, mm)))
        w = wb(src)
        y = pf.luma(w)[m]
        sq = [np.quantile(y, q) for q in QS]
        for k, c in configs.items():
            xs, ys = curve_from_percentiles(sq, T, c['strength'])
            out = saturate(apply_curve(w, xs, ys, c['mode']), c['sat'])
            rows[k].append((i, *dE(out, dst, mm)))
            if k == 'lum_s0.8' and '--save' in sys.argv:
                cv2.imwrite(f'/tmp/claude-501/proto_{i}.jpg', cv2.cvtColor((out * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
    for k, r in rows.items():
        tr = [x for x in r if x[0] not in test]; te = [x for x in r if x[0] in test]
        print(f'{k:16s} train dE med {np.median([x[1] for x in tr]):5.2f} p90 {np.median([x[2] for x in tr]):5.2f} | test dE med {np.median([x[1] for x in te]):5.2f} p90 {np.median([x[2] for x in te]):5.2f}')

if __name__ == '__main__':
    main()
