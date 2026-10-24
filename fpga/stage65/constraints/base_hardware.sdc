create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
create_generated_clock -name audio_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 59 -multiply_by 58 [get_pins {u_instrument/u_audio_pll/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 3 -multiply_by 2 [get_pins {u_instrument/u_lcd_pll/u_pll/PLL_inst/CLKOUT0}]

# The two PLL outputs have no guaranteed phase relationship. All crossings use
# single-bit synchronizers or the stable-data request/acknowledge protocol.
set_clock_groups -asynchronous -group [get_clocks {audio_clk}] -group [get_clocks {pixel_clk}]

# The four buttons are asynchronous and enter two-stage audio-domain
# synchronizers before their levels are used.
set_false_path -from [get_ports {key0_n key1_n key2_n setting_key}]

# ADC protocol is cycle-counted; external board timing is not certified by STA.
set_false_path -from [get_ports {adc_miso}]
set_false_path -to [get_ports {adc_sclk adc_mosi adc_cs0_n adc_cs1_n adc_led[*]}]
set_false_path -from [get_ports {hc05_rx}]
# Asynchronous UART, WS2812 and scope marker have no external capture clock.
set_false_path -to [get_ports {hc05_tx ws2812_data pluck_debug}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {audio_clk}]

# Reset assertion is asynchronous; deassertion passes through two clocked stages.
set_false_path -through [get_pins {u_instrument/sys_reset_sync_n_0_s0/CLEAR u_instrument/sys_reset_sync_n_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/audio_reset_sync_n_0_s0/CLEAR u_instrument/audio_reset_sync_n_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/pixel_reset_sync_n_0_s0/CLEAR u_instrument/pixel_reset_sync_n_1_s0/CLEAR}]
# V3 handshake reset: asynchronous assert, separately synchronized release.
set_false_path -through [get_pins {u_instrument/v3_analog.u_inputs/src_reset_0_s0/CLEAR u_instrument/v3_analog.u_inputs/src_reset_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/v3_analog.u_inputs/dst_reset_0_s0/CLEAR u_instrument/v3_analog.u_inputs/dst_reset_1_s0/CLEAR}]
