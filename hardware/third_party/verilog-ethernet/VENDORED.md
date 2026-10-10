# Vendored copy

Source: https://github.com/alexforencich/verilog-ethernet
Commit: 77320a9471d19c7dd383914bc049e02d9f4f1ffb
License: MIT (see COPYING)

Includes `rtl/` (verilog-ethernet proper) and `lib/axis/` (its `verilog-axis`
dependency, merged upstream via git subtree). Only the synthesizable RTL and
the Vivado CDC/timing constraint scripts under `syn/vivado/` and
`lib/axis/syn/vivado/` are kept; cocotb testbenches, Quartus files, and CI
config were dropped since they're not used by this project.

`rtl/`/`lib/axis/rtl/` are further trimmed to this project's actual
dependency closure (traced from `eth_mac_mii_fifo`/`eth_axis_rx`/
`eth_axis_tx`/`axis_fifo`), not the full upstream directories. This matters
beyond tidiness: `scripts/synth.tcl`'s non-project `read_verilog -v`+
`synth_design` flow elaborates every file it's given up front (unlike the
Vivado *project* flow's lazy, hierarchy-driven elaboration), so an unrelated
broken file elsewhere in the full upstream tree (e.g. `ssio_sdr_in_diff.v`,
never instantiated here, fails to elaborate standalone) would fail the whole
build even though nothing in our design uses it. If you ever need another
verilog-ethernet module, re-vendor it (and its own transitive deps) rather
than restoring the full tree.

Used from this project: `eth_mac_mii_fifo.v`, `eth_axis_rx.v`, `eth_axis_tx.v`
(and their transitive dependencies), replacing Xilinx's `axi_ethernetlite_0`
as the MII-facing MAC. See /home/tmp/eecs151-tac/ethernet-testing/src/zu3top.sv.

The synthesis constraint scripts `syn/vivado/mii_phy_if.tcl`,
`syn/vivado/eth_mac_fifo.tcl`, `lib/axis/syn/vivado/sync_reset.tcl`, and
`lib/axis/syn/vivado/axis_async_fifo.tcl` insert `ASYNC_REG`/`set_max_delay`
constraints on the CDC synchronizer flops inside `eth_mac_mii_fifo` (MII
clock domain <-> logic_clk domain) and must be sourced as a post-synthesis
Tcl step — they use `get_cells` against the synthesized netlist, so they
cannot be plain XDC.
