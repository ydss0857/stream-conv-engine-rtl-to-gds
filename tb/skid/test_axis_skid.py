"""cocotb tests for rtl/axis_skid.v."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from axis import AxisSink, AxisSource


async def setup(dut, idle_prob=0.0, stall_prob=0.0, seed=0):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    src = AxisSource(dut.clk, dut.s_valid, dut.s_ready, {"data": dut.s_data}, idle_prob, seed)
    dut.m_ready.value = 0
    dut.rstn.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    # Start checking only once reset has defined m_valid.
    snk = AxisSink(dut.clk, dut.m_valid, dut.m_ready, {"data": dut.m_data}, stall_prob, seed + 1)
    return src, snk


def random_beats(dut, n, seed):
    rng = random.Random(seed)
    width = len(dut.s_data)
    return [{"data": rng.getrandbits(width)} for _ in range(n)]


async def run_traffic(dut, n, idle_prob, stall_prob, seed):
    src, snk = await setup(dut, idle_prob, stall_prob, seed)
    beats = random_beats(dut, n, seed)
    await src.send(beats)
    await snk.wait_for(n, 50 * n)
    await ClockCycles(dut.clk, 5)
    snk.check(beats)
    dut._log.info(f"{n} beats OK (idle={idle_prob}, stall={stall_prob})")


@cocotb.test()
async def test_passthrough(dut):
    await run_traffic(dut, 500, 0.0, 0.0, seed=10)


@cocotb.test()
async def test_random_traffic(dut):
    for i, (idle, stall) in enumerate([(0.2, 0.2), (0.0, 0.5), (0.5, 0.0), (0.7, 0.7)]):
        await run_traffic(dut, 500, idle, stall, seed=20 + i)


@cocotb.test()
async def test_full_throughput(dut):
    """With no stalls, N beats must take N cycles plus a fixed latency."""
    src, snk = await setup(dut)
    n = 200
    cocotb.start_soon(src.send(random_beats(dut, n, 30)))
    await RisingEdge(dut.clk)
    cycles = 0
    while len(snk.received) < n:
        await RisingEdge(dut.clk)
        cycles += 1
    assert cycles <= n + 2, f"{n} beats took {cycles} cycles: throughput below 1 beat/clock"
    dut._log.info(f"{n} beats in {cycles} cycles")


@cocotb.test()
async def test_ready_is_registered(dut):
    """s_ready must not change in response to m_ready without a clock edge."""
    src, snk = await setup(dut)
    rng = random.Random(40)
    snk.stall_prob = 2.0          # take over m_ready manually
    for _ in range(300):
        dut.s_valid.value = rng.getrandbits(1)
        dut.s_data.value = rng.getrandbits(len(dut.s_data))
        await RisingEdge(dut.clk)
        await Timer(2, unit="ns")
        before = int(dut.s_ready.value)
        dut.m_ready.value = 1 - int(dut.m_ready.value)
        await Timer(2, unit="ns")
        assert int(dut.s_ready.value) == before, "s_ready changed combinationally with m_ready"
