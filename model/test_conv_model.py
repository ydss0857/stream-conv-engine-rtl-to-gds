"""Sanity tests for the golden model (run: pytest model/)."""

import numpy as np
import pytest

from conv_model import (ACC_BITS, MODE_MAG, PRESETS, Config, convolve, lane, process_frame,
                        rgb_to_luma, window)

rng = np.random.default_rng(0)


def test_identity_is_passthrough():
    y = rng.integers(0, 256, (20, 30))
    assert np.array_equal(convolve(y, PRESETS["identity"]), y)


@pytest.mark.parametrize("name", ["gaussian", "box", "sharpen"])
def test_flat_image_is_preserved_by_unity_gain_kernels(name):
    y = np.full((8, 8), 137)
    out = convolve(y, PRESETS[name])
    assert np.all(np.abs(out.astype(int) - 137) <= 3)


@pytest.mark.parametrize("name", ["sobel", "laplace"])
def test_flat_image_has_no_edges(name):
    assert np.all(convolve(np.full((8, 8), 200), PRESETS[name]) == 0)


def test_vertical_edge_is_detected_by_sobel():
    y = np.zeros((8, 8), int)
    y[:, 4:] = 255
    out = convolve(y, PRESETS["sobel"])
    assert np.all(out[:, 3:5] == 255) and np.all(out[:, :2] == 0) and np.all(out[:, 6:] == 0)


def test_edges_replicate_at_borders():
    y = rng.integers(0, 256, (5, 6))
    w = window(y)
    assert np.array_equal(w[0, 0], [y[0, 0], y[0, 0], y[0, 1], y[0, 0], y[0, 0], y[0, 1],
                                    y[1, 0], y[1, 0], y[1, 1]])


def test_worst_case_accumulator_fits():
    """All-255 window with all-(-128) or all-127 coefficients must not overflow s20."""
    win = np.full((1, 1, 9), 255)
    for c in (-128, 127):
        acc = lane(win, [c] * 9, 0)
        assert abs(int(acc[0, 0])) < 1 << (ACC_BITS - 1)


def test_rounding_is_half_up():
    win = np.zeros((1, 1, 9), int)
    win[..., 4] = 1
    assert int(lane(win, [0, 0, 0, 0, 8, 0, 0, 0, 0], 4)[0, 0]) == 1    # 8/16  = 0.5   -> 1
    assert int(lane(win, [0, 0, 0, 0, 7, 0, 0, 0, 0], 4)[0, 0]) == 0    # 7/16          -> 0
    assert int(lane(win, [0, 0, 0, 0, -8, 0, 0, 0, 0], 4)[0, 0]) == 0   # -0.5 rounds up -> 0


def test_luma_matches_grayscale_axis_rtl_formula():
    r, g, b = 200, 100, 50
    word = (r << 16) | (b << 8) | g
    assert int(rgb_to_luma(word)) == (77 * r + 150 * g + 29 * b) >> 8


def test_process_frame_replicates_gray():
    out = process_frame(rng.integers(0, 1 << 24, (4, 4)), PRESETS["gaussian"])
    assert np.all((out >> 16) == (out & 0xFF)) and np.all(((out >> 8) & 0xFF) == (out & 0xFF))


def test_disable_passes_luma_through():
    y = rng.integers(0, 256, (6, 9))
    assert np.array_equal(convolve(y, Config(k0=[9] * 9, enable=False)), y)


def test_invalid_config_rejected():
    with pytest.raises(AssertionError):
        convolve(np.zeros((3, 3), int), Config(k0=[200] + [0] * 8))
    with pytest.raises(AssertionError):
        convolve(np.zeros((3, 3), int), Config(mode=MODE_MAG + 1))
