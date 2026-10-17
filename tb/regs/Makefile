# cocotb tests for rtl/conv_regs.v

SIM ?= icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(abspath ../../rtl/conv_regs.v)

COCOTB_TOPLEVEL = conv_regs
COCOTB_TEST_MODULES = test_conv_regs
export PYTHONPATH := $(abspath ../common):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
