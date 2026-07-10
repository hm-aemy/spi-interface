# Copyright 2026 University of Applied Sciences Munich
# Christopher Hinz <christopher.hinz@hm.edu>
#
# Arty A7 (35T/100T) constraints for the Phase-3 23LC1024 bring-up. Pin
# names/locations follow Digilent's official "Arty-A7-35-Master.xdc" /
# "Arty-A7-100-Master.xdc" (both boards share the same package pins for
# clock, buttons and the basic LEDs; only the chip itself and hence the
# usable Pmod-JA bank differ, which does not matter here).
#
# ONE shared file for BOTH designs: top_model.sv (Board A) and
# top_master.sv (Board B) were deliberately given IDENTICAL port names for
# the shared physical signals (clk100mhz, btn0, ja_cs_n, ja_sclk, ja_sio,
# led4..led7) even though the direction of ja_cs_n/ja_sclk differs between
# the two designs (input on Board A, output on Board B). A location/
# IOSTANDARD constraint does not care about port direction, so the very
# same file below applies unmodified to whichever top module nextpnr-xilinx
# is currently building -- see fpga/arty/Makefile. This is the "eine
# gemeinsame Datei" option from the Phase-3 task; it was chosen over two
# near-duplicate files specifically BECAUSE the port names line up, which
# keeps the pin table in exactly one place instead of two files that could
# silently drift apart.
#
# top_master.sv has two ports with no counterpart in top_model.sv (btn1,
# led_progress) -- their constraints below simply have no effect when
# building top_model (nextpnr-xilinx ignores constraints for ports that do
# not exist in the current top-level design; it does not error out).
#
# NOTE on syntax: nextpnr-xilinx's XDC parser is a minimal subset and does
# NOT understand Vivado's `set_property -dict { ... }` form (it aborts with
# an assertion in xdc.cc) -- every property below is therefore written as a
# plain one-property-per-line `set_property`.
#
# -----------------------------------------------------------------------
# Deliberately OMITTED: CFGBVS / CONFIG_VOLTAGE
# -----------------------------------------------------------------------
# Vivado designs usually set
#   set_property CFGBVS VCCO [current_design]
#   set_property CONFIG_VOLTAGE 3.3 [current_design]
# in the top-level XDC. Those two properties only affect Vivado's `bitgen`
# step (they tell it which bank voltage to assume for the configuration
# pins). This flow does NOT use bitgen -- the bitstream is produced by
# prjxray's fasm2frames + xc7frames2bit from nextpnr-xilinx's FASM output,
# which has no equivalent "current-design bitgen option" concept at all.
# nextpnr-xilinx's constraint reader is a small, Yosys/nextpnr-specific
# subset of XDC focused on `get_ports`-scoped PACKAGE_PIN/IOSTANDARD (and
# `create_clock`); a `[current_design]`-scoped property is outside what it
# looks for. Rather than guess whether it is silently ignored or triggers a
# parse warning/error, we simply leave it out -- it would not do anything
# useful in this flow either way. See docs/fpga_flow.md.
# -----------------------------------------------------------------------

## Clock (E3, 100 MHz onboard oscillator)
set_property PACKAGE_PIN E3 [get_ports {clk100mhz}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk100mhz}]
create_clock -period 10.000 -name sys_clk_pin [get_ports {clk100mhz}]

## Buttons (active-high when pressed)
set_property PACKAGE_PIN D9 [get_ports {btn0}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn0}]
set_property PACKAGE_PIN C9 [get_ports {btn1}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn1}]

## Basic LEDs (single colour). Board silkscreen calls these LD0..LD3; this
## project uses them as LD4..LD7 in the port/LED naming (see top_model.sv /
## top_master.sv headers) -- only the pin LOCATION below matters for the
## toolchain, the "LD4..LD7" label is purely our own documentation choice.
set_property PACKAGE_PIN H5 [get_ports {led4}]
set_property IOSTANDARD LVCMOS33 [get_ports {led4}]
set_property PACKAGE_PIN J5 [get_ports {led5}]
set_property IOSTANDARD LVCMOS33 [get_ports {led5}]
set_property PACKAGE_PIN T9 [get_ports {led6}]
set_property IOSTANDARD LVCMOS33 [get_ports {led6}]
set_property PACKAGE_PIN T10 [get_ports {led7}]
set_property IOSTANDARD LVCMOS33 [get_ports {led7}]

## RGB LEDs (top_master.sv only): one channel (red) of each of the four RGB
## LEDs, used as a 4-bit progress display (LD0..LD3 per the task naming).
## UNVERIFIED against real hardware -- double-check these four locations
## against Digilent's Arty-A7-35-Master.xdc before flashing; if wrong, only
## the progress display is affected (PASS/FAIL/heartbeat use the plain LEDs
## above and are independent of this block).
set_property PACKAGE_PIN G6 [get_ports {led_progress[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_progress[0]}]
set_property PACKAGE_PIN G3 [get_ports {led_progress[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_progress[1]}]
set_property PACKAGE_PIN J3 [get_ports {led_progress[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_progress[2]}]
set_property PACKAGE_PIN K1 [get_ports {led_progress[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_progress[3]}]

## Pmod JA -- the inter-board cable. Belegung (siehe
## docs/fpga_flow.md for the wiring table):
##   JA1 = CS_n   JA2 = SCLK   JA3 = SIO0   JA4 = SIO1
##   JA7 = SIO2   JA8 = SIO3   JA9/JA10 unused
## GND-GND between both boards is mandatory (see docs/14); VCC pins of JA
## are NOT used/connected on purpose -- both boards are powered separately
## over their own USB cable.
set_property PACKAGE_PIN G13 [get_ports {ja_cs_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_cs_n}]
set_property PACKAGE_PIN B11 [get_ports {ja_sclk}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_sclk}]
set_property PACKAGE_PIN A11 [get_ports {ja_sio[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_sio[0]}]
set_property PACKAGE_PIN D12 [get_ports {ja_sio[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_sio[1]}]
set_property PACKAGE_PIN D13 [get_ports {ja_sio[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_sio[2]}]
set_property PACKAGE_PIN B18 [get_ports {ja_sio[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ja_sio[3]}]

## Weak pull-ups on Board A's CS_n/SCLK inputs: if Board B is unplugged or
## not yet powered, these pins would otherwise float. A pull-up keeps CS_n
## deasserted (idle, chip not selected) in that case, which is the safe
## default. On Board B's build these same two ports are OUTPUTS -- a pull-up
## on an actively-driven output pin is a well-defined no-op on 7-series I/O,
## so sharing this file between both designs is harmless. See task note:
## "PULLUP nur falls sinnvoll" -- this is the one place it is.
set_property PULLUP true [get_ports {ja_cs_n}]
set_property PULLUP true [get_ports {ja_sclk}]

## SIO lines: no pull needed. During any live transaction exactly one side
## (model or master) drives each line; the model's own drive/oe discipline
## (see docs/07_verhaltensmodelle.md) guarantees no floating-bus window that
## would matter for a 1 MHz bring-up test.

## Bitstream compression (purely a bitgen convenience in Vivado flows; kept
## here as documentation only -- prjxray's xc7frames2bit does not read this
## property, see the CFGBVS note above for why bitgen-only properties are
## otherwise omitted).
#set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## USB-UART bridge (FT2232 channel B), only used by top_loopback.sv:
## uart_rxd_out = FPGA -> host TX pin (Digilent master XDC name/location).
set_property PACKAGE_PIN D10 [get_ports {uart_rxd_out}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rxd_out}]

## Unidirectional two-board wiring (no tri-state; IOBUF is non-functional in
## the nextpnr flow -- see docs/known_issues.md). Cables 1:1:
## JA3..JA8 = A->B lanes, JA9/JA10/JB1/JB2 = B->A lanes.
set_property PACKAGE_PIN A11 [get_ports {pin_a2b[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_a2b[0]}]
set_property PACKAGE_PIN D12 [get_ports {pin_a2b[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_a2b[1]}]
set_property PACKAGE_PIN D13 [get_ports {pin_a2b[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_a2b[2]}]
set_property PACKAGE_PIN B18 [get_ports {pin_a2b[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_a2b[3]}]
set_property PACKAGE_PIN A18 [get_ports {pin_b2a[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_b2a[0]}]
set_property PACKAGE_PIN K16 [get_ports {pin_b2a[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_b2a[1]}]
set_property PACKAGE_PIN E15 [get_ports {pin_b2a[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_b2a[2]}]
set_property PACKAGE_PIN E16 [get_ports {pin_b2a[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pin_b2a[3]}]
