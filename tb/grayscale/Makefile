# cocotb testbench for rtl/grayscale_axis.v
#   make                          run against the fixed RTL
#   make RTL=<path/to/file.v>     run against another version (e.g. the original)
#   make WAVES=1                  also dump a waveform for GTKWave

SIM ?= icarus
TOPLEVEL_LANG = verilog

RTL ?= $(abspath ../../rtl/grayscale_axis.v)
VERILOG_SOURCES = $(RTL)

COCOTB_TOPLEVEL = grayscale_axis
COCOTB_TEST_MODULES = test_grayscale_axis

include $(shell cocotb-config --makefiles)/Makefile.sim
