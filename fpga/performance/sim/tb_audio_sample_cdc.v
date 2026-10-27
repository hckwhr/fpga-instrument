`timescale 1ns/1ps
`default_nettype none

module tb_audio_sample_cdc;

    reg src_clk;
    reg dst_clk;
    reg src_reset_n;
    reg dst_reset_n;
    reg signed [15:0] src_sample;
    reg src_sample_strobe;

    wire signed [15:0] dst_sample;
    wire dst_sample_valid;

    integer error_count;
    integer transfer_index;
    reg signed [15:0] expected_sample;

    audio_sample_cdc u_dut (
        .src_clk          (src_clk),
        .src_reset_n      (src_reset_n),
        .src_sample       (src_sample),
        .src_sample_strobe(src_sample_strobe),
        .dst_clk          (dst_clk),
        .dst_reset_n      (dst_reset_n),
        .dst_sample       (dst_sample),
        .dst_sample_valid (dst_sample_valid)
    );

    always #7 src_clk = ~src_clk;
    always #5 dst_clk = ~dst_clk;

    task send_and_check;
        input signed [15:0] value;
        begin
            repeat (8) @(posedge src_clk);
            src_sample = value;
            src_sample_strobe = 1'b1;
            @(posedge src_clk);
            #1;
            src_sample_strobe = 1'b0;
            expected_sample = value;

            wait (dst_sample_valid === 1'b1);
            #1;
            if (dst_sample !== expected_sample) begin
                $display("ERROR: CDC sample %0d, expected %0d", dst_sample, expected_sample);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        src_clk = 1'b0;
        dst_clk = 1'b0;
        src_reset_n = 1'b0;
        dst_reset_n = 1'b0;
        src_sample = 16'sd0;
        src_sample_strobe = 1'b0;
        expected_sample = 16'sd0;
        error_count = 0;

        repeat (5) @(posedge dst_clk);
        src_reset_n = 1'b1;
        dst_reset_n = 1'b1;

        for (transfer_index = 0; transfer_index < 8; transfer_index = transfer_index + 1)
            send_and_check(-16'sd7000 + transfer_index * 16'sd2000);

        if (error_count == 0)
            $display("PASS: audio sample CDC handshake transferred all samples");
        else
            $display("FAIL: audio sample CDC found %0d errors", error_count);

        $finish;
    end

endmodule

`default_nettype wire
