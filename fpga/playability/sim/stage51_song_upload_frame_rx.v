`default_nettype none
// Stop-and-wait receiver: discard mode drains through LF. A held frame is
// immutable; traffic received while busy poisons any partial following line.
module stage51_song_upload_frame_rx #(
    parameter integer TIMEOUT_CYCLES = 100_000_000
) (
    input wire clk, reset_n,
    input wire rx_valid, rx_error,
    input wire [7:0] rx_data,
    output wire rx_ready,
    output reg frame_valid,
    input wire frame_ready,
    output reg [7:0] frame_length,
    input wire [7:0] frame_index,
    output wire [7:0] frame_byte,
    output reg error_valid,
    output reg [1:0] error_code
);
    localparam [2:0] RECEIVE=0, CRC_SCAN=1, PUBLISH=2, HOLD=3, DISCARD=4;
    localparam integer TW = TIMEOUT_CYCLES>1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [TW-1:0] TIMEOUT_LAST=TIMEOUT_CYCLES-1;
    reg [2:0] state;
    reg [7:0] line_mem [0:254];
    reg [7:0] line_length, body_length, crc_index;
    reg [15:0] crc, expected_crc;
    reg cr_seen, suffix_pending;
    // Include the current byte on the cycle that a busy frame is released.
    wire pending_suffix = (rx_valid || rx_error) ? (rx_error || rx_data!=8'd10) : suffix_pending;
    reg [TW-1:0] idle_count;
    assign rx_ready = state==RECEIVE || state==DISCARD;
    assign frame_byte = frame_index<frame_length ? line_mem[frame_index] : 8'd0;
    function is_hex;
        input [7:0] value;
        begin is_hex=(value>=8'h30 && value<=8'h39)||(value>=8'h41 && value<=8'h46); end
    endfunction
    function [3:0] hex_nibble;
        input [7:0] value;
        begin hex_nibble=value<=8'h39 ? value-8'h30 : value-8'h37; end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] next_crc;
        integer b;
        begin
            next_crc=old_crc^{value,8'd0};
            for(b=0;b<8;b=b+1) next_crc=next_crc[15] ? (next_crc<<1)^16'h1021 : next_crc<<1;
            crc_byte=next_crc;
        end
    endfunction
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=RECEIVE; frame_valid<=0; frame_length<=0; line_length<=0;
            body_length<=0; crc<=16'hffff; expected_crc<=0; crc_index<=0;
            cr_seen<=0; suffix_pending<=0; idle_count<=0; error_valid<=0; error_code<=0;
        end else begin
            error_valid<=0;
            if (!rx_ready && (rx_valid || rx_error)) suffix_pending<=pending_suffix;
            case(state)
                RECEIVE: begin
                    if(rx_error) begin state<=DISCARD; idle_count<=0; end
                    else if(rx_valid) begin
                        idle_count<=0;
                        if(rx_data==8'd10) begin
                            cr_seen<=0;
                            if(line_length<8'd6) begin error_valid<=1; error_code<=2; line_length<=0; end
                            else begin body_length<=line_length-8'd5; crc_index<=0; crc<=16'hffff; state<=CRC_SCAN; end
                        end else if(rx_data==8'd13 && !cr_seen && line_length<8'd255) cr_seen<=1;
                        else if(cr_seen || line_length==8'd255 || rx_data<8'h20 || rx_data>8'h7e) state<=DISCARD;
                        else begin line_mem[line_length]<=rx_data; line_length<=line_length+1'b1; end
                    end else if(line_length!=0 || cr_seen) begin
                        if(idle_count==TIMEOUT_LAST) begin state<=DISCARD; idle_count<=0; error_valid<=1; error_code<=1; end
                        else idle_count<=idle_count+1'b1;
                    end
                end
                DISCARD: if(rx_valid && !rx_error && rx_data==8'd10) begin
                    error_valid<=1; error_code<=2; line_length<=0; cr_seen<=0; idle_count<=0; state<=RECEIVE;
                end
                CRC_SCAN: begin
                    if(line_mem[body_length]!=8'h2c || !is_hex(line_mem[line_length-4]) ||
                       !is_hex(line_mem[line_length-3]) || !is_hex(line_mem[line_length-2]) || !is_hex(line_mem[line_length-1])) begin
                        error_valid<=1; error_code<=3; line_length<=0; state<=pending_suffix ? DISCARD : RECEIVE;
                        suffix_pending<=0;
                    end else begin
                        expected_crc<={hex_nibble(line_mem[line_length-4]),hex_nibble(line_mem[line_length-3]),hex_nibble(line_mem[line_length-2]),hex_nibble(line_mem[line_length-1])};
                        crc<=crc_byte(crc,line_mem[crc_index]);
                        if(crc_index+8'd1==body_length) state<=PUBLISH;
                        else crc_index<=crc_index+1'b1;
                    end
                end
                PUBLISH: if(crc!=expected_crc) begin
                    error_valid<=1; error_code<=3; line_length<=0;
                    state<=pending_suffix ? DISCARD : RECEIVE; suffix_pending<=0;
                end else begin frame_length<=line_length; frame_valid<=1; state<=HOLD; end
                HOLD: if(frame_ready) begin
                    frame_valid<=0; line_length<=0; idle_count<=0;
                    state<=pending_suffix ? DISCARD : RECEIVE;
                    suffix_pending<=0;
                end
                default: begin state<=DISCARD; frame_valid<=0; end
            endcase
        end
    end
endmodule
`default_nettype wire
