`timescale 1ns/1ps
`default_nettype none

module tb_p2_audio;

    reg clk;
    reg reset_n;
    reg dds_sample_strobe;
    reg signed [15:0] tx_sample;

    wire signed [15:0] dds_sample;
    wire tx_sample_strobe;
    wire audio_bck;
    wire audio_ws;
    wire audio_din;
    wire stream_ready;

    integer error_count;
    integer bit_number;
    integer silent_bit_count;
    integer bck_edge_count;
    time last_bck_edge_time;
    reg expected_bit;

    dds_tone_generator u_dds_tone_generator (
        .clk          (clk),
        .reset_n      (reset_n),
        .sample_strobe(dds_sample_strobe),
        .sample       (dds_sample)
    );

    pt8211_tx u_pt8211_tx (
        .audio_clk    (clk),
        .reset_n      (reset_n),
        .sample_in    (tx_sample),
        .sample_strobe(tx_sample_strobe),
        .audio_bck    (audio_bck),
        .audio_ws     (audio_ws),
        .audio_din    (audio_din),
        .stream_ready (stream_ready)
    );

    always #5 clk = ~clk;

    always @(negedge audio_bck) begin
        if (reset_n && !stream_ready) begin
            silent_bit_count = silent_bit_count + 1;
            if (audio_din !== 1'b0) begin
                $display("ERROR: non-zero startup sample at bit %0d", silent_bit_count);
                error_count = error_count + 1;
            end
        end
    end

    always @(audio_bck) begin
        if (reset_n) begin
            if ((bck_edge_count > 0) && (($time - last_bck_edge_time) != 160)) begin
                $display("ERROR: BCK half-period is %0t, expected 160 ns", $time - last_bck_edge_time);
                error_count = error_count + 1;
            end
            last_bck_edge_time = $time;
            bck_edge_count = bck_edge_count + 1;
        end
    end

    task pulse_dds_sample;
        begin
            dds_sample_strobe = 1'b1;
            @(posedge clk);
            #1;
            dds_sample_strobe = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_n = 1'b0;
        dds_sample_strobe = 1'b0;
        tx_sample = 16'hA5C3;
        error_count = 0;
        silent_bit_count = 0;
        bck_edge_count = 0;
        last_bck_edge_time = 0;

        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        #1;

        if (dds_sample !== 16'sd0) begin
            $display("ERROR: DDS reset sample is %0d, expected 0", dds_sample);
            error_count = error_count + 1;
        end

        repeat (12) pulse_dds_sample();
        if (dds_sample < 16'sd8000) begin
            $display("ERROR: DDS quarter-cycle sample is %0d", dds_sample);
            error_count = error_count + 1;
        end

        repeat (12) pulse_dds_sample();
        if ((dds_sample < -16'sd100) || (dds_sample > 16'sd100)) begin
            $display("ERROR: DDS half-cycle sample is %0d", dds_sample);
            error_count = error_count + 1;
        end

        wait (stream_ready === 1'b1);
        if (silent_bit_count != 2048) begin
            $display("ERROR: observed %0d silent bits, expected 2048", silent_bit_count);
            error_count = error_count + 1;
        end

        for (bit_number = 0; bit_number < 32; bit_number = bit_number + 1) begin
            @(negedge audio_bck);
            #1;
            if (bit_number < 16)
                expected_bit = tx_sample[15 - bit_number];
            else
                expected_bit = tx_sample[31 - bit_number];

            if (audio_ws !== (bit_number >= 16)) begin
                $display("ERROR: WS mismatch at frame bit %0d", bit_number);
                error_count = error_count + 1;
            end
            if (audio_din !== expected_bit) begin
                $display("ERROR: DIN mismatch at frame bit %0d", bit_number);
                error_count = error_count + 1;
            end
        end

        if (error_count == 0)
            $display("PASS: DDS and PT8211 startup/frame checks passed");
        else
            $display("FAIL: DDS and PT8211 found %0d errors", error_count);

        $finish;
    end

endmodule

`default_nettype wire
