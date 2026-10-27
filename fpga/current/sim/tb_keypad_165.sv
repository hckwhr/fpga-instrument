`timescale 1ns/1ps
module tb_keypad_165;
    reg clk=0,reset_n=0;
    always #10 clk=~clk;
    reg [15:0] pressed=0;
    wire serial_data,load_n,shift_clk,valid,ready;
    wire [15:0] keys;
    keypad_165 #(.CLK_DIV_CYCLES(5),.SCAN_IDLE_CYCLES(50),.DEBOUNCE_FRAMES(4)) dut(
        .clk(clk),.reset_n(reset_n),.serial_data(serial_data),.load_n(load_n),.shift_clk(shift_clk),
        .keys(keys),.frame_valid(valid),.ready(ready));
    v3_key_model model(load_n,shift_clk,pressed,serial_data);
    task frames(input integer n);repeat(n)begin @(posedge valid);@(negedge clk);end endtask
    initial begin
        repeat(5)@(negedge clk);reset_n=1;frames(5);
        if(!ready || keys!==0)$fatal(1,"startup keys not released");
        for(integer i=0;i<16;i++)begin
            pressed=16'b1<<i;frames(5);
            if(keys!==pressed)$fatal(1,"165 mapping index %d got %h",i,keys);
            pressed=0;frames(5);if(keys!==0)$fatal(1,"release index %d",i);
        end
        // One sampled high frame followed by low must not pass debounce.
        pressed=16'hffff;frames(1);pressed=0;frames(5);
        if(keys!==0)$fatal(1,"bounce accepted");
        pressed=16'hffff;frames(5);if(keys!==16'hffff)$fatal(1,"full chord lost");
        reset_n=0;#1;if(load_n!==1 || shift_clk!==0 || keys!==0 || ready!==0)$fatal(1,"unsafe reset");
        $display("PASS: all 16 physical shift positions, initial H, chord, debounce, release, reset");$finish;
    end
    initial begin #5000000;$fatal(1,"key scanner timeout");end
endmodule
