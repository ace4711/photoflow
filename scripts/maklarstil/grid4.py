"""grid4.py <ut.jpg> <leverans> namn=sökväg ... — 2×2 (eller fler), registrerat mot leveransen, 2000 px brett."""
import sys, os, cv2, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import pf
out, dl = sys.argv[1], sys.argv[2]
items = [a.split('=', 1) for a in sys.argv[3:]] + [['leverans', dl]]
d = pf.load(dl, 1600)
tiles, valid = [], None
for name, p in items:
    im = pf.load(p, 1600)
    if p == dl: w, v = d, np.ones(d.shape[:2], bool)
    else:
        H, n, _ = pf.register(im, d, 25); w, v = pf.warp(im, H, d.shape)
    valid = v if valid is None else valid & v
    tiles.append((name, w))
ys, xs = np.where(valid); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
res = []
for name, w in tiles:
    c = (np.clip(w[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8)[..., ::-1]
    c = cv2.resize(c, (1000, round(c.shape[0] * 1000 / c.shape[1])), interpolation=cv2.INTER_AREA).copy()
    cv2.rectangle(c, (0, 0), (len(name) * 17 + 16, 38), (0, 0, 0), -1)
    cv2.putText(c, name, (8, 27), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2, cv2.LINE_AA)
    res.append(c)
if len(res) % 2: res.append(np.zeros_like(res[0]))
grid = np.vstack([np.hstack(res[i:i + 2]) for i in range(0, len(res), 2)])
cv2.imwrite(out, grid, [cv2.IMWRITE_JPEG_QUALITY, 85]); print(out, grid.shape)
