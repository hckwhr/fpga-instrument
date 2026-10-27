create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
create_generated_clock -name audio_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 59 -multiply_by 58 [get_pins {u_instrument/u_audio_pll/u_pll/PLL_inst/CLKOUT0}]
# Single video PLL: sys_clk *18 = 900 MHz VCO, /5 serializer, /25 pixel.
# The 1080p30 cascade through a reference PLL is gone, so these clocks derive
# from sys_clk directly. Retain all timing between them, including OSER10
# recovery/removal; do not mark them asynchronous.
create_generated_clock -name hdmi_serial_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 5 -multiply_by 18 [get_pins {u_instrument/u_hdmi_clocks/u_video/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 25 -multiply_by 18 [get_pins {u_instrument/u_hdmi_clocks/u_video/u_pll/PLL_inst/CLKOUT1}]
# The dashboard now maps 1:1, so the renderer shares the physical pixel clock
# instead of a separate half-rate output. render_clk is pixel_clk.

# The two PLL outputs have no guaranteed phase relationship. All crossings use
# single-bit synchronizers or the stable-data request/acknowledge protocol.
set_clock_groups -asynchronous -group [get_clocks {audio_clk}] -group [get_clocks {hdmi_serial_clk pixel_clk}]

# The four buttons are asynchronous and enter two-stage audio-domain
# synchronizers before their levels are used.
set_false_path -from [get_ports {key0_n key1_n key2_n setting_key}]

# ADC protocol is cycle-counted; external board timing is not certified by STA.
set_false_path -from [get_ports {adc_miso}]
set_false_path -to [get_ports {adc_sclk adc_mosi adc_cs0_n adc_cs1_n adc_led[*]}]
set_false_path -from [get_ports {hc05_rx}]
# Asynchronous UART, WS2812 and scope marker have no external capture clock.
set_false_path -to [get_ports {hc05_tx ws2812_data pluck_debug}]
set_false_path -to [get_ports {hdmi_tx_enable}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {audio_clk}]

# Reset assertion is asynchronous; deassertion passes through two clocked stages.
set_false_path -through [get_pins {u_instrument/sys_reset_sync_n_0_s0/CLEAR u_instrument/sys_reset_sync_n_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/audio_reset_sync_n_0_s0/CLEAR u_instrument/audio_reset_sync_n_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/pixel_reset_sync_n_0_s0/CLEAR u_instrument/pixel_reset_sync_n_1_s0/CLEAR}]
# Only the asynchronous CLEAR inputs of the release synchronizer are excluded.
# Its Q -> OSER10 RESET paths remain fully checked, as in accepted stage41e.
set_false_path -through [get_pins {u_instrument/serializer_reset_sync_n_0_s0/CLEAR u_instrument/serializer_reset_sync_n_1_s0/CLEAR}]
# Startup controller is released from the existing falling-PCLK synchronizer.
# No exception on its state or on OSER10 RESET -> PCLK recovery/removal.
# The DHCE clock gate is gone: FCLK free runs, so there is no CEN to except.
# RTL holds RESET asserted for 16 PCLK cycles (444.4 ns at 36 MHz) and releases
# it on a falling PCLK edge; no data is shifted until after that window, which
# is checked independently under reset/relock and a reset-phase sweep.
# Bound RESET settling to only 4 FCLK periods (22.2 ns), not a false path.
# Hold uses END because capture is 5x faster than the launch PCLK.
# Both constraints are restricted to these RESET pins AND FCLK captures;
# PCLK recovery/removal and data stay single-cycle.
set_multicycle_path -from [get_regs {u_instrument/u_hdmi_tx/serializer_release_n*}] -through [get_pins {u_instrument/u_hdmi_tx/lanes*.u_serializer/RESET}] -to [get_clocks {hdmi_serial_clk}] -setup -end 4
set_multicycle_path -from [get_regs {u_instrument/u_hdmi_tx/serializer_release_n*}] -through [get_pins {u_instrument/u_hdmi_tx/lanes*.u_serializer/RESET}] -to [get_clocks {hdmi_serial_clk}] -hold -end 3
# V3 handshake reset: asynchronous assert, separately synchronized release.
set_false_path -through [get_pins {u_instrument/v3_analog.u_inputs/src_reset_0_s0/CLEAR u_instrument/v3_analog.u_inputs/src_reset_1_s0/CLEAR}]
set_false_path -through [get_pins {u_instrument/v3_analog.u_inputs/dst_reset_0_s0/CLEAR u_instrument/v3_analog.u_inputs/dst_reset_1_s0/CLEAR}]
