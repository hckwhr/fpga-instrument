`default_nettype none
// Isolated integration component: physical UART + original store + audio
// scheduler. Control ports are internal; no new wire PLAY/STATUS protocol yet.
module song_upload_playback #(
    parameter integer WIRE_CONTROL=0,
    parameter integer CLKS_PER_BIT=5208
) (
    input wire sys_clk, audio_clk, reset_n, rx,
    output wire tx,
    input wire command_valid,
    output wire command_ready,
    input wire [1:0] command, tempo_select,
    output wire response_valid,
    input wire response_ready,
    output wire [2:0] response_code, response_state,
    output wire [7:0] response_note_index,
    output wire [15:0] response_play_crc,
    output wire [9:0] response_play_length,
    output wire response_stored_valid,
    output wire [15:0] response_stored_crc,
    output wire playback_busy, published, staging, link_fault,
    input wire sample_strobe,
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
    wire [8:0] score_index;
    wire [63:0] score_data;
    wire score_valid;
    wire [9:0] score_length;
    wire [23:0] score_end_tick;
    wire [15:0] score_crc;
    wire wire_valid, wire_ready, wire_response_ready, player_ready, player_response_valid;
    wire [1:0] wire_command, wire_tempo;
    assign command_ready=WIRE_CONTROL==0 && player_ready;
    assign response_valid=WIRE_CONTROL==0 && player_response_valid;
    assign wire_ready=WIRE_CONTROL!=0 && player_ready;
    song_upload_uart #(.CONTROL_ENABLE(WIRE_CONTROL),.CLKS_PER_BIT(CLKS_PER_BIT)) upload (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx(rx),.tx(tx),.playback_busy(playback_busy),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_melody_count(),.score_crc(score_crc),
        .published(published),.staging(staging),.link_fault(link_fault),
        .control_valid(wire_valid),.control_ready(wire_ready),.control_command(wire_command),.control_tempo(wire_tempo),
        .control_response_valid(player_response_valid),.control_response_ready(wire_response_ready),
        .control_response_code(response_code),
        .control_status({response_state,response_note_index,response_play_length,response_play_crc,response_stored_valid,response_stored_crc}));
    song_uploaded_player player (
        .local_stop(1'b0),.play_blocked(1'b0),.score_melody_count(8'd0),
        .active_audio(),.state_audio(),.note_index_audio(),.melody_count_audio(),.tempo_audio(),
        .sys_clk(sys_clk),.sys_reset_n(sys_release[1]),.audio_clk(audio_clk),.audio_reset_n(audio_release[1]),
        .command_valid(WIRE_CONTROL!=0 ? wire_valid : command_valid),.command_ready(player_ready),
        .command(WIRE_CONTROL!=0 ? wire_command : command),.tempo_select(WIRE_CONTROL!=0 ? wire_tempo : tempo_select),
        .response_valid(player_response_valid),.response_ready(WIRE_CONTROL!=0 ? wire_response_ready : response_ready),.response_code(response_code),
        .response_state(response_state),.response_note_index(response_note_index),.response_play_crc(response_play_crc),
        .response_play_length(response_play_length),.response_stored_valid(response_stored_valid),.response_stored_crc(response_stored_crc),
        .playback_busy(playback_busy),.score_index(score_index),.score_data(score_data),.score_valid(score_valid),
        .score_length(score_length),.score_end_tick(score_end_tick),.score_crc(score_crc),.sample_strobe(sample_strobe),
        .event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),
        .event_id(event_id),.event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready));
endmodule
`default_nettype wire
