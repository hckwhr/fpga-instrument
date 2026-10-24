`default_nettype none
// SONG2 byte-stream endpoint + real store. No board pins, audio CDC or legacy
// short-command mux here. One live session and one exact-request replay cache.
// Successful COMMIT retains the cache for >=30 seconds (50 MHz default),
// rejecting new-session CAPS with BUSY during that window. Explicit reset
// clears all sessions. The S3 bridge must flush old bytes on reconnection.
module song_upload_link #(
    parameter integer CONTROL_ENABLE=0,
    parameter integer FRAME_TIMEOUT_CYCLES=100_000_000,
    parameter integer STORE_TIMEOUT_CYCLES=1_500_000_000,
    parameter integer REPLAY_HOLD_CYCLES=1_500_000_000,
    parameter integer BACKEND_TIMEOUT_CYCLES=100_000
) (
    input wire clk, reset_n,
    input wire [7:0] rx_data,
    input wire rx_valid, rx_error,
    output wire rx_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready, playback_busy,
    input wire [8:0] score_index,
    output wire [63:0] score_data,
    output wire score_valid,
    output wire [9:0] score_length,
    output wire [23:0] score_end_tick,
    output wire [7:0] score_melody_count,
    output wire [15:0] score_crc,
    output wire published,
    output wire staging,
    output reg link_fault,
    output wire control_valid,
    input wire control_ready,
    output wire [1:0] control_command, control_tempo,
    input wire control_response_valid,
    output wire control_response_ready,
    input wire [2:0] control_response_code,
    input wire [53:0] control_status
);
    localparam [3:0] IDLE=0, PARSE=1, POLICY=2, COMPARE=3, EXECUTE=4,
        BACKEND=5, CACHE=6, RESPOND=7, TX_WAIT=8, RELEASE=9, CONTROL_SEND=10, CONTROL_WAIT=11,
        COMPARE_WAIT=12, CACHE_WAIT=13;
    localparam [3:0] OK=0, BUSY=1, ABI=2, CAPACITY=3, SESSION=4, SEQUENCE=5,
        CONFLICT=6, OFFSET=7, FORMAT=8, STATE_ERROR=9, CONTENT=10;
    localparam integer RW=REPLAY_HOLD_CYCLES>1?$clog2(REPLAY_HOLD_CYCLES+1):1;
    localparam [RW-1:0] REPLAY_TIME=REPLAY_HOLD_CYCLES;
    localparam integer BW=BACKEND_TIMEOUT_CYCLES>1?$clog2(BACKEND_TIMEOUT_CYCLES):1;
    localparam [BW-1:0] BACKEND_LAST=BACKEND_TIMEOUT_CYCLES-1;
    reg [3:0] state;
    wire frame_valid;
    wire [7:0] frame_length, frame_byte, parse_index;
    reg [7:0] cache_index;
    wire [7:0] frame_index=(state==COMPARE || state==CACHE || state==COMPARE_WAIT || state==CACHE_WAIT) ? cache_index : parse_index;
    wire parse_done, parse_valid;
    wire [63:0] sid;
    wire [15:0] seq, scrc;
    wire [2:0] op;
    wire [23:0] a0,a1,a2,a3;
    wire [511:0] payload;
    reg session_valid, session_expired, cache_valid, mismatch;
    reg [63:0] current_sid;
    reg [15:0] last_seq;
    reg [7:0] last_length;
    (* syn_ramstyle="block_ram" *) reg [7:0] cached_frame[0:254];
    reg [7:0] cached_byte;
    // Both request and replay cache have one-edge synchronous read latency.
    // WAIT follows every cache_index change; COMPARE/CACHE consumes next edge.
    always @(posedge clk) begin
        cached_byte<=cached_frame[cache_index<8'd255 ? cache_index : 8'd0];
        if(reset_n && state==CACHE) cached_frame[cache_index]<=frame_byte;
    end
    reg [9:0] last_count, next_offset, staged_length;
    reg [15:0] last_crc;
    reg [53:0] reply_status, last_status;
    reg [RW-1:0] replay_remaining;
    reg [BW-1:0] backend_age;
    reg [3:0] reply_error;
    reg [9:0] reply_count;
    reg [15:0] reply_crc;
    reg [3:0] word_index;
    wire [3:0] payload_index=a1[3:0]-word_index-4'd1;
    wire [9:0] write_index={1'b0,a0[8:0]}+{6'd0,word_index};
    wire backend_ready, backend_valid, store_expired;
    wire [3:0] backend_code;
    wire [9:0] backend_count;
    wire reply_done;
    wire backend_command_valid=state==EXECUTE;
    wire [1:0] backend_command=op==1?2'd0:op==2?2'd1:op==3?2'd2:2'd3;
    assign control_valid=CONTROL_ENABLE!=0 && state==CONTROL_SEND;
    assign control_command=op==5 ? 2'd0 : op==6 ? 2'd1 : 2'd2;
    assign control_tempo=a2[1:0];
    assign control_response_ready=state==CONTROL_WAIT;

    song_upload_frame_rx #(.TIMEOUT_CYCLES(FRAME_TIMEOUT_CYCLES)) receiver (
        .clk(clk),.reset_n(reset_n),.rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_data),.rx_ready(rx_ready),
        .frame_valid(frame_valid),.frame_ready(state==RELEASE),.frame_length(frame_length),
        .frame_index(frame_index),.frame_byte(frame_byte),.error_valid(),.error_code());
    song_upload_parse parser (
        .clk(clk),.reset_n(reset_n),.start(state==IDLE && frame_valid),
        .frame_length(frame_length),.frame_index(parse_index),.frame_byte(frame_byte),
        .done(parse_done),.valid(parse_valid),.session_id(sid),.sequence_id(seq),.operation(op),
        .arg0(a0),.arg1(a1),.arg2(a2),.arg3(a3),.song_crc(scrc),.payload(payload));
    song_upload_reply #(.CONTROL_ENABLE(CONTROL_ENABLE)) formatter (
        .clk(clk),.reset_n(reset_n),.start(state==RESPOND),.session_id(sid),.sequence_id(seq),.operation(op),
        .error_code(reply_error),.count(reply_count),.song_crc(reply_crc),.control_status(reply_status),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.done(reply_done));
    song_upload_store #(.IDLE_TIMEOUT_CYCLES(STORE_TIMEOUT_CYCLES)) store (
        .clk(clk),.reset_n(reset_n),.command_valid(backend_command_valid),.command_ready(backend_ready),.command(backend_command),
        .request_length(op==1 ? a1[9:0] : a0[9:0]),.request_end_tick(a2),.request_melody_count(a3[7:0]),
        .request_crc(scrc),.request_index(write_index[8:0]),.request_word(payload[payload_index[2:0]*64 +: 64]),
        .response_valid(backend_valid),.response_ready(state==BACKEND),.response_code(backend_code),.response_count(backend_count),
        .playback_busy(playback_busy),.score_index(score_index),.score_data(score_data),.score_valid(score_valid),
        .score_length(score_length),.score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
        .published(published),.staging(staging),.expired(store_expired));

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; cache_index<=0; session_valid<=0; session_expired<=0; cache_valid<=0; mismatch<=0;
            current_sid<=0; last_seq<=0; last_length<=0; last_count<=0; last_crc<=0;
            next_offset<=0; staged_length<=0; replay_remaining<=0; backend_age<=0; word_index<=0;
            reply_error<=0; reply_count<=0; reply_crc<=0; link_fault<=0;
            reply_status<=0; last_status<=0;
        end else begin
            if(replay_remaining!=0) replay_remaining<=replay_remaining-1'b1;
            if(store_expired) session_expired<=1;
            case(state)
                IDLE: if(frame_valid) state<=PARSE;
                PARSE: if(parse_done) begin
                    reply_error<=OK; reply_count<=0; reply_crc<=scrc; word_index<=0;
                    if(!parse_valid) state<=RELEASE; // no response with untrusted identity/fields
                    else state<=POLICY;
                end
                POLICY: begin
                    state<=RESPOND;
                    if(link_fault) reply_error<=STATE_ERROR;
                    else if(session_valid && sid==current_sid && cache_valid && seq==last_seq && (!session_expired || op>=5)) begin
                        mismatch<=frame_length!=last_length; cache_index<=0; state<=COMPARE_WAIT;
                    end else if(op==0) begin
                        if(seq!=0) reply_error<=SEQUENCE;
                        else if(session_valid && sid==current_sid) reply_error<=SESSION;
                        else if(staging || replay_remaining!=0) reply_error<=BUSY;
                        else begin
                            current_sid<=sid; session_valid<=1; session_expired<=0; cache_index<=0; state<=CACHE_WAIT;
                        end
                    end else if(!session_valid || sid!=current_sid) reply_error<=SESSION;
                    else if(session_expired && op!=4 && op<5) reply_error<=SESSION;
                    else if(seq<=last_seq || (op!=4 && seq!=last_seq+16'd1) || last_seq==16'hffff) reply_error<=SEQUENCE;
                    else if(op==1 && a0!=24'd12) reply_error<=ABI;
                    else if(op==1 && (a1==0 || a1>512 || a1[0] || a2==0 || a3==0 || a3>255)) reply_error<=CAPACITY;
                    else if(op==2 && (!staging || session_expired)) reply_error<=STATE_ERROR;
                    else if(op==2 && (a0>511 || a0!={14'd0,next_offset} || a0+a1>{14'd0,staged_length})) reply_error<=OFFSET;
                    else if(op==3 && (a0==0 || a0>512)) reply_error<=CAPACITY;
                    else if(op>=5 && CONTROL_ENABLE==0) reply_error<=FORMAT;
                    else if(op==5 && (a0==0 || a0>512 || a2>3)) reply_error<=FORMAT;
                    else if(op==5 && !score_valid) reply_error<=4'd11;
                    else if(op==5 && (a0!={14'd0,score_length} || scrc!=score_crc)) reply_error<=CONTENT;
                    else if(op>=5) state<=CONTROL_SEND;
                    else begin backend_age<=0; state<=EXECUTE; end
                end
                COMPARE_WAIT: state<=COMPARE;
                CACHE_WAIT: state<=CACHE;
                COMPARE: begin
                    if(frame_byte!=cached_byte) mismatch<=1;
                    if(cache_index+8'd1==frame_length) begin
                        state<=RESPOND;
                        if((session_expired || store_expired) && op<5) reply_error<=SESSION;
                        else if(mismatch || frame_byte!=cached_byte) reply_error<=CONFLICT;
                        else begin reply_error<=OK; reply_count<=last_count; reply_crc<=last_crc; reply_status<=last_status; end
                    end else begin cache_index<=cache_index+1'b1; state<=COMPARE_WAIT; end
                end
                EXECUTE: if(backend_ready) begin state<=BACKEND; backend_age<=0; end
                    else if(backend_age==BACKEND_LAST) begin link_fault<=1; reply_error<=STATE_ERROR; state<=RESPOND; end
                    else backend_age<=backend_age+1'b1;
                BACKEND: if(backend_valid) begin
                    if(backend_code!=0) begin
                        case(backend_code)
                            1: reply_error<=STATE_ERROR;
                            2: reply_error<=CAPACITY;
                            3: reply_error<=OFFSET;
                            5: reply_error<=BUSY;
                            default: reply_error<=CONTENT;
                        endcase
                        state<=RESPOND;
                    end else if(op==2 && word_index+4'd1<a1[3:0]) begin
                        word_index<=word_index+1'b1; backend_age<=0; state<=EXECUTE;
                    end else begin
                        reply_count<=backend_count; cache_index<=0; state<=CACHE_WAIT;
                        if(op==1) begin next_offset<=0; staged_length<=a1[9:0]; end
                        if(op==2) next_offset<=backend_count;
                        if(op==3) replay_remaining<=REPLAY_TIME;
                        if(op==4) begin next_offset<=0; session_expired<=0; end
                    end
                end else if(backend_age==BACKEND_LAST) begin link_fault<=1; reply_error<=STATE_ERROR; state<=RESPOND; end
                else backend_age<=backend_age+1'b1;
                CONTROL_SEND: if(control_ready) state<=CONTROL_WAIT;
                // No execution timeout ACK: a stopped audio clock keeps this
                // transaction in flight. A later reply is still this request;
                // the host must treat exhausted retries as an unknown outcome.
                CONTROL_WAIT: if(control_response_valid) begin
                    reply_status<=control_status;
                    if(control_response_code==0) begin cache_index<=0; state<=CACHE_WAIT; end
                    else begin
                        reply_error<=control_response_code==1 ? 4'd11 : control_response_code==2 ? BUSY : FORMAT;
                        state<=RESPOND;
                    end
                end
                CACHE: begin
                    if(cache_index+8'd1==frame_length) begin
                        cache_valid<=1; last_seq<=seq; last_length<=frame_length;
                        last_count<=reply_count; last_crc<=reply_crc; last_status<=reply_status; state<=RESPOND;
                    end else begin cache_index<=cache_index+1'b1; state<=CACHE_WAIT; end
                end
                RESPOND: state<=TX_WAIT;
                TX_WAIT: if(reply_done) state<=RELEASE;
                RELEASE: state<=IDLE;
                default: begin link_fault<=1; state<=RELEASE; end
            endcase
        end
    end
endmodule
`default_nettype wire
