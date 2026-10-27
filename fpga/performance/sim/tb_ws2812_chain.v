`timescale 1ns/1ps
module tb_ws2812_chain;
    reg clk=0, reset_n=0;
    reg [11:0] held_notes=12'h801;
    wire data_out, buffer_enable;
    reg [23:0] received, expected;
    realtime rise_time, low_start;
    integer lamp, bit_no;
    always #15 clk=~clk;
    ws2812_tx #(.STARTUP_CYCLES(4)) dut(.clk(clk),.reset_n(reset_n),
        .held_notes(held_notes),.data_out(data_out),.buffer_enable(buffer_enable));
    initial begin #10000000; $fatal(1,"WS2812 chain timeout"); end
    task frame;
        input [11:0] mask;
        input change_midway;
        begin
            for(lamp=0;lamp<36;lamp=lamp+1) begin
                received=0;
                for(bit_no=0;bit_no<24;bit_no=bit_no+1) begin
                    @(posedge data_out); rise_time=$realtime;
                    if(lamp==0 && bit_no==0 && rise_time-low_start<350000.0)
                        $fatal(1,"latch low interval too short: %0t",rise_time-low_start);
                    @(negedge data_out);
                    if($realtime-rise_time!=360.0 && $realtime-rise_time!=810.0)
                        $fatal(1,"illegal pulse");
                    received={received[22:0],($realtime-rise_time>600.0)};
                    low_start=$realtime;
                end
                expected=mask[lamp/3] ? 24'h100800 : 24'd0;
                if(received!==expected) $fatal(1,"lamp %0d: got %h expected %h",lamp,received,expected);
                if(change_midway && lamp==5) held_notes=12'h002;
            end
        end
    endtask
    initial begin
        #1; reset_n=0;
        repeat(3) @(negedge clk); reset_n=1;
        @(posedge buffer_enable); low_start=$realtime;
        frame(12'd0,0); // Always clear all 36 pixels first.
        frame(12'h801,1); // Update after six pixels: frame must not tear.
        frame(12'h002,0);
        held_notes=0;
        frame(12'd0,0); // Full black data, buffer remains enabled for latch.
        @(posedge data_out); #100; reset_n=0; #1;
        if(data_out!==0 || buffer_enable!==0) $fatal(1,"mid-bit reset unsafe");
        held_notes=12'hfff;
        repeat(3) @(negedge clk); reset_n=1;
        @(posedge buffer_enable); low_start=$realtime;
        frame(12'd0,0);
        $display("PASS: 36-pixel chain, 3 lamps/key, atomic updates, full black and reset recovery");
        $finish;
    end
endmodule
