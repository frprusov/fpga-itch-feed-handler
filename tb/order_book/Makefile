SIM ?= ghdl
TOPLEVEL_LANG ?= vhdl

# Order matters: the package must be compiled before the order book that uses it.
VHDL_SOURCES += $(PWD)/../../rtl/itch_pkg.vhd
VHDL_SOURCES += $(PWD)/../../rtl/order_book.vhd

COCOTB_TOPLEVEL = order_book
COCOTB_TEST_MODULES = test_order_book

GHDL_ARGS += --std=08

# Waveforms are off by default (the random test makes the file large).
# Enable with:   make WAVES=1
ifeq ($(WAVES),1)
SIM_ARGS += --wave=order_book.ghw
endif

# Make the Python reference model (the model/ folder in the repo root) importable.
export PYTHONPATH := $(PWD)/../..:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
