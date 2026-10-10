source ../target.tcl

open_checkpoint ${ABS_TOP}/build/synth/${TOP}.dcp

if {[string trim ${CONSTRAINTS}] ne ""} {
  read_xdc ${CONSTRAINTS}
}

# The Ethernet MAC's and the async stream FIFOs' CDC constraints (verilog-ethernet's scripts).
# They find their cells in the netlist, so they run after read_xdc.
source ${ABS_TOP}/src/eth/apply_eth_mac_cdc_constraints.tcl

opt_design
place_design
write_checkpoint -force ${TOP}_placed.dcp
report_utilization -file post_place_utilization.rpt
phys_opt_design
route_design

write_checkpoint -force ${TOP}_routed.dcp
write_verilog -force post_route.v
write_xdc -force post_route.xdc
report_drc -file post_route_drc.rpt
report_timing_summary -warn_on_violation -file post_route_timing_summary.rpt

write_bitstream -force ${TOP}.bit
write_debug_probes -force ${TOP}.ltx
