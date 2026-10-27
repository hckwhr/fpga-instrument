`default_nettype none
// One bounded complete-line buffer. The physical UART cannot be backpressured:
// busy arrivals are dropped through LF, never reinterpreted as fresh commands.
module uart_line_router #(
    parameter integer TIMEOUT_CYCLES=100_000_000,
    parameter integer HANDSHAKE_LEGACY=0,
    parameter integer SCOPE_ENABLE=0
) (
    input wire clk, reset_n,
    input wire [7:0] rx_data,
    input wire rx_valid, rx_error,
    output wire [7:0] line_data,
    output wire legacy_valid, song_valid,
    output wire scope_valid,
    input wire song_ready,
    input wire legacy_ready,
    output reg [1:0] legacy_fault,
    output reg rx_dropped
);
    localparam integer TW=TIMEOUT_CYCLES>1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [TW-1:0] TIMEOUT_LAST=TIMEOUT_CYCLES-1;
    (* syn_ramstyle="block_ram" *) reg [7:0] memory[0:254];
    reg [7:0] replay_byte;
    reg [7:0] length, index;
    reg [47:0] prefix;
    reg sending, selected_song, selected_scope, discard, cr_seen;
    reg [TW-1:0] idle_count;
    wire is_song=length>=6 && prefix==48'h534f4e47322c; // SONG2,
    wire is_scope=SCOPE_ENABLE!=0 && length>=6 && prefix==48'h53434f504531; // SCOPE1
    wire replay_accept=selected_scope || (selected_song ? song_ready : (HANDSHAKE_LEGACY==0 || legacy_ready));
    // Prefetch the next accepted address. Stalls re-read the current byte;
    // the LF edge fetches byte zero, so replay still sustains one byte/clock.
    wire [7:0] replay_index=!sending || index==length ? 8'd0 :
        replay_accept && index+8'd1<length ? index+8'd1 : index;
    wire write_byte=reset_n && !sending && !discard && !rx_error && rx_valid &&
        !cr_seen && length<8'd255 && rx_data>=8'd32 && rx_data<=8'd126;
    always @(posedge clk) begin
        if(write_byte) memory[length]<=rx_data;
        replay_byte<=memory[replay_index]; // No reset: BSRAM read port.
    end
    assign line_data=index==length ? 8'd10 : replay_byte;
    assign legacy_valid=sending && !selected_song && !selected_scope;
    assign song_valid=sending && selected_song;
    assign scope_valid=sending && selected_scope;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            length<=0; index<=0; prefix<=0; sending<=0; selected_song<=0;selected_scope<=0;
            discard<=0; cr_seen<=0; idle_count<=0; legacy_fault<=0; rx_dropped<=0;
        end else begin
            legacy_fault<=0;
            if(sending) begin
                // Account for a new byte on the same edge as the final replay
                // byte: its suffix must remain poisoned after the buffer frees.
                if(rx_error || rx_valid) begin
                    discard<=rx_error || rx_data!=8'd10;
                    rx_dropped<=1;
                end
                if(replay_accept) begin
                    if(index==length) begin
                        sending<=0; length<=0; prefix<=0; cr_seen<=0; idle_count<=0;
                    end else index<=index+1'b1;
                end
            end else if(discard) begin
                if(rx_valid && !rx_error && rx_data==8'd10) begin
                    discard<=0; length<=0; prefix<=0; cr_seen<=0; idle_count<=0;
                end
            end else if(rx_error) begin
                discard<=1; rx_dropped<=1; idle_count<=0;
                if(!is_song) legacy_fault<=2'd1;
            end else if(rx_valid) begin
                idle_count<=0;
                if(rx_data==8'd10) begin
                    if(length!=0 && (!is_song || song_ready)) begin
                        sending<=1; index<=0; selected_song<=is_song;selected_scope<=is_scope;
                    end else begin
                        if(length!=0) rx_dropped<=1;
                        length<=0; prefix<=0; cr_seen<=0;
                    end
                end else if(rx_data==8'd13 && !cr_seen) cr_seen<=1;
                else if(cr_seen || length==8'd255 || rx_data<8'd32 || rx_data>8'd126) begin
                    discard<=1; rx_dropped<=1;
                    if(!is_song) legacy_fault<=2'd3;
                end else begin
                    length<=length+1'b1;
                    if(length<6) prefix<={prefix[39:0],rx_data};
                end
            end else if(length!=0 || cr_seen) begin
                if(idle_count==TIMEOUT_LAST) begin
                    discard<=1; rx_dropped<=1; idle_count<=0;
                    if(!is_song) legacy_fault<=2'd2;
                end else idle_count<=idle_count+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
