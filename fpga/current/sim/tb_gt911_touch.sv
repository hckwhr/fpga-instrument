`timescale 1ns/1ps
module tb_gt911_touch;
    reg clk=0,reset_n=0;
    always #10 clk=~clk;
    tri1 scl,sda;
    reg slave_sda_low=0;
    wire scl_low,sda_low,rst_n,int_low,online,down,update;
    wire [9:0] x,y;
    wire [2:0] count;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=(sda_low || slave_sda_low)?1'b0:1'bz;
    gt911_touch #(.CYCLES_PER_MS(20),.I2C_HALF_CYCLES(8),.I2C_TIMEOUT_CYCLES(1000)) dut (
        .clk(clk),.reset_n(reset_n),.scl_in(scl),.sda_in(sda),
        .scl_low(scl_low),.sda_low(sda_low),.touch_reset_n(rst_n),.int_low(int_low),
        .online(online),.down(down),.x(x),.y(y),.touch_count(count),.update(update)
    );
    `include "gt911_bus_tasks.vh"
    task expect_touch;
        input expected_down;
        input [9:0] expected_x,expected_y;
        input [2:0] expected_count;
        begin
            @(posedge update);#1;
            if(down!==expected_down || count!==expected_count ||
                (expected_down && (x!==expected_x || y!==expected_y)))
                $fatal(1,"Touch mismatch down=%b x=%d y=%d count=%d",down,x,y,count);
        end
    endtask
    task event_packet;
        input [7:0] status;
        input [15:0] px,py;
        input [2:0] expected_count;
        begin
            serve_read(16'h814e,1,{72'd0,status});
            if(!status[6] && status[3:0]>=1 && status[3:0]<=5)
                serve_read(16'h814f,8,{16'd0,8'd0,16'd10,py,px,8'd0});
            fork
                serve_clear;
                expect_touch(expected_count!=0,px[9:0],py[9:0],expected_count);
            join
        end
    endtask
    integer i;
    initial begin
        #100;reset_n=1;
        serve_read(16'h8140,10,80'h02580400123400313139);
        wait(online);
        // A coordinate is not published if acknowledging the buffer fails.
        serve_read(16'h814e,1,80'h81);
        serve_read(16'h814f,8,{16'd0,8'd0,16'd10,16'd300,16'd512,8'd0});
        fork
            begin
                bus_start;receive_byte(8'hba,1);receive_byte(8'h81,1);
                receive_byte(8'h4e,1);receive_byte(8'h00,0);bus_stop;
            end
            expect_touch(0,0,0,0);
        join
        if(online) $fatal(1,"Failed clear still online");
        serve_read(16'h8140,10,80'h02580400123400313139);
        wait(online);
        event_packet(8'h81,16'd512,16'd300,1);
        event_packet(8'h85,16'd1023,16'd599,5);
        event_packet(8'h80,0,0,0); // release must clear status too
        event_packet(8'h81,16'd1024,16'd600,0); // no truncation/wrap
        event_packet(8'h86,0,0,0); // invalid count
        event_packet(8'hc1,0,0,0); // large-area detect
        event_packet(8'h81,0,0,1); // origin is valid
        fork
            begin for(i=0;i<20;i=i+1) serve_read(16'h814e,1,80'd0); end
            expect_touch(0,0,0,0);
        join
        event_packet(8'h81,16'd128,16'd64,1);
        // Disconnect during next status poll: NACK -> STOP -> safe release/reset.
        fork
            begin bus_start;receive_byte(8'hba,0);bus_stop;end
            begin expect_touch(0,0,0,0);if(online) $fatal(1,"Disconnected still online");end
        join
        wait(!rst_n);
        // Wrong resolution is rejected, never overwrites factory config.
        serve_read(16'h8140,10,80'h03200500123400313139);
        repeat(10) @(posedge clk);
        if(online || down) $fatal(1,"Wrong panel accepted");
        serve_read(16'h8140,10,80'h02580400123400313139);
        wait(online);event_packet(8'h81,16'd900,16'd500,1);
        $display("PASS: GT911 probe, coordinates, 5 touches, release, bad range/count, stale state, disconnect/reprobe");
        $finish;
    end
    initial begin #10000000;$fatal(1,"Watchdog");end
endmodule
