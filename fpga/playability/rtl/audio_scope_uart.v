`default_nettype none
// SCOPE1: on-demand immutable 1024-pair snapshot, NOT a live PCM stream.
// Capture at the actual PT8211 sample edge (48000 Hz), signed high 8 bits of
// effect input/output. 32 lines x 32 pairs, 153 ASCII bytes/line incl LF;
// 4896 bytes / 960 bytes/s = 5.10 s minimum transfer at production 9600 8N1.
// Request: SCOPE1,XXXXXXXX,CCCC\n. CRC16-CCITT init FFFF covers ASCII before
// the last comma. Reply: SCOPE1,XXXXXXXX,II,<128 hex chars>,CCCC\n.
// II=00..1F, payload is interleaved dry/wet signed bytes. No decimation.
// CDC: sys request toggle -> 2 audio FFs; after all writes audio done toggle
// -> 2 sys FFs. Memory is immutable until the next accepted request, which
// cannot occur until transmission finishes. Resets must assert together.
module audio_scope_uart (
    input wire sys_clk, sys_reset_n, audio_clk, audio_reset_n,
    input wire sample_strobe,
    input wire signed [15:0] dry_sample, wet_sample,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready
);
    function [15:0] crc_byte;
        input [15:0] crc;
        input [7:0] value;
        reg [15:0] c;
        integer bit_index;
        begin
            c=crc^{value,8'd0};
            for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction
    function [7:0] hex_char;
        input [3:0] nibble;
        begin hex_char=nibble<4'd10 ? 8'd48+{4'd0,nibble} : 8'd55+{4'd0,nibble}; end
    endfunction
    function [3:0] unhex;
        input [7:0] value;
        begin unhex=value<=8'd57 ? value[3:0] : value[3:0]+4'd9; end
    endfunction
    wire hex_ok=(rx_data>=8'd48 && rx_data<=8'd57) || (rx_data>=8'd65 && rx_data<=8'd70);
    reg [4:0] rx_count;
    reg [55:0] prefix;
    reg [31:0] rx_id, capture_id;
    reg [15:0] rx_crc, supplied_crc;
    reg malformed;
    reg request_toggle;
    reg [1:0] request_sync, done_sync;
    reg done_toggle, capturing;
    reg [9:0] write_index;
    (* syn_ramstyle="block_ram" *) reg [15:0] samples [0:1023];
    always @(posedge audio_clk) begin
        if(audio_reset_n && capturing && sample_strobe)
            samples[write_index]<={dry_sample[15:8],wet_sample[15:8]};
    end
    always @(posedge audio_clk or negedge audio_reset_n) begin
        if(!audio_reset_n) begin
            request_sync<=0;done_toggle<=0;capturing<=0;write_index<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            if(!capturing && request_sync[1]!=done_toggle) begin
                capturing<=1;write_index<=0;
            end else if(capturing && sample_strobe) begin
                if(write_index==10'd1023) begin capturing<=0;done_toggle<=request_sync[1];end
                else write_index<=write_index+1'b1;
            end
        end
    end
    localparam [1:0] IDLE=0, WAIT_CAPTURE=1, FETCH=2, SEND=3;
    reg [1:0] state;
    reg [4:0] block_index;
    reg [7:0] position;
    reg [9:0] read_index;
    reg [15:0] read_pair, tx_crc;
    reg [7:0] byte_value;
    always @(posedge sys_clk) read_pair<=samples[read_index];
    always @* begin
        byte_value=8'd0;
        case(position)
            0:byte_value="S";1:byte_value="C";2:byte_value="O";
            3:byte_value="P";4:byte_value="E";5:byte_value="1";
            6,15,18,147:byte_value=",";
            7:byte_value=hex_char(capture_id[31:28]);8:byte_value=hex_char(capture_id[27:24]);
            9:byte_value=hex_char(capture_id[23:20]);10:byte_value=hex_char(capture_id[19:16]);
            11:byte_value=hex_char(capture_id[15:12]);12:byte_value=hex_char(capture_id[11:8]);
            13:byte_value=hex_char(capture_id[7:4]);14:byte_value=hex_char(capture_id[3:0]);
            16:byte_value=hex_char({3'd0,block_index[4]});17:byte_value=hex_char(block_index[3:0]);
            148:byte_value=hex_char(tx_crc[15:12]);149:byte_value=hex_char(tx_crc[11:8]);
            150:byte_value=hex_char(tx_crc[7:4]);151:byte_value=hex_char(tx_crc[3:0]);
            152:byte_value=8'd10;
            default:case((position-8'd19)&8'd3)
                0:byte_value=hex_char(read_pair[15:12]);1:byte_value=hex_char(read_pair[11:8]);
                2:byte_value=hex_char(read_pair[7:4]);default:byte_value=hex_char(read_pair[3:0]);
            endcase
        endcase
    end
    assign tx_valid=state==SEND;
    assign tx_data=byte_value;
    // Every accepted character is followed by a synchronous RAM fetch cycle.
    // This holds valid/data stable on arbitrary UART stalls, including boundaries.
    always @(posedge sys_clk or negedge sys_reset_n) begin
        if(!sys_reset_n) begin
            rx_count<=0;prefix<=0;rx_id<=0;capture_id<=0;rx_crc<=16'hffff;
            supplied_crc<=0;malformed<=0;request_toggle<=0;done_sync<=0;
            state<=IDLE;block_index<=0;position<=0;read_index<=0;tx_crc<=16'hffff;
        end else begin
            done_sync<={done_sync[0],done_toggle};
            if(state==WAIT_CAPTURE && done_sync[1]==request_toggle) begin
                state<=FETCH;block_index<=0;position<=0;read_index<=0;tx_crc<=16'hffff;
            end else if(state==FETCH) state<=SEND;
            else if(state==SEND && tx_ready) begin
                if(position<8'd147) tx_crc<=crc_byte(tx_crc,byte_value);
                state<=FETCH;
                if(position==8'd152) begin
                    position<=0;tx_crc<=16'hffff;
                    if(block_index==5'd31) state<=IDLE;
                    else begin block_index<=block_index+1'b1;read_index<=read_index+1'b1;end
                end else begin
                    position<=position+1'b1;
                    if(position>=8'd19 && position<8'd143 && ((position-8'd19)&8'd3)==8'd3)
                        read_index<=read_index+1'b1;
                end
            end
            if(rx_valid) begin
                if(rx_data==8'd10) begin
                    if(state==IDLE && !malformed && rx_count==5'd20 &&
                        prefix==56'h53434f5045312c && rx_crc==supplied_crc) begin
                        capture_id<=rx_id;request_toggle<=!request_toggle;state<=WAIT_CAPTURE;
                    end
                    rx_count<=0;prefix<=0;rx_id<=0;rx_crc<=16'hffff;supplied_crc<=0;malformed<=0;
                end else begin
                    if(rx_count<5'd21) rx_count<=rx_count+1'b1;
                    else malformed<=1;
                    if(rx_count<5'd15) rx_crc<=crc_byte(rx_crc,rx_data);
                    if(rx_count<5'd7) prefix<={prefix[47:0],rx_data};
                    else if(rx_count<5'd15) begin
                        rx_id<={rx_id[27:0],unhex(rx_data)};
                        if(!hex_ok) malformed<=1;
                    end else if(rx_count==5'd15) begin if(rx_data!=8'd44) malformed<=1;end
                    else if(rx_count<5'd20) begin
                        supplied_crc<={supplied_crc[11:0],unhex(rx_data)};
                        if(!hex_ok) malformed<=1;
                    end else malformed<=1;
                end
            end
        end
    end
endmodule
`default_nettype wire
