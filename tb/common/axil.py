"""Reusable AXI4-Lite master for cocotb testbenches.

Randomises the relative timing of the AW and W channels (AW first, W first,
or together) and delays bready/rready, and checks that the slave holds its
responses until they are accepted.
"""

import random

import cocotb
from cocotb.triggers import Combine, RisingEdge


class AxiLiteMaster:
    def __init__(self, dut, clk, prefix="s_axi_", max_delay=3, seed=0):
        self.clk = clk
        self.s = lambda name: getattr(dut, prefix + name)
        self.max_delay = max_delay
        self.rng = random.Random(seed)
        for name in ("awvalid", "wvalid", "bready", "arvalid", "rready"):
            self.s(name).value = 0
        self.s("awaddr").value = 0
        self.s("araddr").value = 0
        self.s("wdata").value = 0
        self.s("wstrb").value = 0

    async def _delay(self):
        for _ in range(self.rng.randint(0, self.max_delay)):
            await RisingEdge(self.clk)

    async def _handshake(self, valid, ready):
        """Hold valid high until the slave's ready is sampled high at a clock edge."""
        valid.value = 1
        while True:
            await RisingEdge(self.clk)
            if ready.value:
                break
        valid.value = 0

    # After each handshake the payload wires are scrambled: a slave must have
    # captured what it needs at the handshake, not read the bus later.

    async def _send_aw(self, addr):
        await self._delay()
        self.s("awaddr").value = addr
        await self._handshake(self.s("awvalid"), self.s("awready"))
        self.s("awaddr").value = self.rng.getrandbits(len(self.s("awaddr")))

    async def _send_w(self, data, strb):
        await self._delay()
        self.s("wdata").value = data
        self.s("wstrb").value = strb
        await self._handshake(self.s("wvalid"), self.s("wready"))
        self.s("wdata").value = self.rng.getrandbits(32)
        self.s("wstrb").value = self.rng.getrandbits(4)

    async def _take_response(self, valid, fields):
        """Wait for valid, stall a random time checking the response is held, then accept."""
        while not valid.value:
            await RisingEdge(self.clk)
        snapshot = [int(f.value) for f in fields]
        for _ in range(self.rng.randint(0, self.max_delay)):
            await RisingEdge(self.clk)
            assert valid.value, "response valid dropped before it was accepted"
            assert [int(f.value) for f in fields] == snapshot, "response changed before it was accepted"
        return snapshot

    async def write(self, addr, data, strb=0xF):
        aw = cocotb.start_soon(self._send_aw(addr))
        w = cocotb.start_soon(self._send_w(data, strb))
        await Combine(aw, w)
        bresp, = await self._take_response(self.s("bvalid"), [self.s("bresp")])
        self.s("bready").value = 1
        await RisingEdge(self.clk)
        self.s("bready").value = 0
        assert bresp == 0, f"write to 0x{addr:02X} returned BRESP={bresp}"

    async def read(self, addr):
        await self._delay()
        self.s("araddr").value = addr
        await self._handshake(self.s("arvalid"), self.s("arready"))
        self.s("araddr").value = self.rng.getrandbits(len(self.s("araddr")))
        rdata, rresp = await self._take_response(self.s("rvalid"), [self.s("rdata"), self.s("rresp")])
        self.s("rready").value = 1
        await RisingEdge(self.clk)
        self.s("rready").value = 0
        assert rresp == 0, f"read from 0x{addr:02X} returned RRESP={rresp}"
        return rdata
