SIM ?= ghdl
TOPLEVEL_LANG ?= vhdl

VHDL_SOURCES += $(PWD)/../../rtl/counter.vhd

COCOTB_TOPLEVEL = counter
COCOTB_TEST_MODULES = test_counter

GHDL_ARGS += --std=08
SIM_ARGS  += --wave=counter.ghw

include $(shell cocotb-config --makefiles)/Makefile.sim