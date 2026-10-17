"""End-to-end cocotb tests for rtl/conv_engine.v.

RGB frames in, configured over AXI4-Lite exactly as software will, and every
output pixel compared with model/conv_model.py: process_frame().
"""

import os
import random
from pathlib import Path

import numpy as np
from skimage import data

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from axil import AxiLiteMaster
from axis import AxisSink, AxisSource
from conv_model import PRESETS, Config, pack_rgb, process_frame

REG_CTRL, REG_STATUS, REG_SHIFT, REG_THRESH = 0x00, 0x04, 0x08, 0x0C
REG_WIDTH, REG_HEIGHT, REG_K0, REG_K1, REG_ID = 0x10, 0x14, 0x20, 0x30, 0x3C


# ------------------------------------------------------------------ helpers
async def setup(dut, idle_prob=0.0, stall_prob=0.0, seed=0):
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    p_in = {"data": dut.s_axis_video_tdata, "user": dut.s_axis_video_tuser, "last": dut.s_axis_video_tlast}
    src = AxisSource(dut.aclk, dut.s_axis_video_tvalid, dut.s_axis_video_tready, p_in, idle_prob, seed)
    axi = AxiLiteMaster(dut, dut.aclk, prefix="s_axi_ctrl_", seed=seed + 2)
    dut.m_axis_video_tready.value = 0
    dut.aresetn.value = 0
    await ClockCycles(dut.aclk, 5)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    p_out = {"data": dut.m_axis_video_tdata, "user": dut.m_axis_video_tuser, "last": dut.m_axis_video_tlast}
    snk = AxisSink(dut.aclk, dut.m_axis_video_tvalid, dut.m_axis_video_tready, p_out, stall_prob, seed + 1)
    return src, snk, axi


def kernel_rows(k):
    return [sum((k[3 * r + c] & 0xFF) << (8 * c) for c in range(3)) for r in range(3)]


async def configure(axi, cfg, width, height):
    """Program the engine the way the PYNQ driver will."""
    await axi.write(REG_WIDTH, width)
    await axi.write(REG_HEIGHT, height)
    await axi.write(REG_SHIFT, cfg.shift0 | cfg.shift1 << 8)
    await axi.write(REG_THRESH, cfg.thresh)
    for r, row in enumerate(kernel_rows(cfg.k0)):
        await axi.write(REG_K0 + 4 * r, row)
    for r, row in enumerate(kernel_rows(cfg.k1)):
        await axi.write(REG_K1 + 4 * r, row)
    await axi.write(REG_CTRL, int(cfg.enable) | int(cfg.thresh_en) << 1 | cfg.mode << 2)


def frame_beats(words):
    h, w = words.shape
    return [{"data": int(words[r, c]), "user": int(r == 0 and c == 0), "last": int(c == w - 1)}
            for r in range(h) for c in range(w)]


def expected_beats(words, cfg):
    return frame_beats(process_frame(words, cfg))


def test_images():
    """Small real RGB images (downsampled) plus random noise."""
    astro = data.astronaut()[::8, ::8]                       # 64 x 64
    coffee = data.coffee()[::10, ::10]                       # 40 x 60
    noise = np.random.default_rng(0).integers(0, 256, (17, 23, 3))
    return {name: pack_rgb(im[..., 0], im[..., 1], im[..., 2])
            for name, im in (("astronaut", astro), ("coffee", coffee), ("noise", noise))}


def words_to_gray(beats, h, w):
    return np.array([b["data"] & 0xFF for b in beats], dtype=np.uint8).reshape(h, w)


# ------------------------------------------------------------------ tests
@cocotb.test()
async def test_id_and_reset_passthrough(dut):
    """ID reads 'CONV'; after reset (filter disabled) the output is the luma image."""
    src, snk, axi = await setup(dut)
    assert await axi.read(REG_ID) == 0x434F4E56
    words = test_images()["noise"]
    h, w = words.shape
    await axi.write(REG_WIDTH, w)
    await axi.write(REG_HEIGHT, h)
    await src.send(frame_beats(words))
    await snk.wait_for(h * w, 20 * h * w)
    snk.check(expected_beats(words, Config(enable=False)))


@cocotb.test()
async def test_all_presets_on_images(dut):
    """Every preset on every test image, with random input gaps and output stalls."""
    src, snk, axi = await setup(dut, idle_prob=0.2, stall_prob=0.3, seed=1)
    expected, results = [], []
    for img_name, words in test_images().items():
        h, w = words.shape
        for name, cfg in PRESETS.items():
            await configure(axi, cfg, w, h)
            start = len(expected)
            expected += expected_beats(words, cfg)
            await src.send(frame_beats(words))
            await snk.wait_for(len(expected), 30 * h * w + 1000)
            results.append((img_name, name, h, w, start))
    await ClockCycles(dut.aclk, 20)
    snk.check(expected)
    assert await axi.read(REG_STATUS) == 0, "FRAME_ERR set on well-formed frames"
    dut._log.info(f"{len(results)} image/preset frames OK, {len(expected)} pixels bit-exact")

    if os.environ.get("SAVE_IMAGES"):
        save_grid(snk.received, results)


@cocotb.test()
async def test_config_written_during_frame_applies_next_frame(dut):
    """Registers written mid-frame must not change the frame in flight."""
    src, snk, axi = await setup(dut, idle_prob=0.1, stall_prob=0.2, seed=2)
    words = test_images()["coffee"]
    h, w = words.shape
    seq = [PRESETS["sobel"], PRESETS["gaussian"], PRESETS["sharpen"], PRESETS["edges"]]
    await configure(axi, seq[0], w, h)
    expected = []
    for i, cfg in enumerate(seq):
        expected += expected_beats(words, cfg)
        sender = cocotb.start_soon(src.send(frame_beats(words)))
        # Wait until this frame's first output pixel exists, then reprogram for the next one.
        await snk.wait_for(i * h * w + 1, 30 * h * w)
        if i + 1 < len(seq):
            await configure(axi, seq[i + 1], w, h)
        await sender
    await snk.wait_for(len(expected), 30 * h * w * len(seq))
    await ClockCycles(dut.aclk, 20)
    snk.check(expected)


@cocotb.test()
async def test_random_sizes_and_configs(dut):
    """Random frame sizes and random kernels, back to back."""
    src, snk, axi = await setup(dut, idle_prob=0.3, stall_prob=0.4, seed=3)
    prng, nrng = random.Random(3), np.random.default_rng(3)
    expected = []
    for _ in range(15):
        h, w = int(nrng.integers(1, 12)), int(nrng.integers(1, 30))
        words = nrng.integers(0, 1 << 24, (h, w))
        cfg = Config(k0=[prng.randint(-128, 127) for _ in range(9)],
                     k1=[prng.randint(-128, 127) for _ in range(9)],
                     shift0=prng.randint(0, 15), shift1=prng.randint(0, 15),
                     mode=prng.randint(0, 2), thresh_en=prng.random() < 0.3,
                     thresh=prng.randint(0, 255))
        await snk.wait_for(len(expected), 100_000)     # previous frame fully out before reprogramming size
        await configure(axi, cfg, w, h)
        expected += expected_beats(words, cfg)
        await src.send(frame_beats(words))
    await snk.wait_for(len(expected), 100_000)
    await ClockCycles(dut.aclk, 20)
    snk.check(expected)


@cocotb.test()
async def test_frame_error_reported_and_cleared(dut):
    """A frame shorter than WIDTH sets STATUS.FRAME_ERR; W1C clears it; next frame is clean."""
    src, snk, axi = await setup(dut, seed=4)
    words = test_images()["noise"]
    h, w = words.shape
    await configure(axi, PRESETS["gaussian"], w + 3, h)     # wrong width
    await src.send(frame_beats(words))
    await ClockCycles(dut.aclk, 50)
    assert await axi.read(REG_STATUS) == 1, "FRAME_ERR not set"
    await axi.write(REG_STATUS, 1)
    assert await axi.read(REG_STATUS) == 0, "FRAME_ERR not cleared"

    # The wrong-width frame finishes by count once enough pixels arrive, then resyncs.
    n_bad = len(snk.received)
    await axi.write(REG_WIDTH, w)
    filler = [{"data": 0, "user": 0, "last": 0}] * (h * 3 + 3)   # completes the bad frame by count
    await src.send(filler)
    await ClockCycles(dut.aclk, 100)
    n_bad = len(snk.received)
    await axi.write(REG_STATUS, 1)
    await src.send(frame_beats(words))
    await snk.wait_for(n_bad + h * w, 20 * h * w)
    await ClockCycles(dut.aclk, 20)
    got = snk.received[n_bad:]
    assert got == expected_beats(words, PRESETS["gaussian"]), "frame after error recovery is wrong"
    assert await axi.read(REG_STATUS) == 0


@cocotb.test()
async def test_throughput(dut):
    """No stalls: (W+1)(H+1) cycles per frame plus a fixed pipeline latency."""
    src, snk, axi = await setup(dut, seed=5)
    words = test_images()["astronaut"]
    h, w = words.shape
    await configure(axi, PRESETS["sobel"], w, h)
    cocotb.start_soon(src.send(frame_beats(words)))
    cycles = 0
    while len(snk.received) < h * w:
        await RisingEdge(dut.aclk)
        cycles += 1
    snk.check(expected_beats(words, PRESETS["sobel"]))
    ideal = (w + 1) * (h + 1)
    assert cycles <= ideal + 20, f"{w}x{h} frame took {cycles} cycles, ideal {ideal}"
    dut._log.info(f"{w}x{h} frame in {cycles} cycles (ideal {ideal}, latency {cycles - ideal})")


# ------------------------------------------------------------------ image dump
def save_grid(received, results):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    imgs = [r for r in results if r[0] == "astronaut"]
    fig, axes = plt.subplots(1, len(imgs), figsize=(2.4 * len(imgs), 2.8))
    for ax, (_, name, h, w, start) in zip(axes, imgs):
        ax.imshow(words_to_gray(received[start:start + h * w], h, w), cmap="gray", vmin=0, vmax=255)
        ax.set_title(name)
        ax.set_xticks([]), ax.set_yticks([])
    fig.suptitle("conv_engine RTL simulation output (bit-exact with the Python model)")
    fig.tight_layout()
    out = Path(__file__).resolve().parents[2] / "docs" / "img" / "rtl_sim_astronaut.png"
    fig.savefig(out, dpi=110)
