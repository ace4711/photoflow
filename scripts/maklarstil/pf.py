"""Gemensamma verktyg för par-analysen: läsning, registrering, mått."""
import cv2, numpy as np

def load(path, long_side=None):
    im = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if im is None:
        raise IOError(path)
    if im.ndim == 3 and im.shape[2] == 4:
        im = im[:, :, :3]
    scale = 65535.0 if im.dtype == np.uint16 else 255.0
    im = cv2.cvtColor(im, cv2.COLOR_BGR2RGB).astype(np.float32) / scale
    if long_side:
        h, w = im.shape[:2]
        s = long_side / max(h, w)
        if s < 1:
            im = cv2.resize(im, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)
    return im

def luma(im):
    return 0.2126 * im[..., 0] + 0.7152 * im[..., 1] + 0.0722 * im[..., 2]

def _feat_img(im):
    g = (np.clip(luma(im), 0, 1) * 255).astype(np.uint8)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    return clahe.apply(cv2.equalizeHist(g))

def register(src, dst, min_inliers=40):
    """Homografi H så att dst ≈ warp(src, H). Returnerar (H, inliers, rms) eller (None, …)."""
    sift = cv2.SIFT_create(nfeatures=8000)
    a, b = _feat_img(src), _feat_img(dst)
    ka, da = sift.detectAndCompute(a, None)
    kb, db = sift.detectAndCompute(b, None)
    if da is None or db is None:
        return None, 0, None
    m = cv2.FlannBasedMatcher(dict(algorithm=1, trees=5), dict(checks=64)).knnMatch(da, db, k=2)
    good = [x[0] for x in m if len(x) == 2 and x[0].distance < 0.75 * x[1].distance]
    if len(good) < min_inliers:
        return None, len(good), None
    pa = np.float32([ka[g.queryIdx].pt for g in good])
    pb = np.float32([kb[g.trainIdx].pt for g in good])
    H, inl = cv2.findHomography(pa, pb, cv2.USAC_MAGSAC, 2.0, maxIters=10000, confidence=0.9999)
    if H is None:
        return None, 0, None
    inl = inl.ravel().astype(bool)
    proj = cv2.perspectiveTransform(pa[inl][None], H)[0]
    rms = float(np.sqrt(np.mean(np.sum((proj - pb[inl]) ** 2, axis=1))))
    if inl.sum() < min_inliers:
        return None, int(inl.sum()), rms
    # Förfina med ECC (gradienter, exponeringsoberoende nog efter equalize)
    return H, int(inl.sum()), rms

def warp(src, H, shape):
    h, w = shape[:2]
    out = cv2.warpPerspective(src, H, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(-1, -1, -1))
    valid = (out[..., 0] >= 0)
    valid = cv2.erode(valid.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool)
    return np.clip(out, 0, 1), valid

# --- färg ---
def srgb_to_lab(im):
    return cv2.cvtColor(np.clip(im, 0, 1).astype(np.float32), cv2.COLOR_RGB2LAB)  # L 0..100, a,b ±127

def de2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cm = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dh = h2p - h1p
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(C1p * C2p == 0, 0, dh)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lpm, Cpm = (L1 + L2) / 2, (C1p + C2p) / 2
    hs = h1p + h2p
    hpm = np.where(C1p * C2p == 0, hs, np.where(np.abs(h1p - h2p) <= 180, hs / 2, np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2)))
    T = 1 - 0.17 * np.cos(np.radians(hpm - 30)) + 0.24 * np.cos(np.radians(2 * hpm)) + 0.32 * np.cos(np.radians(3 * hpm + 6)) - 0.20 * np.cos(np.radians(4 * hpm - 63))
    dth = 30 * np.exp(-((hpm - 275) / 25) ** 2)
    Rc = 2 * np.sqrt(Cpm ** 7 / (Cpm ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lpm - 50) ** 2 / np.sqrt(20 + (Lpm - 50) ** 2)
    Sc = 1 + 0.045 * Cpm
    Sh = 1 + 0.015 * Cpm * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))

HUES = [("röd", 0), ("orange", 45), ("gul", 80), ("grön", 140), ("cyan", 200), ("blå", 260), ("lila", 300), ("magenta", 340)]
# Lab-nyansvinkel (a,b) ungefärliga centrum för Lightrooms HSL-band.
LAB_HUE_CENTERS = [("röd", 30), ("orange", 55), ("gul", 85), ("grön", 135), ("cyan", 200), ("blå", 265), ("lila", 305), ("magenta", 345)]

# --- lodlinjer ---
def vertical_tilts(im, min_len_frac=0.06, max_dev=20):
    """Lutning (grader från lodrätt, + = toppen åt höger) för nästan lodräta linjesegment.
    Returnerar (vinklar, längder, x-mittpunkt normerad -1..1)."""
    g = (np.clip(luma(im), 0, 1) * 255).astype(np.uint8)
    h, w = g.shape
    lsd = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD)
    lines = lsd.detect(g)[0]
    if lines is None:
        return np.array([]), np.array([]), np.array([])
    L = lines.reshape(-1, 4)
    dx, dy = L[:, 2] - L[:, 0], L[:, 3] - L[:, 1]
    length = np.hypot(dx, dy)
    # vinkel från lodrätt, topp åt höger positiv (y nedåt i bilden)
    sgn = np.where(dy < 0, 1, -1)
    ang = np.degrees(np.arctan2(dx * sgn, -dy * sgn))
    ok = (length > min_len_frac * h) & (np.abs(ang) < max_dev)
    xm = ((L[:, 0] + L[:, 2]) / 2 / w) * 2 - 1
    return ang[ok], length[ok], xm[ok]
