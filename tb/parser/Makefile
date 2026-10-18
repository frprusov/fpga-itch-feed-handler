SIM ?= ghdl
TOPLEVEL_LANG ?= vhdl

# Order matters: the package must be compiled before the parser that uses it.
VHDL_SOURCES += $(PWD)/../../rtl/itch_pkg.vhd
VHDL_SOURCES += $(PWD)/../../rtl/itch_parser.vhd

COCOTB_TOPLEVEL = itch_parser
COCOTB_TEST_MODULES = test_parser

GHDL_ARGS += --std=08
SIM_ARGS  += --wave=itch_parser.ghw

# Make the Python reference model (the model/ folder in the repo root) importable.
export PYTHONPATH := $(PWD)/../..:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
