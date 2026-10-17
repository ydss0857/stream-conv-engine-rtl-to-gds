"""cocotb testbench for grayscale_axis.

Drives random pixels into the slave port with random idle cycles, applies
random backpressure on the master port, and checks that:
  * every output beat matches the Python golden model, in order, with no
    beats dropped or duplicated;
  * the master port obeys AXI4-Stream: once tvalid is high and tready is low,
    tvalid/tdata/tuser/tlast hold steady until the beat is accepted.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


def golden(tdata):
    """Expected output word for one input word ({R, B, G} channel order)."""
    r = (tdata >> 16) & 0xFF
    b = (tdata >> 8) & 0xFF
    g = tdata & 0xFF
    y = (77 * r + 150 * g + 29 * b) >> 8
    return (y << 16) | (y << 8) | y


def make_frame(width, height, rng):
    """List of (tdata, tuser, tlast) beats for one random frame."""
    beats = []
    for row in range(height):
        for col in range(width):
            beats.append((rng.getrandbits(24), int(row == 0 and col == 0), int(col == width - 1)))
    return beats


async def reset(dut):
    dut.aresetn.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tuser.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 0
    await ClockCycles(dut.aclk, 5)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)


async def drive(dut, beats, rng, idle_prob):
    """AXI4-Stream master: present each beat and hold it until accepted."""
    for tdata, tuser, tlast in beats:
        while rng.random() < idle_prob:
            dut.s_axis_tvalid.value = 0
            await RisingEdge(dut.aclk)
        dut.s_axis_tdata.value = tdata
        dut.s_axis_tuser.value = tuser
        dut.s_axis_tlast.value = tlast
        dut.s_axis_tvalid.value = 1
        await RisingEdge(dut.aclk)
        while not dut.s_axis_tready.value:
            await RisingEdge(dut.aclk)
    dut.s_axis_tvalid.value = 0


async def monitor(dut, received, rng, stall_prob, errors):
    """AXI4-Stream slave: random tready, capture beats, check hold rules."""
    stalled = None  # beat held on the bus at the previous edge while tready was low
    while True:
        dut.m_axis_tready.value = int(rng.random() >= stall_prob)
        await RisingEdge(dut.aclk)
        valid = int(dut.m_axis_tvalid.value)
        ready = int(dut.m_axis_tready.value)
        # Data lines are only meaningful (and may be X) when tvalid is high.
        beat = None
        if valid:
            beat = (int(dut.m_axis_tdata.value), int(dut.m_axis_tuser.value), int(dut.m_axis_tlast.value))

        if stalled is not None:
            if not valid:
                errors.append(f"tvalid dropped while stalled (was holding {stalled})")
            elif beat != stalled:
                errors.append(f"beat changed while stalled: {stalled} -> {beat}")

        if valid and ready:
            received.append(beat)
            stalled = None
        elif valid:
            stalled = beat
        else:
            stalled = None


async def run(dut, width, height, idle_prob, stall_prob, seed):
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)

    beats = make_frame(width, height, rng)
    expected = [(golden(d), u, l) for d, u, l in beats]
    received, errors = [], []

    cocotb.start_soon(monitor(dut, received, random.Random(seed + 1), stall_prob, errors))
    await drive(dut, beats, rng, idle_prob)

    for _ in range(20 * len(beats) + 100):
        if len(received) >= len(expected):
            break
        await RisingEdge(dut.aclk)
    await ClockCycles(dut.aclk, 10)  # catch any extra (duplicated) beats

    assert not errors, f"{len(errors)} AXI-Stream protocol violations, first: {errors[0]}"
    assert len(received) == len(expected), f"expected {len(expected)} beats, got {len(received)}"
    for i, (got, exp) in enumerate(zip(received, expected)):
        assert got == exp, f"beat {i}: got {got}, expected {exp}"
    dut._log.info(f"{len(received)} beats OK (idle={idle_prob}, stall={stall_prob})")


@cocotb.test()
async def test_no_backpressure(dut):
    """Continuous input, sink always ready."""
    await run(dut, width=32, height=8, idle_prob=0.0, stall_prob=0.0, seed=1)


@cocotb.test()
async def test_random_backpressure(dut):
    """Random input gaps and random downstream stalls."""
    await run(dut, width=32, height=8, idle_prob=0.3, stall_prob=0.4, seed=2)


@cocotb.test()
async def test_heavy_backpressure(dut):
    """Sink stalls most cycles while the source is always valid."""
    await run(dut, width=16, height=4, idle_prob=0.0, stall_prob=0.8, seed=3)
