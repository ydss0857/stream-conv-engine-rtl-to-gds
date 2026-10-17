"""Reusable AXI4-Stream source and sink for cocotb testbenches.

A beat is a dict {field_name: int}. Each field maps to a DUT signal handle, so
the same classes work for any port naming, e.g.
    {"data": dut.s_axis_tdata, "user": dut.s_axis_tuser, "last": dut.s_axis_tlast}
"""

import random

import cocotb
from cocotb.triggers import RisingEdge


class AxisSource:
    """Master side: presents beats with random idle gaps, holds each until accepted."""

    def __init__(self, clk, valid, ready, fields, idle_prob=0.0, seed=0):
        self.clk, self.valid, self.ready, self.fields = clk, valid, ready, fields
        self.idle_prob = idle_prob
        self.rng = random.Random(seed)
        self.valid.value = 0

    async def send(self, beats):
        for beat in beats:
            while self.rng.random() < self.idle_prob:
                self.valid.value = 0
                await RisingEdge(self.clk)
            for name, sig in self.fields.items():
                sig.value = beat[name]
            self.valid.value = 1
            await RisingEdge(self.clk)
            while not self.ready.value:
                await RisingEdge(self.clk)
        self.valid.value = 0


class AxisSink:
    """Slave side: random tready, records accepted beats, checks the hold rule.

    AXI4-Stream rule checked: once tvalid is high, tvalid and every payload
    field stay unchanged until the beat is accepted (tvalid && tready).
    """

    def __init__(self, clk, valid, ready, fields, stall_prob=0.0, seed=1):
        self.clk, self.valid, self.ready, self.fields = clk, valid, ready, fields
        self.stall_prob = stall_prob
        self.rng = random.Random(seed)
        self.received, self.errors = [], []
        self.ready.value = 0
        cocotb.start_soon(self._run())

    async def _run(self):
        stalled = None
        while True:
            self.ready.value = int(self.rng.random() >= self.stall_prob)
            await RisingEdge(self.clk)
            valid = int(self.valid.value)
            ready = int(self.ready.value)
            beat = {n: int(s.value) for n, s in self.fields.items()} if valid else None

            if stalled is not None and beat != stalled:
                self.errors.append(f"beat changed or dropped while stalled: {stalled} -> {beat}")
            if valid and ready:
                self.received.append(beat)
            stalled = beat if (valid and not ready) else None

    async def wait_for(self, count, timeout_cycles):
        for _ in range(timeout_cycles):
            if len(self.received) >= count:
                return
            await RisingEdge(self.clk)

    def check(self, expected):
        assert not self.errors, f"{len(self.errors)} AXI-Stream violations, first: {self.errors[0]}"
        assert len(self.received) == len(expected), \
            f"expected {len(expected)} beats, got {len(self.received)}"
        for i, (got, exp) in enumerate(zip(self.received, expected)):
            assert got == exp, f"beat {i}: got {got}, expected {exp}"
