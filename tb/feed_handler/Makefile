SIM ?= ghdl
TOPLEVEL_LANG ?= vhdl

# Order matters: dependencies first, top level last.
VHDL_SOURCES += $(PWD)/../../rtl/itch_pkg.vhd
VHDL_SOURCES += $(PWD)/../../rtl/itch_parser.vhd
VHDL_SOURCES += $(PWD)/../../rtl/order_book.vhd
VHDL_SOURCES += $(PWD)/../../rtl/feed_handler.vhd

COCOTB_TOPLEVEL = feed_handler
COCOTB_TEST_MODULES = test_feed_handler

GHDL_ARGS += --std=08

# Stop the simulation on a VHDL assertion of severity error (e.g. the busy check).
SIM_ARGS += --assert-level=error

# Waveforms are off by default (the random test makes the file large).
# Enable with:   make WAVES=1
ifeq ($(WAVES),1)
SIM_ARGS += --wave=feed_handler.ghw
endif

# Make the Python reference model (the model/ folder in the repo root) importable.
export PYTHONPATH := $(PWD)/../..:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
