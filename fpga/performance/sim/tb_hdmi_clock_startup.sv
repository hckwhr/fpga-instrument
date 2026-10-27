`timescale 1ns/1ps
// Exercise actual generated adaptive wrappers, not just their PLL primitives.
module tb_hdmi_clock_startup;
    reg sys_clk=0;
    always #10 sys_clk=~sys_clk;
    GSR GSR(.GSRI(1'b1));
    wire pixel_clk,serial_clk,locked;
    wire render_clk;
    hdmi_clocks dut(.sys_clk(sys_clk),.pixel_clk(pixel_clk),.serial_clk(serial_clk),.render_clk(render_clk),.locked(locked));
    realtime previous=0;
    integer edges=0;
    integer render_edges=0;
    realtime render_previous=0;
    always @(posedge render_clk)if(locked)begin
        if(render_previous!=0 && ($realtime-render_previous<27.777 || $realtime-render_previous>27.779))
            $fatal(1,"Official PLL render clock frequency incorrect");
        render_previous=$realtime;render_edges++;
    end
    always @(posedge serial_clk)if(locked)edges++;
    initial begin
        wait(locked===1'b1);
        repeat(3)@(posedge pixel_clk);
        #0.01;edges=0;previous=$realtime;
        repeat(1000)begin
            @(posedge pixel_clk);#0.01;
            if(!locked || edges!=5 || $realtime-previous<27.777 || $realtime-previous>27.779)
                $fatal(1,"Generated PLL wrapper startup/clock ratio failed");
            edges=0;previous=$realtime;
        end
        if(render_edges<500)$fatal(1,"Render PLL output did not start");
        $display("PASS: single production PLL wrapper locks at 36/180MHz, render clock shares PCLK, 1000 pixel cycles");
        $finish;
    end
    initial begin #20000000;$fatal(1,"Production HDMI clocks never locked");end
endmodule
