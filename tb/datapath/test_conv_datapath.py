"""cocotb tests for rtl/conv_datapath.v against model/conv_model.py: apply_windows()."""

import random

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from axis import AxisSink, AxisSource
from conv_model import MODE_ABS0, MODE_LANE0, MODE_MAG, PRESETS, Config, apply_windows


def pack_s8(coeffs):
    return sum((c & 0xFF) << (8 * k) for k, c in enumerate(coeffs))


def pack_window(w):
    return sum(int(p) << (8 * k) for k, p in enumerate(w))


def random_config(rng):
    return Config(k0=[rng.randint(-128, 127) for _ in range(9)],
                  k1=[rng.randint(-128, 127) for _ in range(9)],
                  shift0=rng.randint(0, 15), shift1=rng.randint(0, 15),
                  mode=rng.choice([MODE_LANE0, MODE_ABS0, MODE_MAG]),
                  thresh_en=rng.random() < 0.3, thresh=rng.randint(0, 255),
                  enable=rng.random() > 0.1)


def drive_config(dut, cfg):
    dut.cfg_enable.value = int(cfg.enable)
    dut.cfg_k0.value = pack_s8(cfg.k0)
    dut.cfg_k1.value = pack_s8(cfg.k1)
    dut.cfg_shift0.value = cfg.shift0
    dut.cfg_shift1.value = cfg.shift1
    dut.cfg_mode.value = cfg.mode
    dut.cfg_thresh_en.value = int(cfg.thresh_en)
    dut.cfg_thresh.value = cfg.thresh


async def setup(dut, idle_prob, stall_prob, seed):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    fields_in = {"data": dut.s_data, "user": dut.s_user, "last": dut.s_last}
    src = AxisSource(dut.clk, dut.s_valid, dut.s_ready, fields_in, idle_prob, seed)
    drive_config(dut, Config())
    dut.m_ready.value = 0
    dut.rstn.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    fields_out = {"data": dut.m_data, "user": dut.m_user, "last": dut.m_last}
    snk = AxisSink(dut.clk, dut.m_valid, dut.m_ready, fields_out, stall_prob, seed + 1)
    return src, snk


def make_frame(wins, cfg, line_len):
    """Windows -> (input beats, expected output beats) for one 'frame'."""
    out = apply_windows(wins, cfg)
    beats_in, beats_out = [], []
    for i, w in enumerate(wins):
        user, last = int(i == 0), int(i % line_len == line_len - 1)
        beats_in.append({"data": pack_window(w), "user": user, "last": last})
        beats_out.append({"data": int(out[i]), "user": user, "last": last})
    return beats_in, beats_out


async def run_frames(dut, frames, idle_prob=0.0, stall_prob=0.0, seed=0):
    """frames: list of (windows (N, 9), Config). Config changes at each frame start."""
    src, snk = await setup(dut, idle_prob, stall_prob, seed)
    expected = []
    for wins, cfg in frames:
        beats_in, beats_out = make_frame(wins, cfg, line_len=7)
        expected += beats_out
        # Drive the new config only once the previous frame's beats are all
        # accepted, then send the next frame immediately (pipeline still full).
        drive_config(dut, cfg)
        await src.send(beats_in)
    await snk.wait_for(len(expected), 50 * len(expected) + 200)
    await ClockCycles(dut.clk, 10)
    snk.check(expected)


@cocotb.test()
async def test_presets(dut):
    """Every preset on random windows, back to back."""
    rng = np.random.default_rng(1)
    frames = [(rng.integers(0, 256, (60, 9)), cfg) for cfg in PRESETS.values()]
    await run_frames(dut, frames)
    dut._log.info(f"presets OK: {list(PRESETS)}")


@cocotb.test()
async def test_random_configs_backpressure(dut):
    """Random kernels, shifts, modes and thresholds, config switching every frame."""
    prng, nrng = random.Random(2), np.random.default_rng(2)
    frames = [(nrng.integers(0, 256, (int(nrng.integers(1, 40)), 9)), random_config(prng))
              for _ in range(60)]
    await run_frames(dut, frames, idle_prob=0.3, stall_prob=0.4, seed=3)
    dut._log.info(f"{len(frames)} random configs OK, {sum(len(f[0]) for f in frames)} windows")


@cocotb.test()
async def test_extremes(dut):
    """Worst-case accumulator values: all-255 / all-0 windows, +-max coefficients."""
    wins = np.array([[255] * 9, [0] * 9, [255, 0] * 4 + [255], [0, 255] * 4 + [0]] * 4)
    frames = []
    for c0 in (-128, 127):
        for c1 in (-128, 127):
            for mode in (MODE_LANE0, MODE_ABS0, MODE_MAG):
                for shift in (0, 1, 15):
                    frames.append((wins, Config(k0=[c0] * 9, k1=[c1] * 9, shift0=shift,
                                                shift1=15 - shift, mode=mode)))
    await run_frames(dut, frames, stall_prob=0.2, seed=4)
    dut._log.info(f"{len(frames)} extreme configs OK")


@cocotb.test()
async def test_config_changes_mid_frame_are_ignored(dut):
    """Config writes during a frame must not affect it: settings latch at start of frame."""
    src, snk = await setup(dut, 0.2, 0.3, seed=6)
    prng, nrng = random.Random(6), np.random.default_rng(6)
    expected = []

    async def scramble(stop):
        while not stop[0]:
            drive_config(dut, random_config(prng))
            await ClockCycles(dut.clk, prng.randint(1, 4))

    for _ in range(20):
        cfg = random_config(prng)
        beats_in, beats_out = make_frame(nrng.integers(0, 256, (int(nrng.integers(2, 30)), 9)), cfg, 7)
        expected += beats_out
        drive_config(dut, cfg)
        await src.send(beats_in[:1])          # start of frame latches cfg
        stop = [False]
        cocotb.start_soon(scramble(stop))
        await src.send(beats_in[1:])
        stop[0] = True
        await RisingEdge(dut.clk)
    await snk.wait_for(len(expected), 50 * len(expected) + 200)
    await ClockCycles(dut.clk, 10)
    snk.check(expected)
    dut._log.info(f"20 frames OK with config scrambled mid-frame")


@cocotb.test()
async def test_throughput(dut):
    """No stalls: one window per clock after the pipeline fills."""
    src, snk = await setup(dut, 0.0, 0.0, seed=5)
    rng = np.random.default_rng(5)
    beats_in, beats_out = make_frame(rng.integers(0, 256, (300, 9)), PRESETS["sobel"], 30)
    drive_config(dut, PRESETS["sobel"])
    cocotb.start_soon(src.send(beats_in))
    cycles = 0
    while len(snk.received) < len(beats_in):
        await RisingEdge(dut.clk)
        cycles += 1
    snk.check(beats_out)
    # 8 pipeline registers + the source's first cycle = 9 cycles of latency.
    assert cycles <= len(beats_in) + 9, f"{len(beats_in)} windows took {cycles} cycles"
    dut._log.info(f"{len(beats_in)} windows in {cycles} cycles (latency {cycles - len(beats_in)})")
