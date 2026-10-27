`timescale 1ns/1ps
module tb_i2c_register;
    reg clk=0,reset_n=0,request=0,reading=1;
    always #10 clk=~clk;
    tri1 scl,sda;
    reg slave_sda_low=0,stretch_low=0;
    wire scl_low,sda_low,busy,done,error;
    wire [79:0] result;
    reg [15:0] address=16'h8140;
    reg [3:0] length=10;
    assign scl=(scl_low || stretch_low)?1'b0:1'bz;
    assign sda=(sda_low || slave_sda_low)?1'b0:1'bz;
    i2c_register_master #(.HALF_CYCLES(250),.TIMEOUT_CYCLES(6000)) dut (
        .clk(clk),.reset_n(reset_n),.request(request),.read_not_write(reading),
        .register_address(address),.read_length(length),.write_data(8'h00),
        .scl_in(scl),.sda_in(sda),.scl_low(scl_low),.sda_low(sda_low),
        .busy(busy),.done(done),.error(error),.read_data(result)
    );
    `include "gt911_bus_tasks.vh"
    time last_rise=0,last_fall=0;
    reg monitor=0;
    always @(posedge scl) begin
        if (monitor && last_fall!=0 && $time-last_fall<5000) $fatal(1,"SCL low <5us");
        last_rise=$time;
    end
    always @(negedge scl) begin
        if (monitor && last_rise!=0 && $time-last_rise<5000) $fatal(1,"SCL high <5us");
        last_fall=$time;
    end
    task launch;
        begin @(negedge clk);request=1;@(negedge clk);request=0; end
    endtask
    task finish_check;
        input expected_error;
        begin wait(done);#1;if(error!==expected_error) $fatal(1,"Wrong completion status"); end
    endtask
    initial begin
        #100;reset_n=1;monitor=1;
        fork
            begin launch;finish_check(0);end
            serve_read(16'h8140,10,80'h02580400123400313139);
            begin wait(scl_low);@(negedge clk);stretch_low=1;repeat(400) @(negedge clk);stretch_low=0;end
        join
        if(result!==80'h02580400123400313139) $fatal(1,"Read byte order");
        reading=0;address=16'h814e;
        fork begin launch;finish_check(0);end serve_clear; join
        fork
            begin launch;finish_check(1);end
            begin bus_start;receive_byte(8'hba,0);bus_stop;end
        join
        monitor=0;stretch_low=1;
        launch;finish_check(1);
        if(scl_low || sda_low) $fatal(1,"Timeout retained bus");
        stretch_low=0;
        // Stuck SDA is bounded as well; START must not clock a false address.
        slave_sda_low=1;launch;finish_check(1);slave_sda_low=0;
        fork begin launch;finish_check(0);end serve_clear; join
        reading=1;length=0;launch;finish_check(1);
        $display("PASS: I2C 100kHz timing, repeated START, byte order, ACK/NACK, stretch, stuck bus, retry");
        $finish;
    end
    initial begin #10000000;$fatal(1,"Watchdog");end
endmodule
