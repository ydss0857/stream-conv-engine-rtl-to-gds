## Clock constraint
create_clock -period 13.468 -name TMDS_clk -waveform {0.000 6.734} [get_ports TMDS_0_clk_p]

## HDMI RX (input) - TMDS_0
set_property -dict { PACKAGE_PIN N18   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_clk_p }]
set_property -dict { PACKAGE_PIN P19   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_clk_n }]
set_property -dict { PACKAGE_PIN V20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_p[0] }]
set_property -dict { PACKAGE_PIN W20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_n[0] }]
set_property -dict { PACKAGE_PIN T20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_p[1] }]
set_property -dict { PACKAGE_PIN U20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_n[1] }]
set_property -dict { PACKAGE_PIN N20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_p[2] }]
set_property -dict { PACKAGE_PIN P20   IOSTANDARD TMDS_33 } [get_ports { TMDS_0_data_n[2] }]

## HDMI RX DDC (I2C)
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { DDC_0_scl_io }]
set_property -dict { PACKAGE_PIN U15   IOSTANDARD LVCMOS33 } [get_ports { DDC_0_sda_io }]

## HDMI TX (output) - TMDS_1
set_property -dict { PACKAGE_PIN L16   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_clk_p }]
set_property -dict { PACKAGE_PIN L17   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_clk_n }]
set_property -dict { PACKAGE_PIN K17   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_p[0] }]
set_property -dict { PACKAGE_PIN K18   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_n[0] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_p[1] }]
set_property -dict { PACKAGE_PIN J19   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_n[1] }]
set_property -dict { PACKAGE_PIN J18   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_p[2] }]
set_property -dict { PACKAGE_PIN H18   IOSTANDARD TMDS_33 } [get_ports { TMDS_1_data_n[2] }]
set_property -dict { PACKAGE_PIN T19   IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_hpd }]
