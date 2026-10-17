# cocotb tests for rtl/conv_datapath.v

SIM ?= icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(abspath ../../rtl/conv_datapath.v) $(abspath ../../rtl/mul_u8s8.v)

COCOTB_TOPLEVEL = conv_datapath
COCOTB_TEST_MODULES = test_conv_datapath
export PYTHONPATH := $(abspath ../common):$(abspath ../../model):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
