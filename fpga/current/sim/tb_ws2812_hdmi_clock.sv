`timescale 1ns/1ps
module tb_ws2812_hdmi_clock;
    reg clk=0,reset_n=0;
    always #13.888888889 clk=~clk;
    wire data_out,enabled;
    ws2812_tx #(.CLOCK_KHZ(36000),.STARTUP_CYCLES(4),.PIXELS_PER_KEY(1)) dut(
        .clk(clk),.reset_n(reset_n),.held_notes(12'hfff),
        .data_out(data_out),.buffer_enable(enabled));
    realtime rising,last_rising=0,last_falling=0;
    integer short_bits=0,long_bits=0;
    always @(posedge data_out)begin
        rising=$realtime;
        if(last_rising!=0 && rising-last_rising<10000 &&
           (rising-last_rising<1200 || rising-last_rising>1300))
            $fatal(1,"WS2812 bit period changed with HDMI clock");
        if(last_falling!=0 && rising-last_falling>10000 && rising-last_falling<300000)
            $fatal(1,"WS2812 reset latch is too short");
        last_rising=rising;
    end
    always @(negedge data_out)if(reset_n && rising!=0)begin
        if($realtime-rising>300 && $realtime-rising<450)short_bits++;
        else if($realtime-rising>700 && $realtime-rising<900)long_bits++;
        else $fatal(1,"WS2812 high pulse width=%f",$realtime-rising);
        last_falling=$realtime;
    end
    initial begin
        #1;reset_n=0;#40;reset_n=1;
        wait(long_bits>=10 && short_bits>=288);
        $display("PASS: production 36MHz render clock preserves WS2812 bit/high/reset timing, both zero and one bits checked");
        $finish;
    end
    initial begin #3000000;$fatal(1,"WS2812 HDMI timeout");end
endmodule
