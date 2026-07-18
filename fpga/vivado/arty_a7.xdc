# Copyright 2026 University of Applied Sciences Munich
# Christopher Hinz <christopher.hinz@hm.edu>
#
# Arty A7 (35T/100T) constraints for top_model, Vivado flow. Same physical
# pins as fpga/arty/arty_a7.xdc -- only the Pmod JA block differs, because
# here SIO0..3 are one real bidirectional bus (ja_sio[3:0]) instead of split
# pin_a2b/pin_b2a groups. Full Vivado XDC syntax throughout (unlike
# fpga/arty/, which targets nextpnr-xilinx's minimal XDC subset).

## Clock (E3, 100 MHz onboard oscillator)
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { clk100mhz }]
create_clock -period 10.000 -name sys_clk_pin [get_ports { clk100mhz }]

## Reset button
set_property -dict { PACKAGE_PIN D9 IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

## Basic LEDs LD4..LD7
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { led4 }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { led5 }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led6 }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led7 }]

## Pmod JA -- real bidirectional QSPI bus to Board A (the hatch SoC).
## JA1=CS_n JA2=SCLK JA3=SIO0 JA4=SIO1 JA7=SIO2 JA8=SIO3 (JA9/JA10 unused).
## No pull-up here on purpose (unlike Board A's ja_sio in hatch's
## fpga/vivado/hatch_arty.xdc): a real 23LC1024/W25Q128JV chip has no
## configurable pad pull, so leaving this side undriven keeps this stand-in
## electrically faithful to what it is standing in for. Board A's pull-up
## alone is enough to give the bus a defined idle level.
set_property -dict { PACKAGE_PIN G13 IOSTANDARD LVCMOS33 } [get_ports { ja_cs_n }]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports { ja_sclk }]
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports { ja_sio[0] }]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports { ja_sio[1] }]
set_property -dict { PACKAGE_PIN D13 IOSTANDARD LVCMOS33 } [get_ports { ja_sio[2] }]
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports { ja_sio[3] }]

## Bitgen config-bank properties (bitgen-only; the open-source flow's
## xc7frames2bit has no equivalent and omits these, see fpga/arty/arty_a7.xdc).
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
