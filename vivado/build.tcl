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

# =============================================================================
# Settings
# =============================================================================

# CPU threads for Vivado (max 8 for most steps). Use the number of cores you have.
set THREADS  8

# Target clock period in ns. 10.0 = 100 MHz, 6.4 = 156.25 MHz, 5.0 = 200 MHz.
# The reported Fmax is computed from the slack, so it is meaningful whatever the
# target: a design that reaches 130 MHz reports ~130 MHz with a 10 ns target too.
# A far-too-tight target makes synthesis spend a very long time on timing.
set CLOCK_NS 10.0

# 1 = fast run: runtime-optimized directives, no phys_opt_design. Good for a first
#     measurement; Fmax can come out a little lower than the best possible.
# 0 = default effort.
set FAST     1

# =============================================================================

set_param general.maxThreads $THREADS

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set out        [file join $script_dir out]
set part       xc7z020clg400-1
set top        feed_handler

file mkdir $out

if {$FAST} {
  set directive RuntimeOptimized
} else {
  set directive Default
}

proc stamp {msg} {
  puts "=== [clock format [clock seconds] -format %H:%M:%S]  $msg"
}

# --- constraints (generated from the settings above) --------------------------
set xdc [file join $out constraints_ooc.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"
# Out of context the clock does not come from a real pin: model a global buffer.
puts $fh "set_property HD.CLK_SRC BUFGCTRL_X0Y0 \[get_ports clk\]"
close $fh

# --- sources ----------------------------------------------------------------
stamp "reading sources"
read_vhdl -vhdl2008 [list \
  [file join $root rtl itch_pkg.vhd] \
  [file join $root rtl itch_parser.vhd] \
  [file join $root rtl order_book.vhd] \
  [file join $root rtl feed_handler.vhd] \
]
read_xdc -mode out_of_context $xdc

# --- synthesis ---------------------------------------------------------------
stamp "synthesis ($directive)"
synth_design -top $top -part $part -mode out_of_context -directive $directive
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization    -file [file join $out utilization_synth.rpt]
report_timing_summary -file [file join $out timing_synth.rpt]

# --- implementation ------------------------------------------------------------
# All default optimizations except BRAM power optimization, which crashed
# Vivado 2024.2 on this design (EXCEPTION_ACCESS_VIOLATION in pwropt).
stamp "opt_design"
opt_design -retarget -propconst -sweep -bufg_opt -shift_register_opt

stamp "place_design ($directive)"
place_design -directive $directive

if {!$FAST} {
  stamp "phys_opt_design"
  phys_opt_design
}

stamp "route_design ($directive)"
route_design -directive $directive
write_checkpoint -force [file join $out post_route.dcp]

# --- reports -------------------------------------------------------------------
stamp "reports"
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
  return [llength [get_cells -hierarchical -quiet -filter "IS_PRIMITIVE && REF_NAME =~ $pattern"]]
}
set luts  [cell_count "LUT*"]
set ffs   [cell_count "FD*"]
set bram  [cell_count "RAMB*"]

set lines [list \
  "feed_handler on $part (out of context, FAST=$FAST, $THREADS threads)" \
  [format "Clock period target : %.3f ns (%.1f MHz)" $period [expr {1000.0 / $period}]] \
  [format "Worst setup slack   : %.3f ns" $wns] \
  [format "Max frequency       : %.1f MHz" $fmax] \
  "Critical path       : [get_property STARTPOINT_PIN $path] -> [get_property ENDPOINT_PIN $path]" \
  "LUTs                : $luts  (of 53200)" \
  "Flip-flops          : $ffs  (of 106400)" \
  "Block RAM (RAMB36)  : $bram  (of 140)" \
]
set fh [open [file join $out summary.txt] w]
foreach l $lines { puts $l; puts $fh $l }
close $fh

if {$wns < 0} {
  puts "TIMING NOT MET at the target clock: see out/critical_paths.rpt"
} else {
  puts "Timing met."
}
stamp "done"
