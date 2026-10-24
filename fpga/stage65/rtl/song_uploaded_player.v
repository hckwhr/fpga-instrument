`default_nettype none
// Internal command endpoint, not a UART parser. Both resets must assert
// together and release synchronously in their domains. One command in flight.
// Snapshot write ownership stays in sys until the entire score is copied;
// audio reads only after the request toggle. No RAM reset or read/write overlap.
module song_uploaded_player #(parameter integer SCORE_BITS=9, PROGRESS_BITS=8,
    parameter integer CE_ENABLE=0,
    parameter integer LOCAL_CONTROL=0) (
    input wire clock_enable,
    
    input wire sys_clk, sys_reset_n, audio_clk, audio_reset_n,
    input wire command_valid,
    output wire command_ready,
    input wire [1:0] command, // PLAY=0, STOP=1, STATUS=2
    input wire [1:0] tempo_select,
    output reg response_valid,
    input wire response_ready,
    output reg [2:0] response_code, // OK=0, NO_SCORE=1, BUSY=2, FORMAT=3
    output reg [2:0] response_state,
    output reg [PROGRESS_BITS-1:0] response_note_index,
    output reg [15:0] response_play_crc,
    output reg [SCORE_BITS:0] response_play_length,
    output reg response_stored_valid,
    output reg [15:0] response_stored_crc,
    output wire playback_busy,
    output wire [SCORE_BITS-1:0] score_index,
    input wire [63:0] score_data,
    input wire score_valid,
    input wire [SCORE_BITS:0] score_length,
    input wire [23:0] score_end_tick,
    input wire [15:0] score_crc,
    input wire sample_strobe,
    output wire event_flush, event_valid, event_on, event_melody,
    output wire [15:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    input wire event_ready,
    input wire local_stop, play_blocked,
    output wire active_audio,
    output wire [2:0] state_audio,
    output wire [PROGRESS_BITS-1:0] note_index_audio,
    input wire [PROGRESS_BITS-1:0] score_melody_count,
    output wire [PROGRESS_BITS-1:0] melody_count_audio,
    output wire [1:0] tempo_audio
);
    localparam [2:0] IDLE=0, COPY_WAIT=1, COPY_WRITE=2, WAIT_ACK=3, REPLY=4;
    localparam [2:0] STOPPED=0, STARTING=1, PLAYING=2, FINISHED=3, FAULT=4;
    reg [2:0] state;
    reg owned;
    reg [SCORE_BITS-1:0] copy_index;
    reg [63:0] snapshot [0:(1 << SCORE_BITS)-1];
    reg [SCORE_BITS:0] held_length;
    reg [23:0] held_end_tick;
    reg [15:0] held_crc;
    reg [1:0] held_tempo, held_command;
    reg request_toggle;
    reg [1:0] ack_sync, complete_sync;
    reg complete_seen;
    reg [2:0] pending_code;
    reg acknowledge_toggle, complete_toggle;
    reg [1:0] request_sync, action_state;
    reg run_audio;
    reg [2:0] play_state;
    reg [SCORE_BITS:0] play_length;
    reg [23:0] play_end_tick;
    reg [15:0] play_crc;
    reg [1:0] play_tempo;
    reg [PROGRESS_BITS-1:0] play_note_index;
    // Audio reply bundle is stable from ACK until the next request is handled.
    reg [3+PROGRESS_BITS+16+SCORE_BITS:0] reply_bundle;
    reg rejected_audio;
    reg [PROGRESS_BITS-1:0] held_melody_count, play_melody_count;
    wire cancel_play=LOCAL_CONTROL!=0 && held_command==2'd0 && (local_stop || play_blocked);
    assign active_audio=run_audio;
    assign state_audio=play_state;
    assign note_index_audio=play_note_index;
    assign melody_count_audio=play_melody_count;
    assign tempo_audio=play_tempo;
    wire [SCORE_BITS-1:0] read_index;
    reg [63:0] read_data;
    wire timeline_done, timeline_fault;
    wire [PROGRESS_BITS-1:0] timeline_note_index;
    wire accept = command_valid && command_ready;
    assign command_ready = sys_reset_n && state==IDLE && !response_valid;
    // Cover the accepting edge as well as registered ownership. The store
    // checks this signal on its COMMIT publication edge in the SAME domain.
    assign playback_busy = owned || (accept && command==2'd0);
    assign score_index = copy_index;

    always @(posedge sys_clk) begin
        if(sys_reset_n && state==COPY_WRITE) snapshot[copy_index]<=score_data;
    end
    always @(posedge audio_clk) if ((!CE_ENABLE || clock_enable)) begin
        if(run_audio) read_data<=snapshot[read_index];
    end

    always @(posedge sys_clk or negedge sys_reset_n) begin
        if(!sys_reset_n) begin
            state<=IDLE; owned<=0; copy_index<=0; held_length<=0;
            held_end_tick<=0; held_crc<=0; held_tempo<=0; held_command<=0;
            request_toggle<=0; ack_sync<=0; complete_sync<=0; complete_seen<=0;
            pending_code<=0; response_valid<=0; response_code<=0; response_state<=STOPPED;held_melody_count<=0;
            response_note_index<=0; response_play_crc<=0; response_play_length<=0;
            response_stored_valid<=0; response_stored_crc<=0;
        end else begin
            ack_sync<={ack_sync[0],acknowledge_toggle};
            complete_sync<={complete_sync[0],complete_toggle};
            if(complete_sync[1]!=complete_seen) begin
                complete_seen<=complete_sync[1]; owned<=0;
            end
            if(response_valid && response_ready) response_valid<=0;
            case(state)
                IDLE: if(accept) begin
                    pending_code<=0;
                    held_command<=command;
                    if(command==2'd0 && !owned && score_valid && score_length!=0 && score_length<=(1 << SCORE_BITS)) begin
                        owned<=1; held_length<=score_length; held_end_tick<=score_end_tick;
                        held_melody_count<=LOCAL_CONTROL!=0 ? score_melody_count : 8'd0;
                        held_crc<=score_crc; held_tempo<=tempo_select; copy_index<=0; state<=COPY_WAIT;
                    end else begin
                        // Rejected requests still obtain an actual audio status
                        // snapshot; they must not alter an existing performance.
                        if(command==2'd0) begin
                            pending_code<=owned ? 3'd2 : 3'd1; held_command<=2'd2;
                        end else if(command==2'd3) begin pending_code<=3'd3; held_command<=2'd2; end
                        request_toggle<=!request_toggle; state<=WAIT_ACK;
                    end
                end
                COPY_WAIT: state<=COPY_WRITE;
                COPY_WRITE: if({1'b0,copy_index}+1'b1==held_length) begin
                    request_toggle<=!request_toggle; state<=WAIT_ACK;
                end else begin copy_index<=copy_index+1'b1; state<=COPY_WAIT; end
                WAIT_ACK: if(ack_sync[1]==request_toggle) begin
                    response_code<=rejected_audio ? 3'd2 : pending_code;
                    {response_state,response_note_index,response_play_crc,response_play_length}<=reply_bundle;
                    response_stored_valid<=score_valid; response_stored_crc<=score_crc;
                    response_valid<=1; state<=REPLY;
                    if(held_command==2'd1 || rejected_audio) owned<=0;
                end
                REPLY: if(response_valid && response_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end

    // Held descriptor + toggle CDC. Metadata is written before publication,
    // remains stable until ACK, and is captured after two synchronizer stages.
    // Snapshot RAM remains immutable until audio has stopped and ownership is
    // returned through ACK or the synchronized completion toggle.
    always @(posedge audio_clk or negedge audio_reset_n) begin
        if(!audio_reset_n) begin
            request_sync<=0; action_state<=0; acknowledge_toggle<=0; complete_toggle<=0;
            run_audio<=0; play_state<=STOPPED; play_length<=0; play_end_tick<=0;
            play_crc<=0; play_tempo<=0; play_note_index<=0; reply_bundle<=0;rejected_audio<=0;play_melody_count<=0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            request_sync<={request_sync[0],request_toggle};
            if(run_audio) play_note_index<=timeline_note_index;
            if(run_audio && action_state==0 && timeline_done) begin
                run_audio<=0; play_state<=timeline_fault ? FAULT : FINISHED;
                complete_toggle<=!complete_toggle;
            end else if(run_audio && event_valid && event_ready) play_state<=PLAYING;
            case(action_state)
                0: if(request_sync[1]!=acknowledge_toggle) begin
                    rejected_audio<=0;
                    if(held_command==2'd0 && LOCAL_CONTROL!=0 && (play_blocked || local_stop))begin
                        rejected_audio<=1;
                    end else if(held_command==2'd0) begin
                        play_length<=held_length; play_end_tick<=held_end_tick;
                        play_crc<=held_crc; play_tempo<=held_tempo;
                        play_melody_count<=held_melody_count;
                        play_note_index<=0; play_state<=STARTING; run_audio<=1;
                    end else if(held_command==2'd1) begin run_audio<=0; play_state<=STOPPED; end
                    action_state<=1;
                end
                1: action_state<=2; // allow timeline to observe enable/disable
                2: begin
                    reply_bundle<={(LOCAL_CONTROL!=0 && local_stop) || cancel_play ? STOPPED : play_state,
                                   play_note_index,play_crc,play_length};
                    acknowledge_toggle<=request_sync[1]; action_state<=0;
                end
                default: action_state<=0;
            endcase
            // Local audio-domain controls win even when a PLAY descriptor
            // arrives on this edge. Completion returns RAM ownership to sys.
            if(LOCAL_CONTROL!=0 && (local_stop || (action_state!=0 && cancel_play)))begin
                if(run_audio)complete_toggle<=!complete_toggle;
                run_audio<=0;play_state<=STOPPED;
                if(action_state!=0 && held_command==2'd0)rejected_audio<=1;
            end
        end
    end

    song_timeline #(.SCORE_BITS(SCORE_BITS),.PROGRESS_BITS(PROGRESS_BITS),.CE_ENABLE(CE_ENABLE)) timeline (.clock_enable(clock_enable),
        .clk(audio_clk),.reset_n(audio_reset_n),.sample_strobe(sample_strobe),.enable(run_audio),
        .stop_pressed(1'b0),.replay_pressed(1'b0),.remote_start(1'b0),.remote_stop(1'b0),
        .tempo_select(play_tempo),.score_index(read_index),.score_data(read_data),
        .score_length(play_length),.score_end_tick(play_end_tick),.note_index(timeline_note_index),
        .done(timeline_done),.deadline_fault(timeline_fault),.event_flush(event_flush),
        .event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),.event_id(event_id),
        .event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready)
    );
endmodule
`default_nettype wire
