`default_nettype none
// Lock even before the first transfer so valid/data cannot change under stall.
// Only an accepted LF releases ownership; valid gaps do not release the line.
module uart_line_tx_mux (
    input wire clk, reset_n,
    input wire [7:0] legacy_data, song_data,
    input wire legacy_valid, song_valid,
    output wire legacy_ready, song_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready,
    output wire song_owned
);
    reg locked, owner_song, prefer_song;
    wire selected=locked ? owner_song : (song_valid && (!legacy_valid || prefer_song));
    assign tx_data=selected ? song_data : legacy_data;
    assign tx_valid=selected ? song_valid : legacy_valid;
    assign legacy_ready=tx_ready && !selected;
    assign song_ready=tx_ready && selected;
    assign song_owned=locked && owner_song;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin locked<=0; owner_song<=0; prefer_song<=0; end
        else if(tx_valid) begin
            if(tx_ready && tx_data==8'd10) begin locked<=0; prefer_song<=!selected; end
            else begin locked<=1; owner_song<=selected; end
        end
    end
endmodule
`default_nettype wire
