"""cocotb tests for rtl/conv_regs.v."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from axil import AxiLiteMaster

# offset: (name, implemented-bit mask, reset value)
REGS = {
    0x00: ("CTRL",    0x0000000F, 0x00000000),
    0x08: ("SHIFT",   0x00000F0F, 0x00000000),
    0x0C: ("THRESH",  0x000000FF, 0x00000080),
    0x10: ("WIDTH",   0x00000FFF, 1280),
    0x14: ("HEIGHT",  0x00000FFF, 720),
    0x20: ("K0_ROW0", 0x00FFFFFF, 0x000000),
    0x24: ("K0_ROW1", 0x00FFFFFF, 0x000100),
    0x28: ("K0_ROW2", 0x00FFFFFF, 0x000000),
    0x30: ("K1_ROW0", 0x00FFFFFF, 0x000000),
    0x34: ("K1_ROW1", 0x00FFFFFF, 0x000000),
    0x38: ("K1_ROW2", 0x00FFFFFF, 0x000000),
}
ID_OFFSET, ID_VALUE = 0x3C, 0x434F4E56
UNMAPPED = [0x18, 0x1C, 0x2C]


async def setup(dut, seed=0, max_delay=3):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    axi = AxiLiteMaster(dut, dut.clk, max_delay=max_delay, seed=seed)
    dut.frame_err.value = 0
    dut.rstn.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    return axi


def cfg_outputs(dut):
    """Decode the cfg_* ports back into register values."""
    k0, k1 = int(dut.cfg_k0.value), int(dut.cfg_k1.value)
    return {
        0x00: int(dut.cfg_enable.value) | int(dut.cfg_thresh_en.value) << 1 | int(dut.cfg_mode.value) << 2,
        0x08: int(dut.cfg_shift0.value) | int(dut.cfg_shift1.value) << 8,
        0x0C: int(dut.cfg_thresh.value),
        0x10: int(dut.cfg_width.value),
        0x14: int(dut.cfg_height.value),
        0x20: k0 & 0xFFFFFF, 0x24: (k0 >> 24) & 0xFFFFFF, 0x28: (k0 >> 48) & 0xFFFFFF,
        0x30: k1 & 0xFFFFFF, 0x34: (k1 >> 24) & 0xFFFFFF, 0x38: (k1 >> 48) & 0xFFFFFF,
    }


@cocotb.test()
async def test_reset_values_and_id(dut):
    axi = await setup(dut)
    for off, (name, _, reset) in REGS.items():
        got = await axi.read(off)
        assert got == reset, f"{name}: reset value 0x{got:X}, expected 0x{reset:X}"
    assert await axi.read(ID_OFFSET) == ID_VALUE
    assert cfg_outputs(dut) == {off: r for off, (_, _, r) in REGS.items()}


@cocotb.test()
async def test_write_read_all_registers(dut):
    """Random writes with random AW/W ordering; readback and cfg ports match a shadow model."""
    axi = await setup(dut, seed=1)
    rng = random.Random(1)
    shadow = {off: reset for off, (_, _, reset) in REGS.items()}
    for _ in range(300):
        off = rng.choice(list(REGS))
        val = rng.getrandbits(32)
        await axi.write(off, val)
        shadow[off] = val & REGS[off][1]
        check = rng.choice(list(REGS))
        got = await axi.read(check)
        assert got == shadow[check], f"{REGS[check][0]}: read 0x{got:X}, expected 0x{shadow[check]:X}"
    assert cfg_outputs(dut) == shadow


@cocotb.test()
async def test_byte_strobes(dut):
    axi = await setup(dut, seed=2)
    rng = random.Random(2)
    shadow = {off: reset for off, (_, _, reset) in REGS.items()}
    for _ in range(200):
        off = rng.choice(list(REGS))
        val, strb = rng.getrandbits(32), rng.getrandbits(4)
        await axi.write(off, val, strb)
        mask = sum(0xFF << (8 * b) for b in range(4) if strb >> b & 1)
        shadow[off] = ((shadow[off] & ~mask) | (val & mask)) & REGS[off][1]
        assert await axi.read(off) == shadow[off], f"{REGS[off][0]} after strobe 0b{strb:04b}"


@cocotb.test()
async def test_unmapped_and_readonly(dut):
    axi = await setup(dut, seed=3)
    for off in UNMAPPED:
        await axi.write(off, 0xFFFFFFFF)
        assert await axi.read(off) == 0
    await axi.write(ID_OFFSET, 0)
    assert await axi.read(ID_OFFSET) == ID_VALUE
    assert cfg_outputs(dut) == {off: r for off, (_, _, r) in REGS.items()}, "unmapped write changed a register"


@cocotb.test()
async def test_status_write_one_to_clear(dut):
    axi = await setup(dut, seed=4)
    pulses = []

    async def count_pulses():
        while True:
            await RisingEdge(dut.clk)
            if dut.frame_err_clr.value:
                pulses.append(1)
    cocotb.start_soon(count_pulses())

    dut.frame_err.value = 1
    assert await axi.read(0x04) == 1
    await axi.write(0x04, 0)              # writing 0 must not clear
    await axi.write(0x04, 1, strb=0b0010)  # bit 0 masked off by strobe: must not clear
    await ClockCycles(dut.clk, 2)
    assert len(pulses) == 0
    await axi.write(0x04, 1)
    await ClockCycles(dut.clk, 2)
    assert len(pulses) == 1, f"expected one clear pulse, saw {len(pulses)}"
    dut.frame_err.value = 0
    assert await axi.read(0x04) == 0


@cocotb.test()
async def test_unaligned_addresses(dut):
    """Address bits [1:0] are ignored: offset+1..3 reach the same 32-bit register."""
    axi = await setup(dut, seed=6)
    rng = random.Random(6)
    for off in REGS:
        val = rng.getrandbits(32)
        await axi.write(off | rng.randint(1, 3), val)
        assert await axi.read(off | rng.randint(1, 3)) == val & REGS[off][1]
        assert await axi.read(off) == val & REGS[off][1]


@cocotb.test()
async def test_no_delays_back_to_back(dut):
    """Zero-delay master: AW and W in the same cycle, every cycle."""
    axi = await setup(dut, seed=5, max_delay=0)
    for i, off in enumerate(REGS):
        await axi.write(off, 0x01010101 * (i + 1))
    for i, off in enumerate(REGS):
        assert await axi.read(off) == (0x01010101 * (i + 1)) & REGS[off][1]
