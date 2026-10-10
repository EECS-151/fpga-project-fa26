# program.tcl

# Check if an argument was provided
if { $argc > 0 } {
    set port [lindex $argv 0]
    puts "Connecting to hw_server on port: $port"
} else {
    puts "Error: No port provided. Usage: vivado -source program.tcl -tclargs <port>"
    exit 1
}

source ../target.tcl
open_hw_manager

connect_hw_server -url localhost:$port -allow_non_jtag

after 2000; # 2-second delay
refresh_hw_server

current_hw_target [get_hw_targets */xilinx_tcf/Xilinx/*]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets */xilinx_tcf/Xilinx/*]
open_hw_target

current_hw_device [get_hw_devices xczu*]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xczu*] 0]
set_property PROBES.FILE {} [get_hw_devices xczu*]
set_property FULL_PROBES.FILE {} [get_hw_devices xczu*]

# Hack to expand ${ABS_TOP} and ${TOP} properly, running set_property directly doesn't expand these variables
set set_cmd "set_property PROGRAM.FILE \{${ABS_TOP}/build/impl/${TOP}.bit\} \[get_hw_devices xczu*\]"
eval ${set_cmd}
program_hw_devices [get_hw_devices xczu*]
refresh_hw_device [lindex [get_hw_devices xczu*] 0]

close_hw_manager
