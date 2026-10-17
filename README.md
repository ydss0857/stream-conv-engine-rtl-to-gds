# Streaming Convolution Engine: RTL to GDS

A hand-designed, line-buffered 3×3 streaming convolution engine (Sobel / Gaussian) with AXI4-Stream and AXI4-Lite interfaces. It is verified against a bit-exact Python golden model, demonstrated live on HDMI video on a PYNQ-Z2 FPGA, and taken through an open-source ASIC flow to a GDS layout for a PPA study.

Builds on [Pynq-Z2_VideoP](https://github.com/Antonioio95/Pynq-Z2_VideoP), the HDMI grayscale pipeline that serves as the FPGA test harness.

## Layout

| Path | Contents |
|---|---|
| `rtl/` | Technology-independent Verilog for the convolution engine |
| `tb/` | cocotb testbenches |
| `model/` | Python golden model (fixed-point, bit-exact) |
| `formal/` | SymbiYosys formal proofs (AXI-Stream properties) |
| `fpga/` | Vivado project for PYNQ-Z2 (HDMI in → engine → HDMI out) |
| `asic/` | OpenLane 2 flow configuration and PPA results |
| `docs/` | Architecture diagrams and the technical report |

## Plan

| Phase | Work |
|---|---|
| 0 | Tool setup; fix backpressure in `grayscale_axis`; first cocotb testbench |
| 1 | Python golden model, fixed-point analysis, block diagram |
| 2 | RTL: line buffers, 3×3 window, convolution datapath, skid buffers, AXI4-Lite registers |
| 3 | Verification: bit-exact image tests, randomized backpressure, formal proofs, coverage |
| 4 | FPGA integration and live HDMI demo on PYNQ-Z2 |
| 5 | ASIC flow (OpenLane 2, open PDK): GDS, PPA study, FPGA vs ASIC comparison |
| 6 | Write-up and technical report |

## FPGA Build Requirements

- Vivado 2023.2
- [Digilent vivado-library](https://github.com/Digilent/vivado-library) at `C:\xilinx_ip\vivado-library` (provides `dvi2rgb` / `rgb2dvi`)
