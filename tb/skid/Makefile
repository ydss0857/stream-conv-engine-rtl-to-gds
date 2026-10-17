# cocotb tests for rtl/axis_skid.v (DATA_W=26: 24-bit pixel + tuser + tlast)

SIM ?= icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(abspath ../../rtl/axis_skid.v)
ifeq ($(SIM),verilator)
EXTRA_ARGS += -GDATA_W=26
else
COMPILE_ARGS += -Paxis_skid.DATA_W=26
endif

COCOTB_TOPLEVEL = axis_skid
COCOTB_TEST_MODULES = test_axis_skid
export PYTHONPATH := $(abspath ../common):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
