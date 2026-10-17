# cocotb tests for rtl/conv_window.v (+ rtl/line_ram.v)

SIM ?= icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(abspath ../../rtl/conv_window.v) $(abspath ../../rtl/line_ram.v)

COCOTB_TOPLEVEL = conv_window
COCOTB_TEST_MODULES = test_conv_window
export PYTHONPATH := $(abspath ../common):$(abspath ../../model):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
