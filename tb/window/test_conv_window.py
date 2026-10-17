"""cocotb tests for rtl/conv_window.v against model/conv_model.py: window()."""

import random

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from axis import AxisSink, AxisSource
from conv_model import window


def frame_beats(y):
    h, w = y.shape
    return [{"data": int(y[r, c]), "user": int(r == 0 and c == 0), "last": int(c == w - 1)}
            for r in range(h) for c in range(w)]


def expected_windows(y):
    h, w = y.shape
    win = window(y.astype(np.int64))
    out = []
    for r in range(h):
        for c in range(w):
            data = sum(int(p) << (8 * k) for k, p in enumerate(win[r, c]))
            out.append({"data": data, "user": int(r == 0 and c == 0), "last": int(c == w - 1)})
    return out


async def setup(dut, idle_prob=0.0, stall_prob=0.0, seed=0):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    fields_in = {"data": dut.s_data, "user": dut.s_user, "last": dut.s_last}
    src = AxisSource(dut.clk, dut.s_valid, dut.s_ready, fields_in, idle_prob, seed)
    dut.m_ready.value = 0
    dut.err_clr.value = 0
    dut.cfg_width.value = 1
    dut.cfg_height.value = 1
    dut.rstn.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    fields_out = {"data": dut.m_data, "user": dut.m_user, "last": dut.m_last}
    snk = AxisSink(dut.clk, dut.m_valid, dut.m_ready, fields_out, stall_prob, seed + 1)
    return src, snk


async def send_frame(dut, src, y):
    h, w = y.shape
    dut.cfg_width.value = w
    dut.cfg_height.value = h
    await src.send(frame_beats(y))


async def run_frames(dut, frames, idle_prob=0.0, stall_prob=0.0, seed=0):
    src, snk = await setup(dut, idle_prob, stall_prob, seed)
    expected = []
    for y in frames:
        expected += expected_windows(y)
        await send_frame(dut, src, y)
    await snk.wait_for(len(expected), 50 * len(expected) + 1000)
    await ClockCycles(dut.clk, 20)
    snk.check(expected)
    assert int(dut.err.value) == 0, "err flag set on well-formed frames"
    return snk


@cocotb.test()
async def test_small_shapes(dut):
    """Degenerate and small frames: every border and flush case collides."""
    rng = np.random.default_rng(1)
    shapes = [(1, 1), (1, 2), (2, 1), (1, 6), (6, 1), (2, 2), (3, 3), (2, 5), (5, 2), (4, 7)]
    frames = [rng.integers(0, 256, s) for s in shapes]
    await run_frames(dut, frames)
    dut._log.info(f"{len(frames)} frames OK: {shapes}")


@cocotb.test()
async def test_random_frames_backpressure(dut):
    """Back-to-back random-size frames with random input gaps and output stalls."""
    rng = np.random.default_rng(2)
    frames = [rng.integers(0, 256, (int(rng.integers(1, 20)), int(rng.integers(1, 40))))
              for _ in range(12)]
    await run_frames(dut, frames, idle_prob=0.3, stall_prob=0.4, seed=3)
    dut._log.info(f"{len(frames)} frames OK, sizes {[f.shape for f in frames]}")


@cocotb.test()
async def test_max_width(dut):
    """A frame at MAX_WIDTH exercises the full line-buffer depth."""
    rng = np.random.default_rng(4)
    await run_frames(dut, [rng.integers(0, 256, (4, 2048))], stall_prob=0.2, seed=5)


@cocotb.test()
async def test_extreme_frame_shapes(dut):
    """Very tall / very wide frames: every bit of the size registers and counters is used."""
    rng = np.random.default_rng(11)
    shapes = [(4095, 1), (2, 3), (1, 2048), (3, 640), (513, 2), (2, 1100), (2, 1023), (1, 1)]
    await run_frames(dut, [rng.integers(0, 256, s) for s in shapes], stall_prob=0.1, seed=12)
    dut._log.info(f"extreme shapes OK: {shapes}")


@cocotb.test()
async def test_throughput(dut):
    """No stalls: a W x H frame takes about (W+1)(H+1) cycles."""
    src, snk = await setup(dut)
    rng = np.random.default_rng(6)
    h, w = 16, 64
    y = rng.integers(0, 256, (h, w))
    dut.cfg_width.value, dut.cfg_height.value = w, h
    cocotb.start_soon(src.send(frame_beats(y)))
    cycles = 0
    while len(snk.received) < h * w:
        await RisingEdge(dut.clk)
        cycles += 1
    ideal = (w + 1) * (h + 1)
    snk.check(expected_windows(y))
    assert cycles <= ideal + 8, f"frame took {cycles} cycles, ideal {ideal}"
    dut._log.info(f"{w}x{h} frame in {cycles} cycles (ideal {ideal}, {w * h} pixels)")


@cocotb.test()
async def test_invalid_config_drops_frame(dut):
    """Start of frame with WIDTH=0, HEIGHT=0 or WIDTH>MAX_WIDTH: err set, frame dropped, recovery."""
    src, snk = await setup(dut, idle_prob=0.2, stall_prob=0.2, seed=9)
    rng = np.random.default_rng(9)
    for bad_w, bad_h in ((0, 3), (4, 0), (2049, 2)):
        dut.cfg_width.value, dut.cfg_height.value = bad_w, bad_h
        await src.send(frame_beats(rng.integers(0, 256, (3, 4))))   # tuser + pixels, all swallowed
        await ClockCycles(dut.clk, 10)
        assert int(dut.err.value) == 1, f"WIDTH={bad_w} HEIGHT={bad_h} did not set err"
        assert len(snk.received) == 0, "a frame with an invalid config produced output"
        dut.err_clr.value = 1
        await RisingEdge(dut.clk)
        dut.err_clr.value = 0
    good = rng.integers(0, 256, (3, 4))
    await send_frame(dut, src, good)
    await snk.wait_for(12, 2000)
    await ClockCycles(dut.clk, 20)
    snk.check(expected_windows(good))
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_start_of_frame_mid_frame(dut):
    """A tuser in the middle of a frame sets err; the frame completes by count; next frame is clean."""
    src, snk = await setup(dut, idle_prob=0.2, stall_prob=0.3, seed=10)
    rng = np.random.default_rng(10)
    bad = frame_beats(rng.integers(0, 256, (3, 5)))
    bad[7]["user"] = 1
    dut.cfg_width.value, dut.cfg_height.value = 5, 3
    await src.send(bad)
    await snk.wait_for(15, 2000)
    assert int(dut.err.value) == 1, "mid-frame tuser did not set err"
    dut.err_clr.value = 1
    await RisingEdge(dut.clk)
    dut.err_clr.value = 0
    good = rng.integers(0, 256, (4, 3))
    await send_frame(dut, src, good)
    await snk.wait_for(15 + 12, 2000)
    await ClockCycles(dut.clk, 20)
    assert snk.received[15:] == expected_windows(good), "frame after mid-frame tuser is wrong"
    assert not snk.errors, snk.errors[0]
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_framing_errors_and_recovery(dut):
    """Junk before SOF is dropped; a bad tlast sets err; the next frame is clean."""
    src, snk = await setup(dut, idle_prob=0.2, stall_prob=0.3, seed=7)
    rng = np.random.default_rng(8)

    # 1. Junk pixels without tuser before the first frame are swallowed.
    await src.send([{"data": 0xAA, "user": 0, "last": 0}] * 10)
    good1 = rng.integers(0, 256, (3, 5))
    await send_frame(dut, src, good1)

    # 2. A frame whose tlast lands one pixel early on the first line.
    bad = frame_beats(rng.integers(0, 256, (3, 5)))
    bad[3]["last"], bad[4]["last"] = 1, 0
    dut.cfg_width.value, dut.cfg_height.value = 5, 3
    await src.send(bad)
    n_before = len(expected_windows(good1)) + 15
    await snk.wait_for(n_before, 2000)
    assert int(dut.err.value) == 1, "bad tlast did not set err"

    # 3. Clear the error, send a good frame, and check it alone.
    dut.err_clr.value = 1
    await RisingEdge(dut.clk)
    dut.err_clr.value = 0
    good2 = rng.integers(0, 256, (4, 6))
    await send_frame(dut, src, good2)
    await snk.wait_for(n_before + 24, 4000)
    await ClockCycles(dut.clk, 20)

    got = snk.received
    assert got[:15] == expected_windows(good1), "frame after junk is wrong"
    assert got[n_before:] == expected_windows(good2), "frame after error is wrong"
    assert not snk.errors, snk.errors[0]
    assert int(dut.err.value) == 0, "err set again by a good frame"
