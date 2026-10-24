`timescale 1ns/1ps
// Decode only the physical data pin; DUT counters are not used as evidence.
module ws2812_12_checker #(parameter integer SELF_TEST=0);
    reg clk=0, reset_n=0;
    reg [11:0] held_notes=12'h801;
    wire data_out, buffer_enable;
    integer pixel, bit_no, step_no, repeat_no;
    reg [23:0] received, expected, color;
    reg [11:0] mask;
    realtime rise_time, low_start, previous_rise;
    always #15 clk=~clk;
    ws2812_tx #(.STARTUP_CYCLES(4),.PIXELS_PER_KEY(1),
        .STARTUP_TEST_ENABLE(SELF_TEST),.TEST_FRAMES_PER_STEP(2)) dut(
        .clk(clk),.reset_n(reset_n),.held_notes(held_notes),
        .data_out(data_out),.buffer_enable(buffer_enable));
    initial begin #40000000; $fatal(1,"12-pixel timeout"); end
    task frame;
        input [11:0] notes;
        input [23:0] grb;
        input change_midway;
        begin
            previous_rise=0;
            for(pixel=0;pixel<12;pixel=pixel+1) begin
                received=0;
                for(bit_no=0;bit_no<24;bit_no=bit_no+1) begin
                    @(posedge data_out); rise_time=$realtime;
                    if(buffer_enable!==1) $fatal(1,"data with buffer disabled");
                    if(pixel==0 && bit_no==0) begin
                        // Extra pixels would put the next edge only 1.26 us away.
                        if(rise_time-low_start<350000.0) $fatal(1,"not a 12-pixel frame / latch too short");
                    end else if(rise_time-previous_rise!=1260.0) $fatal(1,"bit period changed");
                    previous_rise=rise_time;
                    @(negedge data_out);
                    if($realtime-rise_time!=360.0 && $realtime-rise_time!=810.0) $fatal(1,"illegal pulse");
                    received={received[22:0],($realtime-rise_time>600.0)};
                    low_start=$realtime;
                end
                expected=notes[pixel] ? grb : 24'd0;
                if(received!==expected) $fatal(1,"pixel %0d got %h expected %h",pixel,received,expected);
                if(change_midway && pixel==2) held_notes=12'h002;
            end
        end
    endtask
    initial begin
        #1; reset_n=0;
        repeat(3) @(negedge clk); reset_n=1;
        @(posedge buffer_enable); low_start=$realtime;
        frame(0,0,0);
        if(SELF_TEST) begin
            for(step_no=0;step_no<15;step_no=step_no+1) begin
                mask=step_no<3 ? 12'hfff : 12'b1 << (step_no-3);
                color=step_no==0 ? 24'h001000 : step_no==1 ? 24'h100000 :
                      step_no==2 ? 24'h000010 : 24'h101010;
                for(repeat_no=0;repeat_no<2;repeat_no=repeat_no+1) frame(mask,color,0);
            end
        end
        frame(12'h801,24'h100800,1);
        frame(12'h002,24'h100800,0);
        // Check every position through the normal held-note input too.
        for(step_no=0;step_no<12;step_no=step_no+1) begin
            held_notes=12'b1 << step_no;
            frame(held_notes,24'h100800,0);
        end
        held_notes=0; frame(0,0,0);
        @(posedge data_out); #100; reset_n=0; #1;
        if(data_out!==0 || buffer_enable!==0) $fatal(1,"unsafe reset");
        repeat(3) @(negedge clk); reset_n=1;
        @(posedge buffer_enable); low_start=$realtime;
        frame(0,0,0);
        frame(SELF_TEST ? 12'hfff : 12'd0,SELF_TEST ? 24'h001000 : 24'd0,0);
        $display("PASS: 12 pixels, 288 bits/frame, RGB startup=%0d, all positions, atomic update, reset",SELF_TEST);
        $finish;
    end
endmodule
module tb_ws2812_12_chain;
    ws2812_12_checker #(.SELF_TEST(0)) checker_inst();
endmodule
module tb_ws2812_12_startup;
    ws2812_12_checker #(.SELF_TEST(1)) checker_inst();
endmodule
