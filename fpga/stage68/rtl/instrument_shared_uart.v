`default_nettype none
// Component only: legacy status inputs and request outputs belong to sys_clk.
// Production source selection/pin assignment is deliberately outside this top.
module instrument_shared_uart #(
    parameter integer CLKS_PER_BIT=5208,
    parameter integer LINE_TIMEOUT_CYCLES=100_000_000
) (
    input wire sys_clk, audio_clk, reset_n, rx,
    output wire tx,
    input wire setting_mode, stop_key, song_active, song_done,
    input wire [7:0] song_index, song_length,
    output wire play_request, stop_request,
    input wire sample_strobe,
    output wire playback_busy, published, staging, link_fault, rx_dropped,
    output wire event_flush, event_valid, event_on, event_melody,
    output wire [15:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    input wire event_ready
);
    reg [1:0] sys_release, audio_release;
    always @(posedge sys_clk or negedge reset_n)
        if(!reset_n) sys_release<=0; else sys_release<={sys_release[0],1'b1};
    always @(posedge audio_clk or negedge reset_n)
        if(!reset_n) audio_release<=0; else audio_release<={audio_release[0],1'b1};
    wire [7:0] rx_data, tx_data, line_data, legacy_tx_data, song_tx_data;
    wire rx_valid, rx_error, tx_valid, tx_ready;
    wire legacy_rx_valid, song_rx_valid, song_rx_ready;
    wire legacy_tx_valid, song_tx_valid, legacy_tx_ready, song_tx_ready, song_owned;
    wire [1:0] legacy_fault;
    uart_8n1 #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx(rx),.tx(tx),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    uart_line_router #(.TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) router (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .line_data(line_data),.legacy_valid(legacy_rx_valid),.song_valid(song_rx_valid),
        .song_ready(song_rx_ready),.legacy_ready(1'b1),.legacy_fault(legacy_fault),.rx_dropped(rx_dropped));
    hc05_commands #(.TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) legacy (
        .play_blocked(1'b0),
        .clk(sys_clk),.reset_n(sys_release[1]),.rx_data(line_data),.rx_valid(legacy_rx_valid),.rx_error(1'b0),
        .line_fault(legacy_fault),.tx_data(legacy_tx_data),.tx_valid(legacy_tx_valid),.tx_ready(legacy_tx_ready),
        .tx_busy(!tx_ready || song_tx_valid || song_owned),
        .setting_mode(setting_mode),.stop_key(stop_key),.song_active(song_active),.song_done(song_done),
        .song_index(song_index),.song_length(song_length),.play_request(play_request),.stop_request(stop_request));
    uart_line_tx_mux replies (
        .clk(sys_clk),.reset_n(sys_release[1]),.legacy_data(legacy_tx_data),.song_data(song_tx_data),
        .legacy_valid(legacy_tx_valid),.song_valid(song_tx_valid),.legacy_ready(legacy_tx_ready),.song_ready(song_tx_ready),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.song_owned(song_owned));

    wire [8:0] score_index;
    wire [63:0] score_data;
    wire score_valid, control_valid, control_ready, response_valid, response_ready;
    wire [9:0] score_length, response_length;
    wire [23:0] score_end_tick;
    wire [15:0] score_crc, response_crc, response_stored_crc;
    wire [1:0] control_command, control_tempo;
    wire [2:0] response_code, response_state;
    wire [7:0] response_note;
    wire response_stored_valid;
    song_upload_link #(.CONTROL_ENABLE(1),.FRAME_TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) upload (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx_data(line_data),.rx_valid(song_rx_valid),.rx_error(1'b0),.rx_ready(song_rx_ready),
        .tx_data(song_tx_data),.tx_valid(song_tx_valid),.tx_ready(song_tx_ready),.playback_busy(playback_busy),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_melody_count(),.score_crc(score_crc),
        .published(published),.staging(staging),.link_fault(link_fault),
        .control_valid(control_valid),.control_ready(control_ready),.control_command(control_command),.control_tempo(control_tempo),
        .control_response_valid(response_valid),.control_response_ready(response_ready),.control_response_code(response_code),
        .control_status({response_state,response_note,response_length,response_crc,response_stored_valid,response_stored_crc}));
    song_uploaded_player player (
        .local_stop(1'b0),.play_blocked(1'b0),.score_melody_count(8'd0),
        .active_audio(),.state_audio(),.note_index_audio(),.melody_count_audio(),.tempo_audio(),
        .sys_clk(sys_clk),.sys_reset_n(sys_release[1]),.audio_clk(audio_clk),.audio_reset_n(audio_release[1]),
        .command_valid(control_valid),.command_ready(control_ready),.command(control_command),.tempo_select(control_tempo),
        .response_valid(response_valid),.response_ready(response_ready),.response_code(response_code),
        .response_state(response_state),.response_note_index(response_note),.response_play_crc(response_crc),.response_play_length(response_length),
        .response_stored_valid(response_stored_valid),.response_stored_crc(response_stored_crc),
        .playback_busy(playback_busy),.score_index(score_index),.score_data(score_data),.score_valid(score_valid),
        .score_length(score_length),.score_end_tick(score_end_tick),.score_crc(score_crc),.sample_strobe(sample_strobe),
        .event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),
        .event_id(event_id),.event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready));
endmodule
`default_nettype wire
