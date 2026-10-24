`default_nettype none

module key_debounce #(parameter integer CE_ENABLE=0,
    
    parameter integer COUNTER_WIDTH = 18,
    parameter integer STABLE_CYCLES = 245760
) (
    input wire clock_enable,
    
    input  wire clk,
    input  wire reset_n,
    input  wire key_n,
    output wire pressed
);

    // Preserve wall-clock debounce time with one engine step per two clocks.
    localparam [COUNTER_WIDTH-1:0] STABLE_COUNT_LAST =
        (CE_ENABLE ? (STABLE_CYCLES+1)/2 : STABLE_CYCLES) - 1;

    reg [1:0] key_sync;
    reg       stable_key_n;
    reg [COUNTER_WIDTH-1:0] stable_count;

    assign pressed = ~stable_key_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key_sync    <= 2'b11;
            stable_key_n <= 1'b1;
            stable_count <= {COUNTER_WIDTH{1'b0}};
        end else if ((!CE_ENABLE || clock_enable)) begin
            key_sync <= {key_sync[0], key_n};

            if (key_sync[1] == stable_key_n) begin
                stable_count <= {COUNTER_WIDTH{1'b0}};
            end else if (stable_count == STABLE_COUNT_LAST) begin
                stable_key_n <= key_sync[1];
                stable_count <= {COUNTER_WIDTH{1'b0}};
            end else begin
                stable_count <= stable_count + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
            end
        end
    end

endmodule

`default_nettype wire
