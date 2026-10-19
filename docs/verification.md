# Verification Summary

How the streaming convolution engine (`rtl/conv_engine.v`) was verified, what each method proves, and what it doesn't.

## At a glance

| Method | Scope | Result |
|---|---|---|
| Golden model | Bit-exact Python reference (`model/conv_model.py`) | 14 unit tests pass |
| Simulation (cocotb) | 32 tests across 5 testbenches, every block plus the top level | All pass on **Icarus Verilog 12** and **Verilator 5.040** |
| End-to-end | Real images, all 7 filter presets, random stalls, 720p frames | **1.89 M output pixels bit-exact** with the model |
| Formal (SymbiYosys) | Skid buffer, register block, window generator | **Unbounded proofs** on every interface protocol; **bounded proof** of window contents |
| Mutation testing | 14 deliberately injected bugs (18 runs across simulation and formal) | **All 14 caught** (1 only after a testbench fix, see §5) |
| Coverage (Verilator) | All 8 RTL modules | **100 % line, branch, expression and toggle**, with 82 documented waivers |

## 1. Strategy

Each method covers a weakness of another:

- **Simulation against a golden model** checks *values*: every output pixel is compared with an independent Python implementation, on real images and random data.
- **Formal verification** checks *protocol behaviour for every possible input sequence*: no amount of random simulation can show that a handshake rule holds for all stall patterns, but a proof can.
- **Mutation testing** checks *the checkers*: each testbench and proof is run against deliberately broken RTL to confirm it can actually fail.
- **Coverage** checks *what was exercised*, and found two error-recovery paths that no test had reached.

The model (`model/conv_model.py`) is the single source of truth. It's written with integer arithmetic using the same widths, rounding and saturation as the RTL. Where this document and the model disagree, the model wins.

## 2. Simulation

Testbenches are written in Python with cocotb 2.1. Shared drivers live in [`tb/common/`](../tb/common):

- **`AxisSource` / `AxisSink`:** an AXI4-Stream driver and checker. Random idle cycles and random backpressure; checks that a stalled beat is held unchanged. While idle, the source scrambles its payload wires, so a design that reads data without `tvalid` fails.
- **`AxiLiteMaster`:** an AXI4-Lite driver. Randomly sends AW before W, W before AW, or both together; delays `bready`/`rready` and checks that responses are held; scrambles address and data wires after each handshake.

| Testbench | Tests | What it covers |
|---|---|---|
| `tb/skid` | 4 | 2,500 random beats across 5 stall/idle mixes; full throughput (200 beats in 201 cycles); `s_ready` independent of `m_ready` |
| `tb/window` | 8 | Every border case (1×1, 1×N, N×1 …); 2048-wide frames; 4095-line frames; random sizes with backpressure; invalid config; mid-frame start of frame; misplaced `tlast`; junk before the first frame |
| `tb/datapath` | 5 | All presets; 60 random configurations; 36 worst-case accumulator configurations; config scrambled mid-frame must be ignored; 1 window/clock |
| `tb/regs` | 7 | Reset values; 300 random write/read pairs against a shadow model; byte strobes; unmapped and read-only addresses; write-1-to-clear; unaligned addresses; zero-delay back-to-back |
| `tb/top` | 8 | ID and reset passthrough; 7 presets × 3 images; config written mid-frame applies to the next frame; random sizes and kernels; frame-error report and recovery; register read-back; throughput; **two full 1280×720 frames** (`STRESS=1`) |

Every test passes on both Icarus and Verilator. These are independent simulators, so a race or simulator-specific behaviour would likely show up as a mismatch between them.

**Measured performance (simulation):** a 64×64 frame takes 4,240 cycles against an ideal (W+1)(H+1) = 4,225; latency is one line + 1 pixel + 15 cycles.

## 3. Formal verification

Properties are written inline in the RTL under `` `ifdef FORMAL `` (ignored by synthesis and simulation) and run with SymbiYosys v0.52 on Yosys 0.52.

| Block | Properties | Engine | Result | Run time |
|---|---|---|---|---|
| `axis_skid` | AXI4-Stream hold rule on the output; reset empties the buffer; the skid entry is used only behind a full main entry; **every beat leaves intact, in order, exactly once** (an arbitrary beat index chosen by the solver) | smtbmc / z3, k-induction | **PASS, unbounded** | ~1 s |
| `conv_regs` | Responses held until accepted; **exactly one B per AW+W and one R per AR**, in any arrival order; at most one transaction outstanding; full-strobe CTRL write lands (checked against data captured independently from the bus); WIDTH read returns the register; clear pulse only after a W1C write | smtbmc / z3, k-induction | **PASS, unbounded** | ~1 s |
| `conv_window` (protocol) | AXI4-Stream hold rule; `tuser` on exactly the first window of each frame; `tlast` on exactly each line end; no false error flag for well-formed input. Frames up to 3×3 | ABC PDR (IC3) | **PASS, unbounded** | 3 min 55 s |
| `conv_window` (data) | **Every output window holds exactly the right nine pixels, including edge replication** (an arbitrary pixel position chosen by the solver, tracked per frame). Frames up to 3×2 | ABC bmc3 | **PASS, bounded to 24 cycles** | 14 min 6 s |

Cover statements confirm the proofs aren't vacuous: the skid entry fills and drains, data-before-address and address-before-data writes both complete, and a full 3×2 frame completes at step 16 (so the 24-cycle bound covers a whole frame plus the start of the next).

The window generator is run with `MAX_WIDTH` = 8 instead of 2048. The logic is identical; only the line-buffer depth changes.

**What it took:**
- The register-block proof initially returned UNKNOWN. Induction was starting from unreachable states, and two invariants tying the checker's copies to the design's held copies closed it.
- On the window generator, smtbmc with z3 needed over 6 minutes per step by step 14. Switching to ABC's bit-level engines, and splitting the cheap protocol properties from the expensive data property, let the protocol side close as an unbounded proof.

## 4. Coverage

All five testbenches run under Verilator with `--coverage`. The results are merged and reported per module by [`tb/coverage_report.py`](../tb/coverage_report.py), which combines points by source location so that a line hit in either the block-level or the top-level testbench counts once.

| Module | Line | Branch | Expression | Toggle |
|---|---|---|---|---|
| `axis_skid` | 5/5 | 10/10 | 5/5 | 174/174 |
| `luma_axis` | 4/4 | 6/6 | 5/5 | 232/232 |
| `conv_window` | 16/16 | 34/34 | 56/56 | 820/820 |
| `line_ram` | 1/1 | 4/4 | – | 82/82 |
| `conv_datapath` | 16/16 | 44/44 | 19/19 | 2,738/2,738 |
| `mul_u8s8` | 1/1 | 2/2 | – | 70/70 |
| `conv_regs` | 36/36 | 26/26 | 15/15 | 1,166/1,166 |
| `conv_engine` | – | – | – | 922/922 |
| **Total** | **100 %** | **100 %** | **100 %** | **100 %** |

**Waivers (82 points):** each is a point that can't be reached by construction.

| Module | Points | Reason |
|---|---|---|
| `conv_datapath` | 20 | Rounding constant is at most 2¹⁴ (shift ≤ 15) |
| `conv_datapath` | 4 | \|lane\| ≤ 310,144 < 2¹⁹, so bit 19 is always 0 |
| `conv_regs`, `conv_engine` | 16 | Responses are always OKAY by design |
| `conv_regs`, `conv_engine` | 30 | No register (or the ID) has read-data bits 26–29 or 31 set |
| `conv_regs` | 8 | Unused SHIFT bits are masked to 0 on write |
| `luma_axis` | 2 | 150·G is always even |
| `luma_axis` | 2 | 77·R + 29·B ≤ 26,010 < 2¹⁵ |

**Gaps that coverage found and closed:** the first run reported 89 %. After merging by location and applying waivers, these real gaps remained, and each now has a test:
- a frame starting with an invalid configuration;
- a start of frame arriving mid-frame;
- unaligned AXI-Lite addresses;
- frames tall or wide enough to use the top bits of the size counters;
- register read-back through the top-level port.

The first two are error-recovery paths that no test had exercised.

## 5. Mutation testing

A check that has never failed proves nothing. Each of these bugs was injected into a copy of the RTL and run against the relevant tests or proofs:

| Block | Injected bug | Caught by |
|---|---|---|
| `grayscale_axis` (Phase 0) | Original code: output overwritten under backpressure; wrong RGB channel order | Simulation (96 protocol violations; wrong first pixel) |
| `axis_skid` | `s_ready` tied to 1 | Simulation (65 of 500 beats lost); formal (counterexample) |
| `conv_window` | Left-edge replication removed | Simulation (5/5 tests); formal data proof |
| `conv_window` | Bottom-edge replication removed | Simulation (5/5 tests) |
| `conv_window` | `tlast` check disabled | Simulation (framing test) |
| `conv_window` | `tlast` off by one | Formal protocol proof |
| `conv_datapath` | Config latched every beat instead of at start of frame | Simulation (mid-frame scramble test only) |
| `conv_datapath` | Rounding removed | Simulation (5/5 tests) |
| `conv_datapath` | Logical instead of arithmetic shift | Simulation (5/5 tests) |
| `conv_datapath` | Negative values not clamped to 0 | Simulation (4/5 tests) |
| `conv_regs` | Write data taken from the live bus when W arrived before AW | Simulation **after a testbench fix**; formal (independent checker) |
| `conv_regs` | Write response dropped before `bready` | Simulation (4 tests); formal |
| `conv_regs` | Byte strobes ignored | Simulation (strobe test) |
| `conv_regs` | Second write accepted while a response is pending | Formal |

**Testbench weaknesses this exposed:**
- The `conv_regs` write-data bug initially passed every simulation test. The test master left the old data on the bus after each handshake, so the broken design read the right value by luck. Both bus drivers now scramble their wires when idle.
- Likewise, the first formal check for CTRL writes used the design's own internal data mux, so it would have agreed with the bug. It was rewritten to use data captured independently from the bus.

## 6. Limitations

- **Window contents are proven only for small frames** (≤ 3×2, 24 cycles). Full-size frames are covered by simulation: real images, 2048-wide frames, 4095-line frames, and two 720p frames.
- **The datapath is not formally verified.** Its arithmetic is checked by simulation against the model, including all-extreme coefficient and pixel values; the accumulator width is justified analytically (9 × 128 × 255 < 2¹⁹) and by the model's overflow assertion.
- **The design uses a single clock domain.** In the FPGA system the AXI4-Lite port will reach the engine through an interconnect clock converter; that crossing is Xilinx IP and isn't verified here.
- **No hardware test yet.** FPGA results so far come from out-of-context synthesis and place and route (898 LUTs, 1,012 FFs, 1 BRAM36, 18 DSP48s, +0.81 ns slack at 150 MHz). Running on the PYNQ-Z2 is Phase 4.

## 7. Reproducing

In WSL / Linux, with the cocotb venv active and `~/.local/bin` on `PATH` (Verilator ≥ 5.036, SymbiYosys):

```bash
cd model && python -m pytest                     # golden model
cd tb/top && make                                # any testbench (Icarus); add SIM=verilator for Verilator
cd tb/top && STRESS=1 make SIM=verilator         # include the 720p stress test
cd tb && ./run_coverage.sh                       # all testbenches under Verilator + coverage report (~4 min)
cd formal/skid && sby -f skid.sby                # formal: also formal/regs, formal/window (window ~20 min)
```

Tool versions: Icarus Verilog 12.0, Verilator 5.040, cocotb 2.1.0, Python 3.14, Yosys 0.52, SymbiYosys v0.52, Z3 4.13.3, ABC (bundled with Yosys).
