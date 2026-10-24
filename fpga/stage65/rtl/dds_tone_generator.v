`default_nettype none

module dds_tone_generator #(
    parameter [31:0] PHASE_INCREMENT = 32'd89_477_498
) (
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_strobe,
    output wire signed [15:0] sample
);

    reg [31:0] phase_accumulator;

    wire [15:0]        triangle_unsigned;
    wire signed [15:0] triangle_centered;

    assign triangle_unsigned = phase_accumulator[31]
                             ? ~phase_accumulator[30:15]
                             :  phase_accumulator[30:15];
    assign triangle_centered = $signed(triangle_unsigned ^ 16'h8000);
    assign sample            = triangle_centered >>> 2;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            phase_accumulator <= 32'h4000_0000;
        else if (sample_strobe)
            phase_accumulator <= phase_accumulator + PHASE_INCREMENT;
    end

endmodule

`default_nettype wire
