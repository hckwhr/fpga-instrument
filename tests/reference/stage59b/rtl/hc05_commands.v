`default_nettype none
// Legacy short-command byte endpoint; hc05_link preserves the original UART wrapper.
// Upper-case ASCII commands terminated by LF or CRLF, one outstanding request.
// A response proves FPGA execution; no STATE wire exists on the four-pin HC-05.
module hc05_commands #(parameter integer CE_ENABLE=0,
    
    parameter integer TIMEOUT_CYCLES = 98_305_085,
    parameter integer EXTERNAL_PLAY_GUARD = 0
) (
    input wire clock_enable,
    
    input wire clk, reset_n,
    input wire [7:0] rx_data,
    input wire rx_valid, rx_error,
    // Whole-line router has already drained/isolated this bad line.
    input wire [1:0] line_fault,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready, tx_busy,
    input wire setting_mode, stop_key, song_active, song_done,
    input wire play_blocked,
    input wire [7:0] song_index,
    input wire [7:0] song_length,
    output reg play_request, stop_request
);
    localparam integer TW = (TIMEOUT_CYCLES>1) ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [TW-1:0] TIMEOUT_LAST =
        (CE_ENABLE ? (TIMEOUT_CYCLES+1)/2 : TIMEOUT_CYCLES)-1;
    reg [63:0] line;
    reg [3:0] length;
    reg discard, cr_seen, busy_pending;
    reg [TW-1:0] timeout_count;
    // Fixed short responses use a shift register; no RAM or general formatter.
    reg [319:0] reply;
    reg [5:0] remaining;
    wire response_busy = (remaining!=0) || tx_busy;
    wire [7:0] position = song_index+8'd1;
    wire [7:0] hundreds = 8'd48 + position/8'd100;
    wire [7:0] tens = 8'd48 + (position/8'd10)%8'd10;
    wire [7:0] units = 8'd48 + position%8'd10;
    wire [7:0] total_hundreds = 8'd48 + song_length/8'd100;
    wire [7:0] total_tens = 8'd48 + (song_length/8'd10)%8'd10;
    wire [7:0] total_units = 8'd48 + song_length%8'd10;
    assign tx_data=reply[319:312];
    assign tx_valid=remaining!=0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            line<=0; length<=0; discard<=0; cr_seen<=0; timeout_count<=0;
            reply<=0; remaining<=0; busy_pending<=0;
            play_request<=0; stop_request<=0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            play_request<=0; stop_request<=0;
            if (remaining!=0 && tx_ready) begin
                reply<={reply[311:0],8'd0}; remaining<=remaining-1'b1;
            end
            if (!response_busy && busy_pending) begin
                reply<={"ERR,BUSY\n",248'd0}; remaining<=9; busy_pending<=0;
            end
            if (line_fault!=0) begin
                line<=0; length<=0; discard<=0; cr_seen<=0; timeout_count<=0;
                if (response_busy || busy_pending) busy_pending<=1;
                else case(line_fault)
                    2'd1: begin reply<={"ERR,FRAME\n",240'd0}; remaining<=10; end
                    2'd2: begin reply<={"ERR,TIMEOUT\n",224'd0}; remaining<=12; end
                    default: begin reply<={"ERR,LINE\n",248'd0}; remaining<=9; end
                endcase
            end else if (rx_error) begin
                discard<=1; timeout_count<=0;
                if (response_busy || busy_pending) busy_pending<=1;
                else begin reply<={"ERR,FRAME\n",240'd0}; remaining<=10; end
            end else if (rx_valid) begin
                timeout_count<=0;
                if (rx_data==8'd10) begin
                    line<=0; length<=0; discard<=0; cr_seen<=0;
                    // STOP remains available under backpressure. Flooded commands
                    // never start music; the peer must wait for each response.
                    if (!discard && length==4 && line==64'h53544f50) stop_request<=1;
                    if (response_busy || busy_pending) begin
                        if (length!=0 || discard) busy_pending<=1;
                    end else if (discard) begin
                        reply<={"ERR,LINE\n",248'd0}; remaining<=9;
                    end else if (length==0) begin end
                    else if (length==4 && line==64'h50494e47) begin
                        reply<={"PONG\n",280'd0}; remaining<=5;
                    end else if (length==5 && line==64'h48454c4c4f) begin
                        reply<={"OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\n",32'd0}; remaining<=36;
                    end else if (length==4 && line==64'h53544f50) begin
                        reply<={"OK,STOP\n",256'd0}; remaining<=8;
                    end else if (length==4 && line==64'h504c4159) begin
                        if (setting_mode || stop_key || (EXTERNAL_PLAY_GUARD!=0 && play_blocked)) begin
                            reply<={"ERR,LOCAL\n",240'd0}; remaining<=10;
                        end else begin
                            // Idempotent PLAY does not restart a running song.
                            if (!song_active || song_done) play_request<=1;
                            reply<={"OK,PLAY\n",256'd0}; remaining<=8;
                        end
                    end else if (length==6 && line==64'h535441545553) begin
                        if (setting_mode) begin
                            reply<={"STATUS,SETTING\n",200'd0}; remaining<=15;
                        end else if (!song_active) begin
                            reply<={"STATUS,MANUAL\n",208'd0}; remaining<=14;
                        end else if (song_done) begin
                            reply<={"STATUS,STOPPED,",hundreds,tens,units,"/",total_hundreds,total_tens,total_units,"\n",136'd0}; remaining<=23;
                        end else begin
                            reply<={"STATUS,PLAYING,",hundreds,tens,units,"/",total_hundreds,total_tens,total_units,"\n",136'd0}; remaining<=23;
                        end
                    end else begin
                        reply<={"ERR,COMMAND\n",224'd0}; remaining<=12;
                    end
                end else if (!discard) begin
                    if (rx_data==8'd13 && !cr_seen) cr_seen<=1;
                    else if (cr_seen || length==8 || rx_data<8'd32 || rx_data>8'd126) discard<=1;
                    else begin line<={line[55:0],rx_data}; length<=length+1'b1; end
                end
            end else if (!discard && (length!=0 || cr_seen)) begin
                if (timeout_count==TIMEOUT_LAST) begin
                    // Discard until LF: a delayed suffix cannot become a command.
                    discard<=1; timeout_count<=0;
                    if (response_busy || busy_pending) busy_pending<=1;
                    else begin reply<={"ERR,TIMEOUT\n",224'd0}; remaining<=12; end
                end else timeout_count<=timeout_count+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
