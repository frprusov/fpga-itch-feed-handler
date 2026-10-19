# Timing constraints for the out-of-context build of feed_handler.
#
# Target clock: 200 MHz (5.000 ns). Change the period to try other frequencies;
# build.tcl reports the maximum frequency that the design actually reaches.
create_clock -period 5.000 -name clk [get_ports clk]

# Out of context the clock does not come from a real pin. Tell Vivado it is driven
# by a global clock buffer, as it would be inside a full design.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
