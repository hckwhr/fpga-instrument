`timescale 1ns/1ps
module tb_v3_performance_input;
    reg sys_clk=0,audio_clk=0,sys_reset_n=0,audio_reset_n=0,running=1;
    always #10 if(running)sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    reg [9:0] divider=0;
    always @(posedge audio_clk)divider<=divider+1'b1;
    wire sample_strobe=divider==0;
    reg [15:0] pressed=0;
    reg [9:0] fp=500,xp=503,yp=529;
    wire sclk,mosi,cs,miso,load_n,key_clk,serial_data,gate,ready,calibrated;
    wire [15:0] keys;
    wire [6:0] force_value;
    wire signed [7:0] bend;
    wire [7:0] vibrato;
    wire [9:0] zero,xc,yc;
    v3_performance_input #(.SPI_DIV(5),.SCAN_IDLE_CYCLES(200),.SETTLE_FRAMES(2),.CALIBRATION_LOG2(3)) dut(
        .sys_clk(sys_clk),.sys_reset_n(sys_reset_n),.audio_clk(audio_clk),.audio_reset_n(audio_reset_n),
        .sample_strobe(sample_strobe),.adc_miso(miso),.key_serial(serial_data),.manual_force(7'd96),.manual_vibrato(2'd0),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs_n(cs),.key_load_n(load_n),.key_shift_clk(key_clk),.keys(keys),
        .force_value(force_value),.bend(bend),.vibrato_depth(vibrato),.pressure_gate(gate),.ready(ready),
        .calibrated(calibrated),.force_zero(zero),.x_center(xc),.y_center(yc));
    v3_key_model key_model(load_n,key_clk,pressed,serial_data);
    v3_adc_model adc_model(cs,sclk,mosi,fp,xp,yp,miso);
    task samples(input integer n);repeat(n)begin @(posedge sample_strobe);@(negedge audio_clk);end endtask
    initial begin
        repeat(10)@(negedge sys_clk);sys_reset_n=1;audio_reset_n=1;
        samples(60);if(ready || calibrated)$fatal(1,"calibrated under pressure");
        fp=92;pressed=16'h1;samples(60);if(ready)$fatal(1,"calibrated with key held");
        pressed=0;wait(ready);samples(4);
        if(zero!==92 || xc!==503 || yc!==529 || keys!==0 || bend!==0 || gate)$fatal(1,"calibration value error");
        pressed=16'h4891;fp=320;xp=950;yp=950;samples(160);
        if(keys!==pressed || !gate || force_value<90 || bend<85 || vibrato<85)$fatal(1,"multidimensional input missing");
        fp=92;pressed=0;xp=50;yp=529;samples(300);
        if(keys!==0 || gate || bend> -85 || vibrato!==0)$fatal(1,"release or negative bend missing");
        running=0;samples(260);
        if(ready || keys!==0 || gate)$fatal(1,"stale sys domain keys remain active");
        running=1;wait(ready);samples(150);if(bend> -85)$fatal(1,"clock recovery failed");
        audio_reset_n=0;#1;if(calibrated!==0 || keys!==0)$fatal(1,"coupled reset failed");
        $display("PASS: real SPI/165, blocked nonidle calibration, averaged zero/XY, force/bend/vibrato, coherent keys, timeout and coupled reset");$finish;
    end
    initial begin #50000000;$fatal(1,"V3 input timeout");end
endmodule
