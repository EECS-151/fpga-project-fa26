# CKPT 3 constraints, only read the Makefile reads this file only with HAS_ACCEL=1

# The CPU and accelerator clocks come from separate PLLs, and every path between them goes through
# a synchronizer or a handshake so time those paths
# as asynchronous.
# data path only, within the shorter clock period (bounds gray-pointer skew and
# keeps handshake data settled before the synchronized request arrives).
set cpu_clk   [get_clocks -of_objects [get_pins clk_gen/cpu_clk_buf/O]]
set accel_clk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ clk_gen/*accel_clk_buf/O}]]
set cdc_max_delay [expr {min([get_property PERIOD $cpu_clk], [get_property PERIOD $accel_clk])}]
set_max_delay -datapath_only -from $cpu_clk -to $accel_clk $cdc_max_delay
set_max_delay -datapath_only -from $accel_clk -to $cpu_clk $cdc_max_delay

# The 100 MHz clock feeds three MMCMs (CPU, accelerator, Ethernet interface), one per clock region
# of the CMT column. Route it on the clock backbone so they needn't be next to its input pin,
# and fix the CPU and accelerator MMCMs below the Ethernet interface's.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets CLK_100MHZ]
set_property LOC MMCM_X0Y1 [get_cells clk_gen/plle2_cpu_inst]
set_property LOC MMCM_X0Y0 [get_cells -hier -filter {NAME =~ clk_gen/*mmcm_accel_inst}]

# The Ethernet interface's link status crosses into the accelerator clock through a two-flop
# synchronizer.
set_false_path -to [get_cells -hier -filter {NAME =~ */seal/link_sync_reg[0]}]
