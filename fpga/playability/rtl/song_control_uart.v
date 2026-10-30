`default_nettype none
// Wire-only SONG2 upload/playback endpoint; capability flag enabled only here.
// Internal control ports cannot bypass the numbered request/replay policy.
module song_control_uart #(parameter integer CLKS_PER_BIT=5208) (
    input wire sys_clk, audio_clk, reset_n, rx,
    output wire tx,
    input wire sample_strobe,
    output wire playback_busy, published, staging, link_fault,
    output wire event_flush, event_valid, event_on, event_melody,
    output wire [15:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    input wire event_ready
);
    song_upload_playback #(.WIRE_CONTROL(1),.CLKS_PER_BIT(CLKS_PER_BIT)) endpoint (
        .sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .command_valid(1'b0),.command_ready(),.command(2'd0),.tempo_select(2'd1),
        .response_valid(),.response_ready(1'b0),.response_code(),.response_state(),.response_note_index(),
        .response_play_crc(),.response_play_length(),.response_stored_valid(),.response_stored_crc(),
        .playback_busy(playback_busy),.published(published),.staging(staging),.link_fault(link_fault),
        .sample_strobe(sample_strobe),.event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),
        .event_melody(event_melody),.event_id(event_id),.event_note(event_note),.event_octave(event_octave),
        .event_force(event_force),.event_ready(event_ready));
endmodule
`default_nettype wire
