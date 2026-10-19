# build.tcl
# Out-of-context synthesis and implementation of feed_handler for the PYNQ-Z2
# (Zynq-7020, xc7z020clg400-1). Reports timing (maximum clock frequency) and
# resource usage.
#
# Why out of context: the top level has ~140 data pins (64-bit refs, 32-bit
# prices), more than the package offers. Out of context, Vivado treats the ports
# as internal connections and measures the core on its own, register to register.
#
# Usage, from this folder:
#   Vivado Tcl Shell :  source build.tcl
#   Windows cmd      :  vivado -mode batch -source build.tcl
#
# Results go to ./out:
#   summary.txt          clock period, worst slack, Fmax, LUT/FF/BRAM counts
#   timing_summary.rpt   full timing report
#   critical_paths.rpt   the 10 slowest paths, cell by cell
#   utilization*.rpt     resources, also per module (hier)

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set out        [file join $script_dir out]
set part       xc7z020clg400-1
set top        feed_handler

file mkdir $out

# --- sources ----------------------------------------------------------------
read_vhdl -vhdl2008 [list \
  [file join $root rtl itch_pkg.vhd] \
  [file join $root rtl itch_parser.vhd] \
  [file join $root rtl order_book.vhd] \
  [file join $root rtl feed_handler.vhd] \
]
read_xdc -mode out_of_context [file join $script_dir feed_handler_ooc.xdc]

# --- synthesis ---------------------------------------------------------------
synth_design -top $top -part $part -mode out_of_context
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization    -file [file join $out utilization_synth.rpt]
report_timing_summary -file [file join $out timing_synth.rpt]

# --- implementation ------------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out post_route.dcp]

# --- reports -------------------------------------------------------------------
report_utilization                -file [file join $out utilization.rpt]
report_utilization -hierarchical  -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_timing -max_paths 10 -nworst 1 -path_type full -file [file join $out critical_paths.rpt]

# --- summary -------------------------------------------------------------------
set period [get_property PERIOD [get_clocks clk]]
set path   [get_timing_paths -setup -max_paths 1 -nworst 1]
set wns    [get_property SLACK $path]
set fmax   [expr {1000.0 / ($period - $wns)}]

proc cell_count {pattern} {
  return [llength [get_cells -hierarchical -filter "PRIMITIVE_TYPE =~ $pattern"]]
}
set luts  [cell_count "CLB.LUT.*"]
set ffs   [cell_count "REGISTER.*.*"]
set bram  [cell_count "BLOCKRAM.*.*"]

set lines [list \
  "feed_handler on $part (out of context)" \
  [format "Clock period target : %.3f ns (%.1f MHz)" $period [expr {1000.0 / $period}]] \
  [format "Worst setup slack   : %.3f ns" $wns] \
  [format "Max frequency       : %.1f MHz" $fmax] \
  "Critical path       : [get_property STARTPOINT_PIN $path] -> [get_property ENDPOINT_PIN $path]" \
  "LUTs                : $luts" \
  "Flip-flops          : $ffs" \
  "Block RAM cells     : $bram" \
]
set fh [open [file join $out summary.txt] w]
foreach l $lines { puts $l; puts $fh $l }
close $fh

if {$wns < 0} {
  puts "TIMING NOT MET at the target clock: see out/critical_paths.rpt"
} else {
  puts "Timing met."
}
