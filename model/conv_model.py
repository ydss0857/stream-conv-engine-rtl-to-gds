"""Bit-exact golden model of the streaming 3x3 convolution engine.

Every function here uses integer arithmetic with the exact widths, rounding,
and saturation the RTL implements, so RTL output must match it bit for bit.
See docs/spec.md for the architecture these functions describe.

Datapath per output pixel:

    RGB (8b each, {R,B,G} AXI order)
      -> luma Y (u8)                          rgb_to_luma()
      -> 3x3 window, edges replicated         window()
      -> two kernel lanes K0, K1:
           acc  = sum(coeff * pixel)          s20  (coeff s8, pixel u8)
           lane = (acc + round) >>> shift     s20, round-half-up
      -> combine (MODE):
           LANE0 : lane0
           ABS0  : |lane0|
           MAG   : |lane0| + |lane1|          (L1 gradient magnitude)
      -> saturate to [0, 255]                 u8
      -> optional threshold: v >= T ? 255 : 0
      -> replicate to {Y, Y, Y}
"""

from dataclasses import dataclass, field

import numpy as np

# ---------------------------------------------------------------- widths
PIX_BITS = 8      # unsigned pixel
COEF_BITS = 8     # signed coefficient, range [-128, 127]
ACC_BITS = 20     # signed accumulator: 9 * 128 * 255 = 293760 < 2**19
SHIFT_MAX = 15

MODE_LANE0 = 0
MODE_ABS0 = 1
MODE_MAG = 2


@dataclass
class Config:
    """Mirror of the engine's AXI4-Lite control registers."""
    k0: list = field(default_factory=lambda: [0, 0, 0, 0, 1, 0, 0, 0, 0])  # row-major, s8
    k1: list = field(default_factory=lambda: [0] * 9)
    shift0: int = 0
    shift1: int = 0
    mode: int = MODE_LANE0
    thresh_en: bool = False
    thresh: int = 128

    def validate(self):
        for k in (self.k0, self.k1):
            assert len(k) == 9, "kernel must have 9 coefficients"
            assert all(-128 <= c <= 127 for c in k), "coefficients must fit s8"
        assert 0 <= self.shift0 <= SHIFT_MAX and 0 <= self.shift1 <= SHIFT_MAX
        assert self.mode in (MODE_LANE0, MODE_ABS0, MODE_MAG)
        assert 0 <= self.thresh <= 255


# ---------------------------------------------------------------- presets
PRESETS = {
    "identity": Config(),
    "gaussian": Config(k0=[1, 2, 1, 2, 4, 2, 1, 2, 1], shift0=4),
    "box":      Config(k0=[7] * 9, shift0=6),              # 63/64 ~ 1, shift-only divide
    "sharpen":  Config(k0=[0, -1, 0, -1, 5, -1, 0, -1, 0]),
    "laplace":  Config(k0=[0, 1, 0, 1, -4, 1, 0, 1, 0], mode=MODE_ABS0),
    "sobel":    Config(k0=[-1, 0, 1, -2, 0, 2, -1, 0, 1],
                       k1=[-1, -2, -1, 0, 0, 0, 1, 2, 1],
                       shift0=1, shift1=1, mode=MODE_MAG),
    "edges":    Config(k0=[-1, 0, 1, -2, 0, 2, -1, 0, 1],
                       k1=[-1, -2, -1, 0, 0, 0, 1, 2, 1],
                       shift0=1, shift1=1, mode=MODE_MAG, thresh_en=True, thresh=64),
}


# ---------------------------------------------------------------- stages
def rgb_to_luma(tdata):
    """24-bit AXI video word {R[23:16], B[15:8], G[7:0]} -> u8 luma (BT.601, >> 8)."""
    tdata = np.asarray(tdata, dtype=np.int64)
    r = (tdata >> 16) & 0xFF
    b = (tdata >> 8) & 0xFF
    g = tdata & 0xFF
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.int64)


def pack_rgb(r, g, b):
    """u8 planes -> 24-bit AXI video words in {R, B, G} order."""
    return (np.asarray(r, np.int64) << 16) | (np.asarray(b, np.int64) << 8) | np.asarray(g, np.int64)


def window(y):
    """(H, W) image -> (H, W, 9) neighbourhoods, row-major, edges replicated."""
    p = np.pad(y, 1, mode="edge")
    h, w = y.shape
    return np.stack([p[r:r + h, c:c + w] for r in range(3) for c in range(3)], axis=-1)


def lane(win, kernel, shift):
    """One kernel lane: signed MAC into an s20 accumulator, then rounded arithmetic shift."""
    acc = (win * np.asarray(kernel, np.int64)).sum(axis=-1)
    lo, hi = -(1 << (ACC_BITS - 1)), (1 << (ACC_BITS - 1)) - 1
    assert acc.min() >= lo and acc.max() <= hi, "accumulator overflow: ACC_BITS too small"
    if shift:
        acc = (acc + (1 << (shift - 1))) >> shift  # numpy >> on int64 is arithmetic (floor)
    return acc


def convolve(y, cfg):
    """u8 luma image -> u8 filtered image, bit-exact with the RTL."""
    cfg.validate()
    win = window(np.asarray(y, np.int64))
    l0 = lane(win, cfg.k0, cfg.shift0)
    if cfg.mode == MODE_LANE0:
        v = l0
    elif cfg.mode == MODE_ABS0:
        v = np.abs(l0)
    else:
        v = np.abs(l0) + np.abs(lane(win, cfg.k1, cfg.shift1))
    v = np.clip(v, 0, 255)
    if cfg.thresh_en:
        v = np.where(v >= cfg.thresh, 255, 0)
    return v.astype(np.uint8)


def process_frame(tdata, cfg):
    """(H, W) array of 24-bit input words -> (H, W) array of 24-bit output words."""
    v = convolve(rgb_to_luma(tdata), cfg).astype(np.int64)
    return (v << 16) | (v << 8) | v
