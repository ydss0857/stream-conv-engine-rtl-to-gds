"""Phase 1 analysis: fixed-point model vs ideal floating point, on real images.

Writes docs/img/phase1_filters.png and prints the numbers quoted in docs/spec.md.
Run from the model/ directory:  python analyze.py
"""

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import ndimage
from skimage import data

from conv_model import (ACC_BITS, MODE_ABS0, MODE_LANE0, PRESETS, convolve, lane, pack_rgb,
                        rgb_to_luma, window)

OUT = Path(__file__).resolve().parent.parent / "docs" / "img"


def float_reference(y, cfg):
    """Same filter with real-valued arithmetic and true L2 gradient magnitude."""
    y = y.astype(float)
    k0 = np.reshape(cfg.k0, (3, 3)) / (1 << cfg.shift0)
    l0 = ndimage.correlate(y, k0, mode="nearest")
    if cfg.mode == MODE_LANE0:
        v = l0
    elif cfg.mode == MODE_ABS0:
        v = np.abs(l0)
    else:
        k1 = np.reshape(cfg.k1, (3, 3)) / (1 << cfg.shift1)
        v = np.hypot(l0, ndimage.correlate(y, k1, mode="nearest"))
    v = np.clip(v, 0, 255)
    if cfg.thresh_en:
        v = np.where(v >= cfg.thresh, 255, 0)
    return v


def images():
    rgb = data.astronaut()
    words = pack_rgb(rgb[..., 0], rgb[..., 1], rgb[..., 2])
    return {"camera": data.camera().astype(np.int64), "astronaut": rgb_to_luma(words)}, rgb


def main():
    imgs, rgb = images()

    print("== Luma: fixed (77R+150G+29B)>>8 vs float BT.601")
    ideal = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    err = imgs["astronaut"] - ideal
    print(f"   mean error {err.mean():+.3f} LSB, max |error| {np.abs(err).max():.3f} LSB")

    print("\n== Filters: fixed-point model vs float reference")
    print(f"   {'preset':9s} {'image':10s} {'max|err|':>8s} {'mean|err|':>9s} {'PSNR dB':>8s} {'sat %':>6s} {'acc used':>9s}")
    for name, cfg in PRESETS.items():
        for iname, y in imgs.items():
            fx = convolve(y, cfg).astype(float)
            fl = float_reference(y, cfg)
            e = np.abs(fx - fl)
            mse = np.mean(e ** 2)
            psnr = float("inf") if mse == 0 else 10 * np.log10(255 ** 2 / mse)
            win = window(y)
            acc_peak = max(np.abs((win * np.asarray(k)).sum(-1)).max() for k in (cfg.k0, cfg.k1))
            bits_used = int(acc_peak).bit_length() + 1
            # saturation: pixels clipped at 255 before thresholding
            raw = np.abs(lane(win, cfg.k0, cfg.shift0)) if cfg.mode else lane(win, cfg.k0, cfg.shift0)
            if cfg.mode == 2:
                raw = raw + np.abs(lane(win, cfg.k1, cfg.shift1))
            sat = 100 * np.mean((raw > 255) | (raw < 0))
            print(f"   {name:9s} {iname:10s} {e.max():8.2f} {e.mean():9.3f} {psnr:8.1f} {sat:6.2f} {bits_used:4d}/{ACC_BITS}")

    print("\n== Sobel magnitude: L1 (|gx|+|gy|, used in HW) vs L2 (sqrt(gx^2+gy^2))")
    y = imgs["camera"]
    win = window(y)
    gx = lane(win, PRESETS["sobel"].k0, 1).astype(float)
    gy = lane(win, PRESETS["sobel"].k1, 1).astype(float)
    l1, l2 = np.abs(gx) + np.abs(gy), np.hypot(gx, gy)
    nz = l2 > 8
    print(f"   L1/L2 ratio on edges: mean {np.mean(l1[nz] / l2[nz]):.3f}, max {np.max(l1[nz] / l2[nz]):.3f}"
          " (theory: 1.0 to 1.414)")

    OUT.mkdir(parents=True, exist_ok=True)
    names = ["identity", "gaussian", "sharpen", "laplace", "sobel", "edges"]
    fig, axes = plt.subplots(2, len(names), figsize=(3 * len(names), 6.4))
    for row, (iname, y) in enumerate(imgs.items()):
        for col, name in enumerate(names):
            ax = axes[row, col]
            ax.imshow(convolve(y, PRESETS[name]), cmap="gray", vmin=0, vmax=255)
            ax.set_xticks([]), ax.set_yticks([])
            if row == 0:
                ax.set_title(name)
    fig.suptitle("Fixed-point golden model output (the RTL must match this bit for bit)")
    fig.tight_layout()
    fig.savefig(OUT / "phase1_filters.png", dpi=110)
    print(f"\nwrote {OUT / 'phase1_filters.png'}")


if __name__ == "__main__":
    main()
