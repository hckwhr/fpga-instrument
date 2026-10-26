`timescale 1ns/1ps
module tb_gt911_reset;
    reg clk=0,reset_n=0;
    always #10 clk=~clk;
    tri1 scl,sda;
    wire scl_low,sda_low,rst_n,int_low,online,down,update;
    wire [9:0] x,y;
    wire [2:0] count;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=sda_low?1'b0:1'bz;
    // 1 ms = 100 clocks here. Same production counters, scaled clock parameter.
    gt911_touch #(.CYCLES_PER_MS(100),.I2C_HALF_CYCLES(8),.I2C_TIMEOUT_CYCLES(1000)) dut (
        .clk(clk),.reset_n(reset_n),.scl_in(scl),.sda_in(sda),
        .scl_low(scl_low),.sda_low(sda_low),.touch_reset_n(rst_n),.int_low(int_low),
        .online(online),.down(down),.x(x),.y(y),.touch_count(count),.update(update)
    );
    time reset_release,device_release,int_release;
    initial begin
        #100;reset_n=1;reset_release=$time;
        @(posedge rst_n);device_release=$time;
        if(device_release-reset_release<39980 || !int_low) $fatal(1,"Reset/address setup too short");
        @(negedge int_low);int_release=$time;
        if(int_release-device_release<120000) $fatal(1,"INT sync <60ms");
        @(negedge sda);
        if($time-int_release<200000) $fatal(1,"Boot guard <100ms");
        // No slave: probe must NACK, release touch, then repeat full reset.
        @(negedge rst_n);#1;
        if(online || down || !int_low) $fatal(1,"Missing device not safe");
        @(posedge rst_n);
        // Reset during startup is immediate and restarts the whole interval.
        @(negedge clk);reset_n=0;#1;
        if(rst_n || !int_low || scl_low || sda_low) $fatal(1,"Reset outputs");
        $display("PASS: GT911 20/60/100ms address/reset sequence, INT release, absent-device retry");$finish;
    end
    initial begin #3000000;$fatal(1,"Watchdog");end
endmodule
