`default_nettype none
// Production logic endpoint. Legacy status and commands belong to audio_clk;
// wire transport/store run on sys_clk. No package pins are assigned here.
module instrument_production_link #(parameter integer SCORE_BITS=9, PROGRESS_BITS=8,
    parameter integer CE_ENABLE=0,
    parameter integer SCOPE_ENABLE=0,
    
    parameter integer CLKS_PER_BIT=5208,
    parameter integer LINE_TIMEOUT_CYCLES=100_000_000
) (
    input wire clock_enable,
    
    input wire sys_clk, audio_clk, reset_n, rx,
    output wire tx,
    input wire setting_mode, stop_key, song_active, song_done,
    input wire [7:0] song_index, song_length,
    output wire play_request, stop_request,
    input wire sample_strobe,
    input wire scope_sample_strobe,
    input wire signed [15:0] scope_dry_sample, scope_wet_sample,
    output wire playback_busy, published, staging, link_fault, rx_dropped,
    output wire event_flush, event_valid, event_on, event_melody,
    output wire [15:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    input wire event_ready,
    input wire local_stop,play_blocked,upload_selected,
    output wire active_audio,
    output wire [2:0] state_audio,
    output wire [PROGRESS_BITS-1:0] note_index_audio, melody_count_audio,
    output wire [1:0] tempo_audio
);
    reg [1:0] sys_release, audio_release;
    always @(posedge sys_clk or negedge reset_n)
        if(!reset_n) sys_release<=0; else sys_release<={sys_release[0],1'b1};
    always @(posedge audio_clk or negedge reset_n)
        if(!reset_n) audio_release<=0; else audio_release<={audio_release[0],1'b1};
    wire [7:0] rx_data, tx_data, line_data, legacy_tx_data, song_tx_data;
    wire rx_valid, rx_error, tx_valid, tx_ready;
    wire legacy_rx_valid, song_rx_valid, song_rx_ready,legacy_rx_ready,scope_rx_valid;
    wire legacy_tx_valid, song_tx_valid, legacy_tx_ready, song_tx_ready, song_owned;
    wire [1:0] legacy_fault;
    uart_8n1 #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx(rx),.tx(tx),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    uart_line_router #(.TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES),.HANDSHAKE_LEGACY(1),.SCOPE_ENABLE(SCOPE_ENABLE)) router (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
        .line_data(line_data),.legacy_valid(legacy_rx_valid),.song_valid(song_rx_valid),.scope_valid(scope_rx_valid),
        .song_ready(song_rx_ready),.legacy_ready(legacy_rx_ready),.legacy_fault(legacy_fault),.rx_dropped(rx_dropped));
    wire [9:0] legacy_audio_rx;
    wire [7:0] legacy_audio_tx;
    wire legacy_audio_rx_valid,legacy_audio_tx_valid,legacy_audio_tx_ready,receive_ready;
    reg [1:0] pending_fault;
    always @(posedge sys_clk or negedge sys_release[1])begin
        if(!sys_release[1])pending_fault<=0;
        else begin
            if(receive_ready)pending_fault<=0;
            if(legacy_fault!=0)pending_fault<=legacy_fault;
        end
    end
    // Faults and bytes share one ordered channel. A delayed fault must never
    // clear a later line after an audio-clock pause.
    assign legacy_rx_ready=receive_ready && pending_fault==0;
    uart_byte_cdc #(.SRC_CE_ENABLE(0),.DST_CE_ENABLE(CE_ENABLE),.WIDTH(10)) receive_legacy (.src_clock_enable(1'b1),.dst_clock_enable(clock_enable),
        .src_clk(sys_clk),.src_reset_n(sys_release[1]),
        .src_data(pending_fault!=0 ? {pending_fault,8'd0} : {2'd0,line_data}),
        .src_valid(legacy_rx_valid || pending_fault!=0),.src_ready(receive_ready),
        .dst_clk(audio_clk),.dst_reset_n(audio_release[1]),.dst_data(legacy_audio_rx),
        .dst_valid(legacy_audio_rx_valid),.dst_ready(1'b1));
    hc05_commands #(.PROGRESS_BITS(PROGRESS_BITS),.CE_ENABLE(CE_ENABLE),.TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES),.EXTERNAL_PLAY_GUARD(1)) legacy (.clock_enable(clock_enable),
        .clk(audio_clk),.reset_n(audio_release[1]),.rx_data(legacy_audio_rx[7:0]),
        .rx_valid(legacy_audio_rx_valid && legacy_audio_rx[9:8]==0),.rx_error(1'b0),
        .line_fault(legacy_audio_rx_valid ? legacy_audio_rx[9:8] : 2'd0),
        .tx_data(legacy_audio_tx),.tx_valid(legacy_audio_tx_valid),.tx_ready(legacy_audio_tx_ready),
        .tx_busy(!legacy_audio_tx_ready),
        .setting_mode(setting_mode),.stop_key(stop_key),.play_blocked(active_audio),
        .song_active(song_active || upload_selected),.song_done(upload_selected ? !active_audio : song_done),
        .song_index(upload_selected ? note_index_audio : {{(PROGRESS_BITS-8){1'b0}},song_index}),
        .song_length(upload_selected ? melody_count_audio : {{(PROGRESS_BITS-8){1'b0}},song_length}),.play_request(play_request),.stop_request(stop_request));
    uart_byte_cdc #(.SRC_CE_ENABLE(CE_ENABLE),.DST_CE_ENABLE(0)) transmit_legacy (.src_clock_enable(clock_enable),.dst_clock_enable(1'b1),
        .src_clk(audio_clk),.src_reset_n(audio_release[1]),.src_data(legacy_audio_tx),
        .src_valid(legacy_audio_tx_valid),.src_ready(legacy_audio_tx_ready),
        .dst_clk(sys_clk),.dst_reset_n(sys_release[1]),.dst_data(legacy_tx_data),
        .dst_valid(legacy_tx_valid),.dst_ready(legacy_tx_ready));
    wire [7:0] control_tx_data,scope_tx_data;
    wire control_tx_valid,control_tx_ready,scope_tx_valid,scope_tx_ready;
    uart_line_tx_mux replies (
        .clk(sys_clk),.reset_n(sys_release[1]),.legacy_data(legacy_tx_data),.song_data(song_tx_data),
        .legacy_valid(legacy_tx_valid),.song_valid(song_tx_valid),.legacy_ready(legacy_tx_ready),.song_ready(song_tx_ready),
        .tx_data(control_tx_data),.tx_valid(control_tx_valid),.tx_ready(control_tx_ready),.song_owned(song_owned));
    generate if(SCOPE_ENABLE) begin: scope_enabled
        audio_scope_uart scope (
            .sys_clk(sys_clk),.sys_reset_n(sys_release[1]),.audio_clk(audio_clk),.audio_reset_n(audio_release[1]),
            .sample_strobe(scope_sample_strobe),.dry_sample(scope_dry_sample),.wet_sample(scope_wet_sample),
            .rx_data(line_data),.rx_valid(scope_rx_valid),.tx_data(scope_tx_data),
            .tx_valid(scope_tx_valid),.tx_ready(scope_tx_ready));
        // Existing line lock prevents all three protocols from interleaving.
        uart_line_tx_mux scope_replies (
            .clk(sys_clk),.reset_n(sys_release[1]),.legacy_data(control_tx_data),.legacy_valid(control_tx_valid),
            .legacy_ready(control_tx_ready),.song_data(scope_tx_data),.song_valid(scope_tx_valid),
            .song_ready(scope_tx_ready),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.song_owned());
    end else begin: scope_disabled
        assign tx_data=control_tx_data;assign tx_valid=control_tx_valid;assign control_tx_ready=tx_ready;
        assign scope_tx_data=0;assign scope_tx_valid=0;assign scope_tx_ready=0;
    end endgenerate

    wire [SCORE_BITS-1:0] score_index;
    wire [63:0] score_data;
    wire score_valid, control_valid, control_ready, response_valid, response_ready;
    wire [SCORE_BITS:0] score_length, response_length;
    wire [23:0] score_end_tick;
    wire [15:0] score_crc, response_crc, response_stored_crc;
    wire [1:0] control_command, control_tempo;
    wire [2:0] response_code, response_state;
    wire [PROGRESS_BITS-1:0] response_note;
    wire response_stored_valid;
    wire [PROGRESS_BITS-1:0] score_melody_count;
    song_upload_link #(.SCORE_BITS(SCORE_BITS),.PROGRESS_BITS(PROGRESS_BITS),.CONTROL_ENABLE(1),.FRAME_TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) upload (
        .clk(sys_clk),.reset_n(sys_release[1]),.rx_data(line_data),.rx_valid(song_rx_valid),.rx_error(1'b0),.rx_ready(song_rx_ready),
        .tx_data(song_tx_data),.tx_valid(song_tx_valid),.tx_ready(song_tx_ready),.playback_busy(playback_busy),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
        .published(published),.staging(staging),.link_fault(link_fault),
        .control_valid(control_valid),.control_ready(control_ready),.control_command(control_command),.control_tempo(control_tempo),
        .control_response_valid(response_valid),.control_response_ready(response_ready),.control_response_code(response_code),
        .control_status({response_state,response_note,response_length,response_crc,response_stored_valid,response_stored_crc}));
    song_uploaded_player #(.SCORE_BITS(SCORE_BITS),.PROGRESS_BITS(PROGRESS_BITS),.CE_ENABLE(CE_ENABLE),.LOCAL_CONTROL(1)) player (.clock_enable(clock_enable),
        .sys_clk(sys_clk),.sys_reset_n(sys_release[1]),.audio_clk(audio_clk),.audio_reset_n(audio_release[1]),
        .command_valid(control_valid),.command_ready(control_ready),.command(control_command),.tempo_select(control_tempo),
        .response_valid(response_valid),.response_ready(response_ready),.response_code(response_code),
        .response_state(response_state),.response_note_index(response_note),.response_play_crc(response_crc),.response_play_length(response_length),
        .response_stored_valid(response_stored_valid),.response_stored_crc(response_stored_crc),
        .playback_busy(playback_busy),.score_index(score_index),.score_data(score_data),.score_valid(score_valid),
        .score_length(score_length),.score_end_tick(score_end_tick),.score_crc(score_crc),.sample_strobe(sample_strobe),
        .event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),
        .event_id(event_id),.event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready),
        .local_stop(local_stop),.play_blocked(play_blocked),.active_audio(active_audio),
        .state_audio(state_audio),.note_index_audio(note_index_audio),
        .score_melody_count(score_melody_count),.melody_count_audio(melody_count_audio),.tempo_audio(tempo_audio));
endmodule
`default_nettype wire
