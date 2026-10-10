# Ensure these match the port names in your top-level HDL
set_property PACKAGE_PIN D7 [get_ports CLK_100_P]
set_property PACKAGE_PIN D6 [get_ports CLK_100_N]

# Define the differential I/O standard (LVDS)
set_property IOSTANDARD LVDS [get_ports CLK_100_P]
set_property IOSTANDARD LVDS [get_ports CLK_100_N]
# Define the timing constraint for the 100 MHz clock
create_clock -period 10.000 -name sys_clk_in [get_ports CLK_100_P]

## White LEDS (8 outputs)

set_property PACKAGE_PIN AF5 [get_ports {LEDS[0]}]
set_property PACKAGE_PIN AE7 [get_ports {LEDS[1]}]
set_property PACKAGE_PIN AH2 [get_ports {LEDS[2]}]
set_property PACKAGE_PIN AE5 [get_ports {LEDS[3]}]
set_property PACKAGE_PIN AH1 [get_ports {LEDS[4]}]
set_property PACKAGE_PIN AE4 [get_ports {LEDS[5]}]
set_property PACKAGE_PIN AG1 [get_ports {LEDS[6]}]
set_property PACKAGE_PIN AF2 [get_ports {LEDS[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports LEDS*]

## RGB LEDS (12 outputs)

set_property PACKAGE_PIN AD7 [get_ports {RGB_LED0[0]}]
set_property PACKAGE_PIN AD9 [get_ports {RGB_LED0[1]}]
set_property PACKAGE_PIN AE9 [get_ports {RGB_LED0[2]}]

set_property PACKAGE_PIN AG9 [get_ports {RGB_LED1[0]}]
set_property PACKAGE_PIN AE8 [get_ports {RGB_LED1[1]}]
set_property PACKAGE_PIN AF8 [get_ports {RGB_LED1[2]}]

set_property PACKAGE_PIN AF7 [get_ports {RGB_LED2[0]}]
set_property PACKAGE_PIN AG8 [get_ports {RGB_LED2[1]}]
set_property PACKAGE_PIN AG6 [get_ports {RGB_LED2[2]}]

set_property PACKAGE_PIN AF6 [get_ports {RGB_LED3[0]}]
set_property PACKAGE_PIN AH6 [get_ports {RGB_LED3[1]}]
set_property PACKAGE_PIN AG5 [get_ports {RGB_LED3[2]}]
set_property IOSTANDARD LVCMOS12 [get_ports RGB_LED*]

## Pushbutton Switches (4 inputs)

set_property PACKAGE_PIN AB6 [get_ports {BUTTONS[0]}]
set_property PACKAGE_PIN AB7 [get_ports {BUTTONS[1]}]
set_property PACKAGE_PIN AB2 [get_ports {BUTTONS[2]}]
set_property PACKAGE_PIN AC6 [get_ports {BUTTONS[3]}]
set_property IOSTANDARD LVCMOS12 [get_ports BUTTONS*]

## Slide Switches (8 inputs)

set_property PACKAGE_PIN AB1 [get_ports {SWITCHES[0]}]
set_property PACKAGE_PIN AF1 [get_ports {SWITCHES[1]}]
set_property PACKAGE_PIN AE3 [get_ports {SWITCHES[2]}]
set_property PACKAGE_PIN AC2 [get_ports {SWITCHES[3]}]
set_property PACKAGE_PIN AC1 [get_ports {SWITCHES[4]}]
set_property PACKAGE_PIN AD6 [get_ports {SWITCHES[5]}]
set_property PACKAGE_PIN AD1 [get_ports {SWITCHES[6]}]
set_property PACKAGE_PIN AD2 [get_ports {SWITCHES[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports SWITCHES*]

## PMODS (22 pins)

# H11 = TXD
# H12 = RXD
set_property IOSTANDARD LVCMOS33 [get_ports {FPGA_SERIAL_TX}];
set_property IOSTANDARD LVCMOS33 [get_ports {FPGA_SERIAL_RX}];
set_property PACKAGE_PIN H12 [get_ports {FPGA_SERIAL_TX}];
set_property PACKAGE_PIN H11 [get_ports {FPGA_SERIAL_RX}];

# NetTimeLogic PmEth on PMOD B (PMOD A carries the UART). Same pin order as the shell's
# PMOD A binding (ethernet-testing/src/zu3top.xdc): Pmod J1 1=RESET_N, 2=RXD0, 3=TX_EN,
# 4=TXD0, 7=REF_CLK, 8=RXD1, 9=CRS_DV, 10=TXD1. Pins 5/11 are GND; pins 6/12 are 3.3 V.
# set_property PACKAGE_PIN E12 [get_ports eth_reset_n]
# set_property PACKAGE_PIN D11 [get_ports eth_rxd0]
# set_property PACKAGE_PIN B11 [get_ports eth_tx_en]
# set_property PACKAGE_PIN A10 [get_ports eth_txd0]
# set_property PACKAGE_PIN C11 [get_ports eth_ref_clk]
# set_property PACKAGE_PIN B10 [get_ports eth_rxd1]
# set_property PACKAGE_PIN A12 [get_ports eth_crs_dv]
# set_property PACKAGE_PIN A11 [get_ports eth_txd1]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_reset_n eth_rxd0 eth_tx_en eth_txd0 eth_ref_clk eth_rxd1 eth_crs_dv eth_txd1}]

# ---------------------------------------------------------------------------
# ALTERNATIVE PHY -- Machdyne Katze (LAN8720A) on PMOD B. Commented out.
#
# To switch: comment out the eight PmEth PACKAGE_PIN lines above, uncomment the
# eight below. Nothing else changes. The IOSTANDARD line, every clock
# constraint below, and all of the RTL are written against the PORT names
# rather than the pins, so they carry over untouched -- including
# CLOCK_DEDICATED_ROUTE FALSE, which follows [get_ports eth_ref_clk] to
# whichever pin it lands on. (Still required either way: no JA/JB pin on this
# board is clock-capable.)
#
# The pin ORDER is completely different from the PmEth. Do not assume the two
# modules are interchangeable without re-reading this table.
#
#   Pmod pin   1    2    3     4      5   6    7    8    9     10    11  12
#   PmEth      RST  RXD0 TXEN  TXD0   GND 3V3  RCLK RXD1 CRSDV TXD1  GND 3V3
#   Katze      TXD0 TXD1 TXEN  CRSDV  GND 3V3  RXD0 RXD1 RST   RCLK  GND 3V3
#
# Only TX_EN (pin 3) and RXD1 (pin 8) coincide. Note REF_CLK moves C11 -> A11.
# Sources: machdyne.com/product/katze-ethernet-pmod/, github.com/machdyne/katze
#
# Why you might want it: the LAN8720A autonegotiates and has auto-MDIX, which
# removes the fixed-100-full-duplex mismatch documented in ethernet-testing's
# README -- the one that otherwise makes every host run `ethtool -s <if> speed
# 100 duplex full autoneg off` before anything works reliably under load.
#
# Why you might not: it can equally negotiate 10BASE-T, which is 10x slower per
# frame (57.6 us vs 5.76 us for a minimum-size frame), and its SMI/MDIO is only
# on back-side test pads, so nothing on the Pmod header can read back what the
# link actually settled on. A silently-negotiated 10 Mb link looks like a
# working link with inexplicable latency.
#
set_property PACKAGE_PIN E12 [get_ports eth_txd0]     ;# Pmod B pin 1
set_property PACKAGE_PIN D11 [get_ports eth_txd1]     ;# Pmod B pin 2
set_property PACKAGE_PIN B11 [get_ports eth_tx_en]    ;# Pmod B pin 3
set_property PACKAGE_PIN A10 [get_ports eth_crs_dv]   ;# Pmod B pin 4
set_property PACKAGE_PIN C11 [get_ports eth_rxd0]     ;# Pmod B pin 7
set_property PACKAGE_PIN B10 [get_ports eth_rxd1]     ;# Pmod B pin 8
set_property PACKAGE_PIN A12 [get_ports eth_reset_n]  ;# Pmod B pin 9
set_property PACKAGE_PIN A11 [get_ports eth_ref_clk]  ;# Pmod B pin 10
# ---------------------------------------------------------------------------

# The PmEth's 50 MHz RMII reference clocks the MII side of the MAC (src/eth/rmii_to_mii.v), a
# domain of its own: the MAC's async FIFOs cross it (their constraints are applied in impl,
# src/eth/apply_eth_mac_cdc_constraints.tcl). From ethernet-testing/src/zu3top.xdc.
create_clock -period 20.000 -name eth_ref_clk [get_ports eth_ref_clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports eth_ref_clk]]
create_generated_clock -name mii_tx_clk -source [get_ports eth_ref_clk] -divide_by 2 \
    [get_pins -hier -filter {NAME =~ */rmii_to_mii/mac_mii_txc_reg/Q}]
create_generated_clock -name mii_rx_clk -source [get_ports eth_ref_clk] -divide_by 2 \
    [get_pins -hier -filter {NAME =~ */rmii_to_mii/mac_mii_rxc_reg/Q}]
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_in] \
    -group [get_clocks -include_generated_clocks eth_ref_clk]
set_property IOB FALSE [get_cells -hierarchical -filter {NAME =~ *mii_phy_if_inst/*}]

# set_property PACKAGE_PIN F12 [get_ports {JAB_tri_io[0]}]
# set_property PACKAGE_PIN G11 [get_ports {JAB_tri_io[1]}]
# set_property PACKAGE_PIN E10 [get_ports {JAB_tri_io[2]}]
# set_property PACKAGE_PIN D10 [get_ports {JAB_tri_io[3]}]
# set_property PACKAGE_PIN F10 [get_ports {JAB_tri_io[4]}]
# set_property PACKAGE_PIN F11 [get_ports {JAB_tri_io[5]}]
# set_property IOSTANDARD LVCMOS33 [get_ports JAB_tri_io*]

# A 400 MHz counter in the Ethernet interface crosses into the CPU clock as a gray code:
# bound the skew between its bits to one period of that clock.
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ */seal/tb_gray_reg[*]}] \
    -to [get_cells -hier -filter {NAME =~ */seal/tb_sync0_reg[*]}] 2.500
