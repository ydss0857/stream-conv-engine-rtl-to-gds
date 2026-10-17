## Implementation-only: clk_fpga_* come from the PS7 netlist, which is a black box during synthesis.
## PS FCLK0 (AXI), PS FCLK1 (dvi2rgb RefClk) and the HDMI-recovered pixel clock are unrelated.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_fpga_0] \
    -group [get_clocks -include_generated_clocks clk_fpga_1] \
    -group [get_clocks -include_generated_clocks TMDS_clk]
