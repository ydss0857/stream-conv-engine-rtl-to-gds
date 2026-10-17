# End-to-end cocotb tests for rtl/conv_engine.v
#   make                 run all tests
#   make SAVE_IMAGES=1   also write docs/img/rtl_sim_astronaut.png

SIM ?= icarus
TOPLEVEL_LANG = verilog

RTL = $(abspath ../../rtl)
VERILOG_SOURCES = $(RTL)/conv_engine.v $(RTL)/conv_regs.v $(RTL)/axis_skid.v $(RTL)/luma_axis.v \
                  $(RTL)/conv_window.v $(RTL)/line_ram.v $(RTL)/conv_datapath.v $(RTL)/mul_u8s8.v

COCOTB_TOPLEVEL = conv_engine
COCOTB_TEST_MODULES = test_conv_engine
export PYTHONPATH := $(abspath ../common):$(abspath ../../model):$(PYTHONPATH)
export SAVE_IMAGES

include $(shell cocotb-config --makefiles)/Makefile.sim
