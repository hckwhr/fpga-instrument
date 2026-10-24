`default_nettype none
// Historical wire interface, with the unchanged legacy command behavior.
module hc05_link #(
    parameter integer CLKS_PER_BIT=5120,
    parameter integer TIMEOUT_CYCLES=98_305_085
) (
    input wire clk, reset_n, rx,
    output wire tx,
    input wire setting_mode, stop_key, song_active, song_done,
    input wire [7:0] song_index, song_length,
    output wire play_request, stop_request
);
    wire [7:0] rx_data, tx_data;
    wire rx_valid, rx_error, tx_valid, tx_ready;
    uart_8n1 #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart (
        .clk(clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    hc05_commands #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) commands (
        .play_blocked(1'b0),
        .clk(clk),.reset_n(reset_n),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),.line_fault(2'd0),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_busy(!tx_ready),
        .setting_mode(setting_mode),.stop_key(stop_key),.song_active(song_active),.song_done(song_done),
        .song_index(song_index),.song_length(song_length),.play_request(play_request),.stop_request(stop_request));
endmodule
`default_nettype wire
