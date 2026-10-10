# Post-synthesis hook: apply verilog-ethernet's CDC/timing constraints to the
# eth_mac_mii_fifo instance (mii_phy_if reset sync, eth_mac_*_fifo status
# sync, axis_async_fifo pointer/reset sync). These use get_cells against the
# synthesized netlist, so they cannot be plain XDC and must run post-synth.
set vendor_root [file join [file dirname [info script]] .. .. third_party verilog-ethernet]

foreach f {
    syn/vivado/mii_phy_if.tcl
    syn/vivado/eth_mac_fifo.tcl
    lib/axis/syn/vivado/sync_reset.tcl
    lib/axis/syn/vivado/axis_async_fifo.tcl
} {
    set fh [open [file join $vendor_root $f]]
    set script [read $fh]
    close $fh
    # The Ethernet interface's modules carry a prefix in their names; the filters match it.
    if {[info exists SEALED] && $SEALED} {
        regsub -all {(REF_NAME (==|=~) "?)(mii_phy_if|eth_mac_|sync_reset|axis_async_fifo)} $script {\1seal_\3} script
    }
    eval $script
}
