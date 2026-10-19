# Phase 5: Open Items and Planned Extras

A working list to revisit later. Edit freely: add notes, cross things off, record what a reviewer or professor suggests.

Last updated: 2026-10-19 (after run `w128_80mhz_v7` and the PPA sweeps; see [asic.md](asic.md)).

## 1. Open problem: slow-corner setup timing

**Status.** The baseline (`MAX_WIDTH` 128, `sky130_fd_sc_hd`) passes LibreLane's sky130 sign-off: setup at the typical corner, hold at every corner, 0 DRC and 0 LVS. It does **not** meet this project's stricter goal of 80 MHz at every corner:

| Corner | Setup WNS @ 12.5 ns | Fmax (≈) |
|---|---:|---:|
| tt, 25 °C, 1.80 V | +3.57 ns | 112 MHz |
| ss, 100 °C, 1.60 V | −2.27 ns (TNS −19 ns) | 68 MHz |
| ff, −40 °C, 1.95 V | +5.95 ns | — |

At the slow corner about 9,000 pins also exceed the 0.75 ns max-transition limit (worst ≈ 2.05 ns).

**What has been tried** (full detail in [asic.md §3](asic.md#3-timing-closure-seven-runs)):

| Run | Change | Effect on ss setup |
|---|---|---|
| v2 | Skid buffers between blocks (RTL) | TNS halved |
| v3 | Excluded `clkdlybuf4s*` delay cells from buffering | Removed 1.4 ns-per-buffer chains |
| v4 | Repair margins slew 50 % / cap 40 % | Repair did not converge in 2 h (abandoned) |
| v4b | 80 MHz target (from the 720p60 requirement) | WNS −1.58 ns |
| v5 | Precomputed counter flags (RTL), realistic min input delay (SDC) | Hold closed everywhere |
| v6 | Free-running datapath with credit FIFO (RTL) | Removed a 650-flop enable net |
| v7 | `PNR_CORNERS` = ss, utilisation 40 → 50 % | TNS −19 ns, slew violations unchanged |

**Current diagnosis.**
- The flip-flop line buffers form a ~600 × 280 µm array (see the [placement map](img/asic_placement_w128.png)).
- The window generator's read address and enables must reach all of it every cycle, through long, heavily buffered nets.
- At ss these nets have 2+ ns transitions, and neither design changes nor repair settings have removed them.
- The width sweep is consistent with this: wider buffers give worse ss timing (74 → 68 → 65 → 58 MHz from width 64 to 512), while the typical corner stays flat.
- The high-speed library improves it (ss Fmax 75 MHz) at +33 % area and 2.2× power.

**Ideas not yet tried:**
1. **SRAM macros for the line buffers** (Extra B below). This removes the flip-flop array and its long nets entirely.
2. **Restructure the read path in RTL.** Bank the line buffers (for example 4 banks of 32 columns) and pipeline the read: register the bank select and decoded address one cycle early, so no single net spans the whole array. Costs a cycle of latency in the window generator.
3. **Floorplanning.** Constrain the line-buffer flops to a region next to the window generator, or harden the line buffers as their own macro and place it explicitly.
4. **Repair settings in small steps:** for example `DESIGN_REPAIR_MAX_SLEW_PCT` 20 → 30 with `PNR_CORNERS` at ss; `MAX_TRANSITION_CONSTRAINT`; `DESIGN_REPAIR_MAX_WIRE_LENGTH` around 800 µm (v4 changed too much at once).
5. **Mixed libraries:** `hs` cells only on the critical nets (if the flow allows mixing `hd` and `hs`).

**Questions to ask an expert:**
- Is ~68 MHz at ss for this structure reasonable for sky130 `hd` at 130 nm, or does it point to a flow problem?
- For a flip-flop array of this size, what is the usual fix: banking and pipelining in RTL, floorplan guidance, or simply SRAM?
- Is signing off setup at tt (LibreLane's sky130 default) acceptable for an academic project, provided the ss Fmax is reported?
- Why might slow-corner placement and repair (`PNR_CORNERS` = ss) leave the slew violations essentially unchanged?

## 2. Extra A: fixed kernel versus programmable kernel

**Question:** what does programmability cost? Compare the baseline (two general 3×3 MAC lanes, 18 multipliers, kernel registers) with a hard-wired Sobel datapath that uses shift-and-add for the fixed coefficients.

| Step | Estimate |
|---|---|
| `FIXED_SOBEL` parameter in `conv_datapath.v` (constants instead of `k0_a`/`k1_a`, no multipliers) | 30–45 min |
| Run the existing tests on the variant (the Sobel preset is already bit-exact) | 10 min |
| One ASIC run | ~50 min |
| Add a row to [asic.md §4](asic.md) | 10 min |

Risk: low. Expected: a much smaller datapath and better timing.

## 3. Extra B: SRAM line buffers

**Question:** how much area and timing does a real memory save over flip-flop line buffers? The fit predicts 1.17 mm² of flip-flop cells at 720p against 0.57 mm² for two SRAM macros.

| Step | Estimate |
|---|---|
| `line_ram` variant wrapping `sky130_sram_1kbyte_1rw1r_8x1024_8` (write on port 0, read on port 1) | 45 min |
| Simulate with the macro's behavioural model; all tests must still pass | 30 min |
| LibreLane macro integration: `MACROS` config, placement, power hookup, halo | 45 min |
| ASIC runs: probably 2–3 for first-time macro integration | 2–3 h, mostly unattended |
| Write-up | 15 min |

Risks:
- The PDK ships **only a typical-corner timing model** for the macros, so multi-corner STA needs a documented workaround.
- Open-source SRAM macros may need DRC exceptions.
- The macro's read timing may need an extra pipeline stage in the window generator.

## 4. Decisions log

- 2026-10-19: chose to sign off at the typical corner (LibreLane default) and report the slow-corner Fmax honestly; extras deferred while the technical report (Phase 6) is written and expert advice is sought.
