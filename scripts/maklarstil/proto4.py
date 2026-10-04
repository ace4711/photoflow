"""Prototyp v2: interiör/exteriör-blandning. Kör på alla registrerade par (ours_pre → leverans)."""
import json, sys, os, glob, numpy as np, cv2, itertools
import pf
from proto import wb, curve_from_percentiles, apply_curve, saturate, dE, QS
from extdet import outdoor

INT_T = [0.095, 0.209, 0.482, 0.685, 0.801, 0.905, 0.963]
EXT_T = [0.042, 0.129, 0.335, 0.568, 0.742, 0.886, 0.957]
PIL_TEST = {'DSC_9053', 'DSC_9074', 'DSC_9100', 'DSC_9117', 'DSC_9144', 'DSC_9160', 'DSC_9185'}

def rd(p):
    im = cv2.imread(p, cv2.IMREAD_UNCHANGED)
    return (cv2.cvtColor(im, cv2.COLOR_BGR2RGB).astype(np.float32) / 65535) if im.ndim == 3 else im > 127

def items(src='ours_pre'):
    out = []
    for d in [os.path.expanduser('~/PhotoFlowBenchmark/pilvinge/reg'), os.path.expanduser('~/PhotoFlowBenchmark/shoots/reg')]:
        for f in sorted(glob.glob(f'{d}/*__{src}.png')):
            k = os.path.basename(f)[:-len(f'__{src}.png')]
            out.append((k.replace('__', '/'), f, f'{d}/{k}__delivery.png', f'{d}/{k}__{src}__valid.png'))
    return out

def ext_weight(im):
    v, s = outdoor(cv2.resize(im, (512, 341)))
    return float(np.clip((v + s - 0.08) / 0.17, 0, 1))

def render(src, cfg, wext):
    w = wb(src, frac=1.0)
    y = pf.luma(w)
    sq = [np.quantile(y, q) for q in QS]
    T = [a + (b - a) * wext for a, b in zip(cfg['int_t'], cfg['ext_t'])]
    xs, ys = curve_from_percentiles(sq, T, 1.0)
    sat = cfg['int_sat'] + (cfg['ext_sat'] - cfg['int_sat']) * wext
    hue = [a + (b - a) * wext for a, b in zip(cfg['int_hue'], cfg['ext_hue'])]
    return saturate(apply_curve(w, xs, ys, 'lum'), sat, hue)

def main():
    test_shoot = sys.argv[1] if len(sys.argv) > 1 else 'varmfrontsgatan-11'
    data = []
    for k, fs, fd, fv in items():
        src, dst, m = rd(fs), rd(fd), rd(fv)
        data.append((k, src, dst, m, ext_weight(src)))
    def is_test(k): return k in PIL_TEST or k.startswith(test_shoot)
    base = dict(int_t=INT_T, ext_t=EXT_T, int_sat=0.85, ext_sat=1.3,
                int_hue=[1, 0.9, 0.8, 1, 1, 1.1, 1, 1], ext_hue=[1, 1, 1, 1, 1, 1, 0.7, 1])
    grid = {'base': base}
    for es in (1.0, 1.15, 1.3, 1.45, 1.6):
        grid[f'ext_sat{es}'] = dict(base, ext_sat=es)
    for isat in (0.75, 0.8, 0.9):
        grid[f'int_sat{isat}'] = dict(base, int_sat=isat)
    grid['int_hue_blue1'] = dict(base, int_hue=[1, 0.9, 0.8, 1, 1, 1.0, 1, 1])
    grid['int_hue_flat'] = dict(base, int_hue=[1] * 8)
    grid['no_ext'] = dict(base, ext_t=INT_T, ext_sat=0.85, ext_hue=base['int_hue'])
    res = {}
    for name, cfg in grid.items():
        r = []
        for k, src, dst, m, we in data:
            r.append((k, we) + dE(render(src, cfg, we), dst, m))
        res[name] = r
        tr = [x for x in r if not is_test(x[0])]
        te = [x for x in r if is_test(x[0])]
        ex = [x for x in tr if x[1] > 0.5]
        print(f'{name:14s} train {np.median([x[2] for x in tr]):5.2f}/{np.median([x[3] for x in tr]):5.2f}  ext-train {np.median([x[2] for x in ex]):5.2f}  test {np.median([x[2] for x in te]):5.2f}/{np.median([x[3] for x in te]):5.2f}', flush=True)
    json.dump(res, open('proto4.json', 'w'))

if __name__ == '__main__':
    main()
