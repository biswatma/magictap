#!/usr/bin/env python3
"""Find a feature that separates left taps from right taps.

Usage:
    python3 tools/analyze.py left.csv right.csv

Each CSV comes from `magictap record` and holds one labelled session: tap only
on that side, varying force, for twenty or so taps.

The first run of `magictap tap` showed why a single-axis sign test fails on this
hardware: vertical (z) motion dominates every tap, and the lateral response is
asymmetric rather than mirrored, because the IMU is not centred in the chassis.
So this script does not assume a discriminator. It segments taps, extracts a
wide bank of candidate features, and ranks them by how well each one actually
separates the two labelled sets — then fits a linear combination and reports
leave-one-out accuracy so the number is not just the training fit.
"""

import sys
import csv
import math
import itertools
import numpy as np

# Segmentation, kept close to TapDetector.swift so findings transfer.
GRAVITY_ALPHA = 0.01
THRESHOLD_G = 0.05
REFRACTORY_S = 0.25
PRE_MS = 10.0     # window kept before the peak
POST_MS = 40.0    # and after


def load(path):
    t, xyz = [], []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            t.append(float(row["t"]))
            xyz.append((float(row["x"]), float(row["y"]), float(row["z"])))
    if not t:
        sys.exit(f"{path}: no samples")
    return np.array(t), np.array(xyz)


def linear_acceleration(xyz):
    """Subtract a slow gravity estimate, freezing it during transients."""
    g = xyz[0].copy()
    out = np.empty_like(xyz)
    for i, s in enumerate(xyz):
        resid = s - g
        if np.linalg.norm(resid) < THRESHOLD_G * 0.5:
            g += GRAVITY_ALPHA * (s - g)
        out[i] = s - g
    return out


def segment(t, lin):
    """Return (peak_index, window_slice) for each detected tap."""
    mag = np.linalg.norm(lin, axis=1)
    rate = len(t) / max(t[-1] - t[0], 1e-9)
    pre = int(PRE_MS * 1e-3 * rate)
    post = int(POST_MS * 1e-3 * rate)

    taps = []
    i = 0
    last_t = -1e9
    while i < len(mag):
        if mag[i] < THRESHOLD_G or t[i] - last_t < REFRACTORY_S:
            i += 1
            continue
        # Walk to the local maximum of this excursion.
        j = i
        while j + 1 < len(mag) and mag[j + 1] >= THRESHOLD_G * 0.3:
            j += 1
            if j - i > post * 2:
                break
        peak = i + int(np.argmax(mag[i:j + 1]))
        lo, hi = max(0, peak - pre), min(len(mag), peak + post)
        if hi - lo > 4:
            taps.append((peak, slice(lo, hi)))
            last_t = t[peak]
        i = max(j + 1, peak + 1)
    return taps, rate


def features(lin, peak, win):
    """A bank of candidate discriminators for one tap."""
    w = lin[win]
    mag = np.linalg.norm(w, axis=1)
    pk = lin[peak]
    pkmag = np.linalg.norm(pk)
    if pkmag < 1e-9:
        return None

    f = {}
    # Direction at the peak, normalised so force cancels out.
    f["peak_x/|v|"] = pk[0] / pkmag
    f["peak_y/|v|"] = pk[1] / pkmag
    f["peak_z/|v|"] = pk[2] / pkmag
    lateral = math.hypot(pk[0], pk[1])
    f["lateral/|v|"] = lateral / pkmag
    f["lateral_angle"] = math.atan2(pk[1], pk[0])

    # Onset direction at several fractions of the peak.
    for frac in (0.15, 0.25, 0.40):
        idx = peak
        gate = pkmag * frac
        k = peak
        while k >= win.start and np.linalg.norm(lin[k]) >= gate:
            idx = k
            k -= 1
        o = lin[idx]
        omag = np.linalg.norm(o) or 1e-9
        f[f"onset{int(frac*100)}_x/|v|"] = o[0] / omag
        f[f"onset{int(frac*100)}_y/|v|"] = o[1] / omag
        f[f"onset{int(frac*100)}_z/|v|"] = o[2] / omag

    # Energy split across axes over the whole window.
    energy = (w ** 2).sum(axis=0)
    total = energy.sum() or 1e-9
    f["energy_x_frac"] = energy[0] / total
    f["energy_y_frac"] = energy[1] / total
    f["energy_z_frac"] = energy[2] / total

    # Signed impulse: net displacement of each axis, force-normalised.
    impulse = w.sum(axis=0)
    inorm = np.linalg.norm(impulse) or 1e-9
    f["impulse_x/|i|"] = impulse[0] / inorm
    f["impulse_y/|i|"] = impulse[1] / inorm
    f["impulse_z/|i|"] = impulse[2] / inorm

    # Cross-axis correlations — how x and y move relative to z.
    if w.shape[0] > 3:
        for a, b in (("x", "y"), ("x", "z"), ("y", "z")):
            ia, ib = "xyz".index(a), "xyz".index(b)
            sa, sb = w[:, ia], w[:, ib]
            denom = (sa.std() * sb.std()) or 1e-9
            f[f"corr_{a}{b}"] = float(((sa - sa.mean()) * (sb - sb.mean())).mean() / denom)

    f["peak_g"] = pkmag  # force itself, as a control — it should NOT separate
    return f


def collect(path):
    t, xyz = load(path)
    lin = linear_acceleration(xyz)
    taps, rate = segment(t, lin)
    rows = [f for peak, win in taps if (f := features(lin, peak, win)) is not None]
    return rows, rate


def dprime(a, b):
    sa, sb = a.std(), b.std()
    pooled = math.sqrt((sa ** 2 + sb ** 2) / 2) or 1e-9
    return abs(a.mean() - b.mean()) / pooled


def best_threshold(a, b):
    """Best single-threshold accuracy, and the threshold achieving it."""
    vals = np.concatenate([a, b])
    cuts = (np.sort(vals)[:-1] + np.sort(vals)[1:]) / 2
    best = (0.0, 0.0, 1)
    for c in cuts:
        for sign in (1, -1):
            acc = (np.sum(sign * a < sign * c) + np.sum(sign * b >= sign * c)) / (len(a) + len(b))
            if acc > best[0]:
                best = (acc, float(c), sign)
    return best


def lda_loo(A, B):
    """Leave-one-out accuracy of a Fisher linear discriminant."""
    X = np.vstack([A, B])
    y = np.array([0] * len(A) + [1] * len(B))
    correct = 0
    for i in range(len(X)):
        mask = np.ones(len(X), bool)
        mask[i] = False
        Xt, yt = X[mask], y[mask]
        m0, m1 = Xt[yt == 0].mean(0), Xt[yt == 1].mean(0)
        cov = np.cov(Xt.T) + np.eye(Xt.shape[1]) * 1e-6
        try:
            w = np.linalg.solve(cov, m1 - m0)
        except np.linalg.LinAlgError:
            continue
        cut = w @ (m0 + m1) / 2
        correct += int((X[i] @ w > cut) == bool(y[i]))
    return correct / len(X)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    left_path, right_path = sys.argv[1], sys.argv[2]

    left, lrate = collect(left_path)
    right, rrate = collect(right_path)
    print(f"left : {len(left):3d} taps from {left_path} ({lrate:.0f} Hz)")
    print(f"right: {len(right):3d} taps from {right_path} ({rrate:.0f} Hz)")
    if len(left) < 4 or len(right) < 4:
        sys.exit("\nneed at least ~4 taps per side; lower THRESHOLD_G or record more")

    names = [k for k in left[0] if all(k in r for r in left + right)]
    L = {k: np.array([r[k] for r in left]) for k in names}
    R = {k: np.array([r[k] for r in right]) for k in names}

    ranked = []
    for k in names:
        acc, cut, sign = best_threshold(L[k], R[k])
        ranked.append((acc, dprime(L[k], R[k]), k, cut, sign))
    ranked.sort(reverse=True)

    print(f"\n{'feature':22s} {'acc':>6s} {'d-prime':>8s} {'threshold':>10s} "
          f"{'left mean':>10s} {'right mean':>10s}")
    print("-" * 72)
    for acc, dp, k, cut, sign in ranked:
        flag = "  <-- force, should be ~0.5" if k == "peak_g" else ""
        print(f"{k:22s} {acc:6.1%} {dp:8.2f} {cut:10.4f} "
              f"{L[k].mean():10.4f} {R[k].mean():10.4f}{flag}")

    print("\nbest single feature:")
    acc, dp, k, cut, sign = ranked[0]
    rel = "<" if sign > 0 else ">"
    print(f"  {k} {rel} {cut:.4f}  =>  left     ({acc:.1%} on this data, d'={dp:.2f})")

    # Small combinations, in case no single feature is enough.
    top = [r[2] for r in ranked[:6] if r[2] != "peak_g"]
    print("\nlinear combinations (leave-one-out accuracy):")
    best_combo = None
    for size in (2, 3):
        for combo in itertools.combinations(top, size):
            A = np.column_stack([L[k] for k in combo])
            B = np.column_stack([R[k] for k in combo])
            a = lda_loo(A, B)
            if best_combo is None or a > best_combo[0]:
                best_combo = (a, combo)
    if best_combo:
        print(f"  best: {' + '.join(best_combo[1])}  =>  {best_combo[0]:.1%}")
        print(f"  (single-feature baseline: {ranked[0][0]:.1%})")


if __name__ == "__main__":
    main()
