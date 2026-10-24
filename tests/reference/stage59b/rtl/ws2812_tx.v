`default_nettype none

// 36 WS2812B pixels: three consecutive pixels per pitch class, C through B.
// Worldsemi WS2812B datasheet: GRB, MSB first, 800 kbit/s; see STAGE34.md.
// Production clock is the existing 100/3 MHz pixel clock. No divided clock.
module ws2812_tx #(
    parameter [23:0] ON_GRB = 24'h100800,
    parameter integer STARTUP_CYCLES = 333334
) (
    input wire clk,
    input wire reset_n,
    input wire [11:0] held_notes,
    output reg data_out,
    output reg buffer_enable
);
    localparam [1:0] STARTUP = 2'd0, LATCH = 2'd1, SEND = 2'd2;
    localparam integer STARTUP_WIDTH = (STARTUP_CYCLES > 1) ? $clog2(STARTUP_CYCLES) : 1;
    localparam [STARTUP_WIDTH-1:0] STARTUP_LAST = STARTUP_CYCLES - 1;
    // 42 clocks = 1.260 us. 0: 360 ns high/900 ns low;
    // 1: 810 ns high/450 ns low. Reset: 350.010 us (> 300 us).
    localparam [5:0] BIT_LAST = 6'd41, ZERO_HIGH = 6'd12, ONE_HIGH = 6'd27;
    localparam [13:0] LATCH_LAST = 14'd11666;
    reg [1:0] state;
    reg [STARTUP_WIDTH-1:0] startup_count;
    reg [13:0] latch_count;
    reg [5:0] phase;
    reg [4:0] bit_index;
    reg [3:0] key_index;
    reg [1:0] lamp_in_key;
    reg [11:0] frame_notes;
    reg [23:0] shift_grb;
    reg first_frame;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= STARTUP;
            startup_count <= {STARTUP_WIDTH{1'b0}};
            latch_count <= 14'd0;
            phase <= 6'd0;
            bit_index <= 5'd23;
            key_index <= 4'd0;
            lamp_in_key <= 2'd0;
            frame_notes <= 12'd0;
            shift_grb <= 24'd0;
            first_frame <= 1'b1;
            data_out <= 1'b0;
            buffer_enable <= 1'b0;
        end else begin
            case (state)
                STARTUP: begin
                    data_out <= 1'b0;
                    buffer_enable <= 1'b0;
                    if (startup_count == STARTUP_LAST) begin
                        buffer_enable <= 1'b1;
                        latch_count <= 14'd0;
                        state <= LATCH;
                    end else startup_count <= startup_count + 1'b1;
                end
                LATCH: begin
                    data_out <= 1'b0;
                    if (latch_count == LATCH_LAST) begin
                        // Capture once for all 864 bits. Mid-frame updates
                        // become visible only on the following frame.
                        frame_notes <= first_frame ? 12'd0 : held_notes;
                        shift_grb <= (!first_frame && held_notes[0]) ? ON_GRB : 24'd0;
                        first_frame <= 1'b0;
                        key_index <= 4'd0;
                        lamp_in_key <= 2'd0;
                        bit_index <= 5'd23;
                        phase <= 6'd0;
                        state <= SEND;
                    end else latch_count <= latch_count + 1'b1;
                end
                SEND: begin
                    data_out <= (phase < (shift_grb[23] ? ONE_HIGH : ZERO_HIGH));
                    if (phase == BIT_LAST) begin
                        phase <= 6'd0;
                        if (bit_index != 5'd0) begin
                            bit_index <= bit_index - 1'b1;
                            shift_grb <= {shift_grb[22:0], 1'b0};
                        end else begin
                            bit_index <= 5'd23;
                            if (lamp_in_key != 2'd2) begin
                                lamp_in_key <= lamp_in_key + 1'b1;
                                shift_grb <= frame_notes[key_index] ? ON_GRB : 24'd0;
                            end else if (key_index != 4'd11) begin
                                lamp_in_key <= 2'd0;
                                key_index <= key_index + 1'b1;
                                shift_grb <= frame_notes[key_index + 4'd1] ? ON_GRB : 24'd0;
                            end else begin
                                latch_count <= 14'd0;
                                state <= LATCH;
                            end
                        end
                    end else phase <= phase + 1'b1;
                end
                default: begin
                    state <= STARTUP;
                    startup_count <= {STARTUP_WIDTH{1'b0}};
                    first_frame <= 1'b1;
                    buffer_enable <= 1'b0;
                    data_out <= 1'b0;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
