`default_nettype none

module pt8211_tx (
    input  wire               audio_clk,
    input  wire               reset_n,
    input  wire signed [15:0] sample_in,
    output reg                sample_strobe,
    output reg                audio_bck,
    output reg                audio_ws,
    output reg                audio_din,
    output reg                stream_ready
);

    localparam [3:0] BCK_HALF_PERIOD_CYCLES = 4'd15;
    localparam [6:0] LAST_SILENT_FRAME      = 7'd63;

    reg [3:0]  bck_half_counter;
    reg [4:0]  bit_index;
    reg [6:0]  silent_frame_count;
    reg [31:0] frame_shift;
    reg        frame_started;

    // PT8211 data changes on BCK rising edges and is sampled on falling edges.
    // WS is low for the left 16-bit word and high for the right word.
    always @(posedge audio_clk or negedge reset_n) begin
        if (!reset_n) begin
            bck_half_counter   <= 4'd0;
            bit_index          <= 5'd0;
            silent_frame_count <= 7'd0;
            frame_shift        <= 32'd0;
            frame_started      <= 1'b0;
            sample_strobe      <= 1'b0;
            audio_bck          <= 1'b0;
            audio_ws           <= 1'b0;
            audio_din          <= 1'b0;
            stream_ready       <= 1'b0;
        end else begin
            sample_strobe <= 1'b0;

            if (bck_half_counter == BCK_HALF_PERIOD_CYCLES) begin
                bck_half_counter <= 4'd0;
                audio_bck        <= ~audio_bck;

                if (!audio_bck) begin
                    if (!frame_started) begin
                        frame_started <= 1'b1;
                    end else if (bit_index == 5'd31) begin
                        bit_index <= 5'd0;
                        audio_ws  <= 1'b0;

                        if (!stream_ready) begin
                            if (silent_frame_count == LAST_SILENT_FRAME) begin
                                silent_frame_count <= 7'd64;
                                frame_shift        <= {sample_in, sample_in};
                                audio_din          <= sample_in[15];
                                sample_strobe      <= 1'b1;
                                stream_ready       <= 1'b1;
                            end else begin
                                silent_frame_count <= silent_frame_count + 7'd1;
                                frame_shift        <= 32'd0;
                                audio_din          <= 1'b0;
                            end
                        end else begin
                            frame_shift   <= {sample_in, sample_in};
                            audio_din     <= sample_in[15];
                            sample_strobe <= 1'b1;
                        end
                    end else begin
                        bit_index   <= bit_index + 5'd1;
                        frame_shift <= {frame_shift[30:0], 1'b0};
                        audio_din   <= frame_shift[30];

                        if (bit_index == 5'd15)
                            audio_ws <= 1'b1;
                    end
                end
            end else begin
                bck_half_counter <= bck_half_counter + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
