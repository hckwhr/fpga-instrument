`timescale 1ns/1ps
`default_nettype none

module tb_additive_bank_32;

    localparam integer ACTIVATION_INTERVAL_SAMPLES = 4;

    reg clk;
    reg reset_n;
    reg sample_strobe;
    reg enable;
    wire signed [15:0] sample;
    wire all_partials_active;

    integer error_count;
    integer sample_index;
    integer sample_file;
    integer sample_abs;
    integer peak_sample;
    integer meter_full_samples;

    additive_bank_32 #(
        .ACTIVATION_INTERVAL_SAMPLES(ACTIVATION_INTERVAL_SAMPLES),
        .MASTER_GAIN(8'd64)
    ) u_dut (
        .clk                (clk),
        .reset_n            (reset_n),
        .sample_strobe      (sample_strobe),
        .enable             (enable),
        .sample             (sample),
        .all_partials_active(all_partials_active)
    );

    always #5 clk = ~clk;

    task clock_once;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task pulse_sample;
        begin
            sample_strobe = 1'b1;
            clock_once();
            sample_strobe = 1'b0;
        end
    endtask

    task expect;
        input condition;
        input [8*80-1:0] message;
        begin
            if (!condition) begin
                $display("ERROR: %0s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_n = 1'b0;
        sample_strobe = 1'b0;
        enable = 1'b0;
        error_count = 0;
        peak_sample = 0;
        meter_full_samples = 0;
        repeat (3) clock_once();
        reset_n = 1'b1;
        clock_once();
        expect(sample == 16'sd0, "reset output was not silent");

        enable = 1'b1;
        pulse_sample();
        expect(u_dut.active_partial_count == 6'd1,
               "first additive partial did not enter immediately");
        repeat (32) pulse_sample();
        expect((u_dut.active_partial_count > 6'd1) &&
               (u_dut.active_partial_count < 6'd32),
               "additive partials did not enter progressively");
        expect(u_dut.partial_active[0] &&
               !(u_dut.partial_active[31]),
               "progressive activation order was incorrect");

        repeat (128) pulse_sample();
        expect(u_dut.active_partial_count == 6'd32,
               "progressive activation did not reach 32 partials");
        expect(all_partials_active, "not all 32 additive partials became active");

        sample_file = $fopen("sim/additive_32_samples.txt", "w");
        expect(sample_file != 0, "failed to open additive sample output");
        for (sample_index = 0; sample_index < 65536;
             sample_index = sample_index + 1) begin
            pulse_sample();
            $fdisplay(sample_file, "%0d", sample);
            sample_abs = (sample < 0) ? -sample : sample;
            if (sample_abs > peak_sample)
                peak_sample = sample_abs;
            if (sample_abs >= 16384)
                meter_full_samples = meter_full_samples + 1;
        end
        $fclose(sample_file);

        expect(peak_sample > 1000, "32-partial output level was too low");
        expect(peak_sample < 9000, "32-partial mix exceeded safe headroom");
        expect(meter_full_samples == 0,
               "32-partial mix would pin the LCD level meter");

        enable = 1'b0;
        repeat (128) pulse_sample();
        expect(sample == 16'sd0, "32-partial bank did not release to zero");

        if (error_count == 0) begin
            $display("PASS: progressive 32-partial activation, safe mix headroom, mix tree, and release checks passed");
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d additive-bank checks failed", error_count);
        end
    end

endmodule

`default_nettype wire
