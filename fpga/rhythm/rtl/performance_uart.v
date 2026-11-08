`default_nettype none
// PERF1 commands and bounded audio streaming. sys clock owns the wire protocol.
// Map payload is held from request toggle through audio acknowledgement; all
// audio-side state commits on common engine CE. Busy keys reject the whole map.
module performance_uart #(parameter integer CE_ENABLE=0,
    parameter integer RHYTHM_ENABLE=0, RHYTHM_LEASE_STEPS=75000000,
    parameter integer LEASE_CYCLES=150_000_000, MAX_BLOCKS=3000)(
    input wire sys_clk, sys_reset_n, audio_clk, audio_reset_n, clock_enable,
    input wire sample_strobe,
    input wire signed [15:0] sample,
    input wire keyboard_busy,
    input wire rhythm_blocked,
    input wire [11:0] physical_keys,
    output wire rhythm_guard,
    output wire rhythm_takeover,
    output wire [11:0] rhythm_play_keys, rhythm_guide_keys,
    output reg custom_enabled,
    output reg [71:0] custom_map,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready
);
    function [15:0] crc_byte;
        input [15:0] crc;input [7:0] value;reg [15:0] c;integer k;
        begin c=crc^{value,8'd0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
    endfunction
    function [7:0] hex_char;
        input [3:0] n;begin hex_char=n<10?8'd48+{4'd0,n}:8'd55+{4'd0,n};end
    endfunction
    function [3:0] unhex;
        input [7:0] c;begin unhex=c<=57?c[3:0]:c[3:0]+4'd9;end
    endfunction
    function [7:0] base64_char;
        input [5:0] n;begin
            if(n<26)base64_char=8'd65+{2'd0,n};
            else if(n<52)base64_char=8'd97+{2'd0,n}-8'd26;
            else if(n<62)base64_char=8'd48+{2'd0,n}-8'd52;
            else base64_char=n==62?8'd43:8'd47;
        end
    endfunction
    reg map_request,map_ack;
    reg [1:0] map_req_sync,map_ack_sync;
    reg [71:0] map_payload, result_map;
    reg [2:0] map_operation;
    reg [1:0] map_result;
    reg rhythm_wait, rhythm_prepared;
    // A start transaction first returns the instrument to live mode. The next
    // common-CE edge checks the resulting blockers; ACK still follows commit.
    assign rhythm_takeover=RHYTHM_ENABLE && map_req_sync[1]!=map_ack &&
        map_operation==6 && map_payload[44] && map_payload[71:45]==27'd0 && !rhythm_wait && !keyboard_busy;
    wire [71:0] rhythm_status;
    wire [1:0] rhythm_result;
    wire rhythm_active;
    generate if(RHYTHM_ENABLE) begin: rhythm_enabled
        rhythm_key_gate #(.CE_ENABLE(CE_ENABLE),.LEASE_STEPS(RHYTHM_LEASE_STEPS)) gate(
            .clk(audio_clk),.reset_n(audio_reset_n),.clock_enable(clock_enable),
            .command_valid(map_req_sync[1]!=map_ack && !rhythm_wait && map_operation>=6 &&
                (map_operation!=6 || !map_payload[44] || rhythm_prepared)),
            .command_set(map_operation==6),.command_payload(map_payload),
            .blocked(rhythm_blocked),.keyboard_busy(keyboard_busy),.physical_keys(physical_keys),
            .guard(rhythm_guard),.active(rhythm_active),.play_keys(rhythm_play_keys),
            .guide_keys(rhythm_guide_keys),.status(rhythm_status),.result(rhythm_result));
    end else begin: no_rhythm
        assign rhythm_guard=0;assign rhythm_active=0;assign rhythm_play_keys=physical_keys;
        assign rhythm_guide_keys=0;assign rhythm_status=0;assign rhythm_result=3;
    end endgenerate
    integer i;
    always @(posedge audio_clk or negedge audio_reset_n)begin
        if(!audio_reset_n)begin
            map_req_sync<=0;map_ack<=0;custom_enabled<=0;map_result<=0;
            custom_map<=0;result_map<=0;rhythm_wait<=0;rhythm_prepared<=0;
            for(i=0;i<12;i=i+1)begin custom_map[i*6+:6]<=6'd16+i;result_map[i*6+:6]<=6'd16+i;end
        end else if(!CE_ENABLE || clock_enable)begin
            map_req_sync<={map_req_sync[0],map_request};
            if(map_req_sync[1]!=map_ack)begin
                if(map_operation>=6) begin
                    if(map_operation==6 && map_payload[44] && !rhythm_prepared) rhythm_prepared<=1;
                    // The gate commits on the first CE edge; snapshot its
                    // post-command result on the next before returning ACK.
                    else if(!rhythm_wait) rhythm_wait<=1;
                    else begin
                        rhythm_wait<=0;rhythm_prepared<=0;map_ack<=map_req_sync[1];
                        result_map<=rhythm_status;map_result<=rhythm_result;
                    end
                end else begin
                map_ack<=map_req_sync[1];result_map<=custom_map;
                map_result<=custom_enabled?2'd1:2'd0;
                if(map_operation!=0)begin
                    if(keyboard_busy || rhythm_guard)map_result<=2'd2;
                    else if(map_operation==1)begin custom_map<=map_payload;result_map<=map_payload;custom_enabled<=1;map_result<=1;end
                    else begin custom_enabled<=0;map_result<=0;end
                end
                end
            end
        end
    end
    reg [5:0] rx_count;
    reg [47:0] prefix;
    reg [31:0] rx_id, record_id, ack_id, map_id;
    reg [2:0] operation;
    reg [71:0] rx_map;
    reg [15:0] rx_crc,supplied_crc;
    reg malformed;
    wire hex_ok=(rx_data>=48 && rx_data<=57)||(rx_data>=65 && rx_data<=70);
    reg map_valid;
    integer m;
    always @*begin
        map_valid=1;
        for(m=0;m<12;m=m+1)if(rx_map[m*6+4+:2]>2 || rx_map[m*6+:4]>11)map_valid=0;
    end
    reg map_wait, ack_pending,record_session, end_sent;
    reg [2:0] ack_operation;
    reg [1:0] ack_status;
    reg [71:0] ack_map, keymap_reply;
    // Ownership is acknowledged through the existing stable-bus handshake,
    // not sampled asynchronously from the audio domain.
    reg rhythm_owned;
    reg record_start,record_stop;
    reg [2:0] stop_reason;
    wire record_active, block_valid;
    wire [2:0] record_reason;
    wire [15:0] record_count, block_predictor;
    wire [6:0] block_index;
    wire [5:0] read_code;
    reg block_release;
    reg [7:0] read_address;
    localparam integer LW=LEASE_CYCLES>1?$clog2(LEASE_CYCLES+1):1;
    reg [LW-1:0] lease;
    reg [1:0] recording_audio;
    always @(posedge audio_clk or negedge audio_reset_n)
        if(!audio_reset_n)recording_audio<=0;
        else recording_audio<={recording_audio[0],record_active};
    wire pcm_ready,pcm_valid;
    wire [15:0] pcm_data;
    reg pcm_overrun;
    reg [1:0] overrun_sync;
    always @(posedge audio_clk or negedge audio_reset_n)begin
        if(!audio_reset_n)pcm_overrun<=0;
        else if(!recording_audio[1])pcm_overrun<=0;
        else if(sample_strobe && !pcm_ready)pcm_overrun<=1;
    end
    uart_byte_cdc #(.WIDTH(16)) pcm_cdc(
        .src_clock_enable(1'b1),.dst_clock_enable(1'b1),
        .src_clk(audio_clk),.src_reset_n(audio_reset_n),.src_data(sample),
        .src_valid(sample_strobe && recording_audio[1]),.src_ready(pcm_ready),
        .dst_clk(sys_clk),.dst_reset_n(sys_reset_n),.dst_data(pcm_data),.dst_valid(pcm_valid),.dst_ready(1'b1));
    performance_recorder #(.MAX_BLOCKS(MAX_BLOCKS)) recorder(
        .clk(sys_clk),.reset_n(sys_reset_n),.start(record_start),.stop(record_stop),.stop_reason(stop_reason),
        .pcm_valid(pcm_valid),.pcm(pcm_data),.active(record_active),.reason(record_reason),.count(record_count),
        .block_valid(block_valid),.block_release(block_release),.read_address(read_address),.read_code(read_code),
        .block_predictor(block_predictor),.block_index(block_index));

    localparam [1:0] TX_IDLE=0,TX_FETCH=1,TX_SEND=2;
    localparam [1:0] ACK=0,DATA=1,ENDING=2;
    reg [1:0] tx_state,kind;
    reg [7:0] position;
    reg [31:0] tx_id;
    reg [15:0] next_sequence,tx_sequence,tx_predictor,tx_crc;
    reg [6:0] tx_index;
    reg [2:0] tx_operation,tx_status;
    reg [71:0] tx_map;
    reg [7:0] byte_value;
    wire [7:0] comma_position=kind==ACK?8'd39:kind==DATA?8'd190:8'd23;
    wire [7:0] last_position=comma_position+8'd5;
    always @*begin
        byte_value=8'd44;
        if(position==0)byte_value="P";
        else if(position==1)byte_value="E";
        else if(position==2)byte_value="R";
        else if(position==3)byte_value="F";
        else if(position==4)byte_value="1";
        else if(position>=6 && position<=13)byte_value=hex_char(tx_id[(13-position)*4+:4]);
        else if(position==15)byte_value=kind==ACK?"A":kind==DATA?"D":"E";
        else if(position==last_position)byte_value=8'd10;
        else if(position>comma_position)byte_value=hex_char(tx_crc[(comma_position+4-position)*4+:4]);
        else if(kind==ACK)begin
            if(position==17)byte_value=8'd48+{5'd0,tx_operation};
            else if(position==19)byte_value=8'd48+{5'd0,tx_status};
            else if(position>=21 && position<=38)byte_value=hex_char(tx_map[(38-position)*4+:4]);
        end else begin
            if(position>=17 && position<=20)byte_value=hex_char(tx_sequence[(20-position)*4+:4]);
            else if(kind==ENDING && position==22)byte_value=8'd48+{5'd0,tx_status};
            else if(kind==DATA)begin
                if(position>=22 && position<=25)byte_value=hex_char(tx_predictor[(25-position)*4+:4]);
                else if(position==27)byte_value=hex_char({1'b0,tx_index[6:4]});
                else if(position==28)byte_value=hex_char(tx_index[3:0]);
                else if(position>=30 && position<=189)byte_value=base64_char(read_code);
            end
        end
    end
    assign tx_valid=tx_state==TX_SEND;
    assign tx_data=byte_value;
    always @(posedge sys_clk or negedge sys_reset_n)begin
        if(!sys_reset_n)begin
            rx_count<=0;prefix<=0;rx_id<=0;rx_map<=0;operation<=0;rx_crc<=16'hffff;supplied_crc<=0;malformed<=0;
            map_request<=0;map_ack_sync<=0;map_payload<=0;map_operation<=0;map_wait<=0;map_id<=0;
            ack_pending<=0;ack_id<=0;ack_operation<=0;ack_status<=0;ack_map<=0;
            keymap_reply<=0;rhythm_owned<=0;
            record_session<=0;record_id<=0;record_start<=0;record_stop<=0;stop_reason<=0;lease<=0;end_sent<=0;
            tx_state<=TX_IDLE;kind<=0;position<=0;tx_id<=0;next_sequence<=0;tx_sequence<=0;
            tx_predictor<=0;tx_index<=0;tx_crc<=16'hffff;tx_operation<=0;tx_status<=0;tx_map<=0;
            block_release<=0;read_address<=0;overrun_sync<=0;
        end else begin
            record_start<=0;record_stop<=0;block_release<=0;
            map_ack_sync<={map_ack_sync[0],map_ack};overrun_sync<={overrun_sync[0],pcm_overrun};
            if(record_active)begin
                if(lease!=0)lease<=lease-1'b1;
                else begin record_stop<=1;stop_reason<=2;end
                if(overrun_sync[1])begin record_stop<=1;stop_reason<=4;end
            end
            if(map_wait && map_ack_sync[1]==map_request && !ack_pending)begin
                map_wait<=0;ack_pending<=1;ack_id<=map_id;ack_operation<=map_operation;
                ack_status<=map_result;ack_map<=result_map;
                if(map_operation<=2)keymap_reply<=result_map;
                else rhythm_owned<=result_map[69];
            end
            case(tx_state)
                TX_IDLE:begin
                    position<=0;tx_crc<=16'hffff;read_address<=0;
                    if(ack_pending)begin
                        kind<=ACK;tx_id<=ack_id;tx_operation<=ack_operation;tx_status<={1'b0,ack_status};tx_map<=ack_map;
                        ack_pending<=0;tx_state<=TX_FETCH;
                    end else if(record_session && block_valid && !block_release)begin
                        kind<=DATA;tx_id<=record_id;tx_sequence<=next_sequence;tx_predictor<=block_predictor;tx_index<=block_index;tx_state<=TX_FETCH;
                    end else if(record_session && !record_active && !record_start && !block_valid && !block_release && !end_sent)begin
                        kind<=ENDING;tx_id<=record_id;tx_sequence<=record_count;tx_status<=record_reason;tx_state<=TX_FETCH;end_sent<=1;
                    end
                end
                TX_FETCH:tx_state<=TX_SEND;
                TX_SEND:if(tx_ready)begin
                    if(position<comma_position)tx_crc<=crc_byte(tx_crc,byte_value);
                    if(position==last_position)begin
                        tx_state<=TX_IDLE;
                        if(kind==DATA)begin block_release<=1;next_sequence<=next_sequence+1'b1;end
                        if(kind==ENDING)record_session<=0;
                    end else begin
                        position<=position+1'b1;tx_state<=TX_FETCH;
                        if(kind==DATA && position>=30 && position<189)read_address<=read_address+1'b1;
                    end
                end
                default:tx_state<=TX_IDLE;
            endcase
            if(rx_valid)begin
                if(rx_data==10)begin
                    rx_count<=0;prefix<=0;rx_crc<=16'hffff;supplied_crc<=0;malformed<=0;
                    if(!malformed && rx_count==40 && prefix==48'h50455246312c && rx_crc==supplied_crc && !ack_pending && !map_wait)begin
                        ack_id<=rx_id;ack_operation<=operation;ack_map<=keymap_reply;
                        if((operation>5 && !RHYTHM_ENABLE) || (operation!=1 && operation!=6 && rx_map!=0) || (operation==1 && !map_valid))begin ack_pending<=1;ack_status<=3;end
                        else if(operation<=2 || operation>=6)begin
                            if(record_session)begin ack_pending<=1;ack_status<=2;end
                            else begin map_payload<=rx_map;map_operation<=operation;map_request<=!map_request;map_wait<=1;map_id<=rx_id;end
                        end else if(operation==3)begin
                            ack_pending<=1;
                            if(record_session || rhythm_owned)ack_status<=2;
                            else begin
                                record_id<=rx_id;record_start<=1;record_session<=1;next_sequence<=0;end_sent<=0;
                                stop_reason<=0;lease<=LEASE_CYCLES;ack_status<=0;
                            end
                        end else begin
                            ack_pending<=1;
                            if(!record_session || rx_id!=record_id)ack_status<=3;
                            else begin
                                ack_status<=0;lease<=LEASE_CYCLES;
                                if(operation==4)begin record_stop<=1;stop_reason<=0;end
                            end
                        end
                    end
                end else if(rx_count==63)malformed<=1;
                else begin
                    rx_count<=rx_count+1'b1;
                    if(rx_count<6)prefix<={prefix[39:0],rx_data};
                    if(rx_count<35)rx_crc<=crc_byte(rx_crc,rx_data);
                    if(rx_count>=6 && rx_count<=13)begin rx_id<={rx_id[27:0],unhex(rx_data)};if(!hex_ok)malformed<=1;end
                    if(rx_count==15)begin operation<=rx_data[2:0];if(rx_data<48 || rx_data>(RHYTHM_ENABLE?55:53))malformed<=1;end
                    if(rx_count>=17 && rx_count<=34)begin rx_map<={rx_map[67:0],unhex(rx_data)};if(!hex_ok)malformed<=1;end
                    if(rx_count>=36 && rx_count<=39)begin supplied_crc<={supplied_crc[11:0],unhex(rx_data)};if(!hex_ok)malformed<=1;end
                    if((rx_count==14 || rx_count==16 || rx_count==35) && rx_data!=44)malformed<=1;
                    if(rx_count>=40)malformed<=1;
                end
            end
        end
    end
endmodule
`default_nettype wire
