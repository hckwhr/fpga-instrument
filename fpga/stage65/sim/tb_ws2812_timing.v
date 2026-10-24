`timescale 1ns/1ps
module tb_ws2812_timing;
    reg clk=0, reset_n=0;
    wire data_out, buffer_enable;
    integer frame, bit_no, phase;
    reg expected_bit;
    reg [23:0] expected_word;
    realtime rise_time, fall_time, previous_rise;
    always #15 clk=~clk;
    ws2812_tx #(.ON_GRB(24'hA5963C), .STARTUP_CYCLES(4)) dut(
        .clk(clk), .reset_n(reset_n), .held_notes(12'hfff),
        .data_out(data_out), .buffer_enable(buffer_enable));
    initial begin #4000000; $fatal(1,"WS2812 timing timeout"); end
    initial begin
        #1; reset_n=0;
        repeat(3) @(negedge clk);
        if(data_out!==0 || buffer_enable!==0) $fatal(1,"unsafe reset outputs");
        reset_n=1;
        for(frame=0;frame<2;frame=frame+1) begin
            expected_word = frame==0 ? 24'd0 : 24'hA5963C;
            previous_rise=0;
            for(bit_no=0;bit_no<864;bit_no=bit_no+1) begin
                @(posedge data_out); rise_time=$realtime;
                if(buffer_enable!==1) $fatal(1,"data while buffer disabled");
                if(bit_no>0 && rise_time-previous_rise!=1260.0)
                    $fatal(1,"bit period %0t",rise_time-previous_rise);
                previous_rise=rise_time;
                expected_bit=expected_word[23-(bit_no%24)];
                // Sample all 42 clock cells independently of DUT counters.
                #1;
                for(phase=0;phase<42;phase=phase+1) begin
                    if(data_out !== (phase < (expected_bit ? 27 : 12)))
                        $fatal(1,"frame %0d bit %0d phase %0d",frame,bit_no,phase);
                    if(phase<41) #30;
                end
            end
        end
        @(negedge clk); reset_n=0; #1;
        if(data_out!==0 || buffer_enable!==0) $fatal(1,"reset failed");
        $display("PASS: WS2812 1728 bits, GRB/MSB order and every 30 ns cell checked");
        $finish;
    end
endmodule
