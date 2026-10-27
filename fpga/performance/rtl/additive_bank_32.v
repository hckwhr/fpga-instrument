`default_nettype none

module additive_partial #(parameter integer CE_ENABLE=0,
    
    parameter [31:0] PHASE_INCREMENT = 32'd9_842_633,
    parameter [7:0]  TARGET_GAIN = 8'd96
) (
    input wire clock_enable,
    
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_strobe,
    input  wire               enable,
    output reg  signed [15:0] sample,
    output wire               active
);

    reg [31:0] phase_accumulator;
    reg [7:0]  envelope_gain;

    wire signed [15:0] waveform;
    wire signed [8:0]  gain_signed;
    wire signed [24:0] scaled_sample;

    assign waveform = triangle_wave(phase_accumulator);
    assign gain_signed = $signed({1'b0, envelope_gain});
    assign scaled_sample = $signed(waveform) * gain_signed;
    assign active = (envelope_gain != 8'd0);

    function signed [15:0] triangle_wave;
        input [31:0] phase;
        reg [15:0] triangle_unsigned;
        reg signed [15:0] centered;
        begin
            triangle_unsigned = phase[31] ? ~phase[30:15] : phase[30:15];
            centered = $signed(triangle_unsigned ^ 16'h8000);
            triangle_wave = centered >>> 2;
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            phase_accumulator <= 32'd0;
            envelope_gain     <= 8'd0;
            sample            <= 16'sd0;
        end else if ((!CE_ENABLE || clock_enable)) if (sample_strobe) begin
            if (enable) begin
                phase_accumulator <= phase_accumulator + PHASE_INCREMENT;
                if (envelope_gain < TARGET_GAIN)
                    envelope_gain <= envelope_gain + 8'd1;
            end else begin
                phase_accumulator <= 32'd0;
                if (envelope_gain != 8'd0)
                    envelope_gain <= envelope_gain - 8'd1;
            end

            sample <= scaled_sample[23:8];
        end
    end

endmodule

module additive_bank_32 #(
    parameter integer CE_ENABLE=0,
    parameter [31:0] BASE_PHASE_INCREMENT = 32'd9_842_633,
    parameter integer ACTIVATION_INTERVAL_SAMPLES = 1_200,
    parameter [7:0] MASTER_GAIN = 8'd64
) (
    input  wire               clock_enable,
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_strobe,
    input  wire               enable,
    output wire signed [15:0] sample,
    output wire               all_partials_active
);

    wire signed [15:0] partial_sample [0:31];
    wire [31:0] partial_active;
    wire signed [16:0] sum_level_1 [0:15];
    wire signed [17:0] sum_level_2 [0:7];
    wire signed [18:0] sum_level_3 [0:3];
    wire signed [19:0] sum_level_4 [0:1];
    wire signed [20:0] sum_level_5;
    reg  signed [15:0] mixed_sample;
    reg  [5:0] active_partial_count;
    reg  [15:0] activation_sample_count;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_partial_count     <= 6'd0;
            activation_sample_count  <= 16'd0;
        end else if ((!CE_ENABLE || clock_enable)) if (sample_strobe) begin
            if (!enable) begin
                active_partial_count    <= 6'd0;
                activation_sample_count <= 16'd0;
            end else if (active_partial_count == 6'd0) begin
                active_partial_count    <= 6'd1;
                activation_sample_count <= 16'd0;
            end else if (active_partial_count < 6'd32) begin
                if (activation_sample_count ==
                    ACTIVATION_INTERVAL_SAMPLES - 1) begin
                    active_partial_count    <= active_partial_count + 6'd1;
                    activation_sample_count <= 16'd0;
                end else begin
                    activation_sample_count <= activation_sample_count + 16'd1;
                end
            end
        end
    end

    genvar partial_index;
    generate
        for (partial_index = 0; partial_index < 32;
             partial_index = partial_index + 1) begin : u_partial_bank
            localparam integer HARMONIC = partial_index + 1;
            localparam [31:0] HARMONIC_INCREMENT =
                BASE_PHASE_INCREMENT * HARMONIC;
            localparam [7:0] HARMONIC_GAIN = MASTER_GAIN / HARMONIC;
            wire partial_enable;

            assign partial_enable = enable &&
                                    (active_partial_count > partial_index);

            additive_partial #(
                .CE_ENABLE(CE_ENABLE),
                .PHASE_INCREMENT(HARMONIC_INCREMENT),
                .TARGET_GAIN    (HARMONIC_GAIN)
            ) u_partial (
                .clock_enable(clock_enable),
                .clk          (clk),
                .reset_n      (reset_n),
                .sample_strobe(sample_strobe),
                .enable       (partial_enable),
                .sample       (partial_sample[partial_index]),
                .active       (partial_active[partial_index])
            );
        end
    endgenerate

    genvar sum_index_1;
    generate
        for (sum_index_1 = 0; sum_index_1 < 16;
             sum_index_1 = sum_index_1 + 1) begin : u_sum_level_1
            assign sum_level_1[sum_index_1] =
                $signed({partial_sample[sum_index_1 * 2][15],
                         partial_sample[sum_index_1 * 2]}) +
                $signed({partial_sample[sum_index_1 * 2 + 1][15],
                         partial_sample[sum_index_1 * 2 + 1]});
        end
    endgenerate

    genvar sum_index_2;
    generate
        for (sum_index_2 = 0; sum_index_2 < 8;
             sum_index_2 = sum_index_2 + 1) begin : u_sum_level_2
            assign sum_level_2[sum_index_2] =
                $signed({sum_level_1[sum_index_2 * 2][16],
                         sum_level_1[sum_index_2 * 2]}) +
                $signed({sum_level_1[sum_index_2 * 2 + 1][16],
                         sum_level_1[sum_index_2 * 2 + 1]});
        end
    endgenerate

    genvar sum_index_3;
    generate
        for (sum_index_3 = 0; sum_index_3 < 4;
             sum_index_3 = sum_index_3 + 1) begin : u_sum_level_3
            assign sum_level_3[sum_index_3] =
                $signed({sum_level_2[sum_index_3 * 2][17],
                         sum_level_2[sum_index_3 * 2]}) +
                $signed({sum_level_2[sum_index_3 * 2 + 1][17],
                         sum_level_2[sum_index_3 * 2 + 1]});
        end
    endgenerate

    assign sum_level_4[0] = $signed({sum_level_3[0][18], sum_level_3[0]})
                          + $signed({sum_level_3[1][18], sum_level_3[1]});
    assign sum_level_4[1] = $signed({sum_level_3[2][18], sum_level_3[2]})
                          + $signed({sum_level_3[3][18], sum_level_3[3]});
    assign sum_level_5 = $signed({sum_level_4[0][19], sum_level_4[0]})
                       + $signed({sum_level_4[1][19], sum_level_4[1]});

    // Register the completed 32-partial sum at the audio-sample boundary.
    // This separates the adder tree from effects/PT8211 logic while adding
    // only one 48 kHz sample of latency.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            mixed_sample <= 16'sd0;
        else if ((!CE_ENABLE || clock_enable)) if (sample_strobe)
            mixed_sample <= saturate_21(sum_level_5);
    end

    assign sample = mixed_sample;
    assign all_partials_active = (active_partial_count == 6'd32) &&
                                 (&partial_active);

    function signed [15:0] saturate_21;
        input signed [20:0] value;
        begin
            if (value > 21'sd32767)
                saturate_21 = 16'sh7fff;
            else if (value < -21'sd32768)
                saturate_21 = -16'sd32768;
            else
                saturate_21 = value[15:0];
        end
    endfunction

endmodule

`default_nettype wire
