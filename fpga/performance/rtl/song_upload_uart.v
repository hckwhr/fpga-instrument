`default_nettype none
// Isolated V3-protocol component, 50 MHz system clock / 5208 = 9600.614 baud.
// This is NOT the V2 board top and does not claim physical pin assignment.
module song_upload_uart #(
    parameter integer CONTROL_ENABLE=0,
    parameter integer CLKS_PER_BIT=5208,
    parameter integer FRAME_TIMEOUT_CYCLES=100_000_000,
    parameter integer STORE_TIMEOUT_CYCLES=1_500_000_000,
    parameter integer REPLAY_HOLD_CYCLES=1_500_000_000
) (
    input wire clk, reset_n, rx,
    output wire tx,
    input wire playback_busy,
    input wire [8:0] score_index,
    output wire [63:0] score_data,
    output wire score_valid,
    output wire [9:0] score_length,
    output wire [23:0] score_end_tick,
    output wire [7:0] score_melody_count,
    output wire [15:0] score_crc,
    output wire published, staging, link_fault,
    output wire control_valid,
    input wire control_ready,
    output wire [1:0] control_command, control_tempo,
    input wire control_response_valid,
    output wire control_response_ready,
    input wire [2:0] control_response_code,
    input wire [53:0] control_status
);
    wire [7:0] rx_data, tx_data;
    wire rx_valid,rx_error,tx_valid,tx_ready;
    uart_8n1 #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart (
        .clk(clk),.reset_n(reset_n),.rx(rx),.tx(tx),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    song_upload_link #(.CONTROL_ENABLE(CONTROL_ENABLE),.FRAME_TIMEOUT_CYCLES(FRAME_TIMEOUT_CYCLES),.STORE_TIMEOUT_CYCLES(STORE_TIMEOUT_CYCLES),.REPLAY_HOLD_CYCLES(REPLAY_HOLD_CYCLES)) link (
        .clk(clk),.reset_n(reset_n),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),.rx_ready(),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.playback_busy(playback_busy),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
        .published(published),.staging(staging),.link_fault(link_fault),
        .control_valid(control_valid),.control_ready(control_ready),.control_command(control_command),.control_tempo(control_tempo),
        .control_response_valid(control_response_valid),.control_response_ready(control_response_ready),
        .control_response_code(control_response_code),.control_status(control_status));
endmodule
`default_nettype wire
