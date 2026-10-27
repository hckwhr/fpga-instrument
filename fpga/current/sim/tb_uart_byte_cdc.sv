`timescale 1ns/1ps
module tb_uart_byte_cdc;
    reg src_clk=0,dst_clk=0,reset_n=0,running=1;
    always #10 src_clk=~src_clk;
    initial begin #3; forever begin #13;if(running)dst_clk=~dst_clk;end end
    reg [1:0] sr=0,dr=0;
    always @(posedge src_clk or negedge reset_n)if(!reset_n)sr<=0;else sr<={sr[0],1'b1};
    always @(posedge dst_clk or negedge reset_n)if(!reset_n)dr<=0;else dr<={dr[0],1'b1};
    reg [7:0] src_data=0;
    reg src_valid=0,dst_ready=0;
    wire src_ready,dst_valid;
    wire [7:0] dst_data;
    integer count=0;
    reg [7:0] expected=0;
    uart_byte_cdc dut(.src_clk(src_clk),.src_reset_n(sr[1]),.src_data(src_data),.src_valid(src_valid),.src_ready(src_ready),
        .dst_clk(dst_clk),.dst_reset_n(dr[1]),.dst_data(dst_data),.dst_valid(dst_valid),.dst_ready(dst_ready));
    always @(posedge dst_clk)if(dr[1] && dst_valid && dst_ready)begin
        if(dst_data!==expected)$fatal(1,"CDC corruption %h expected %h",dst_data,expected);
        count++;
    end
    task send(input [7:0] value);
        begin @(negedge src_clk);wait(src_ready);src_data=value;src_valid=1;
        @(negedge src_clk);src_valid=0;src_data=~value;end
    endtask
    task reset;
        begin reset_n=0;src_valid=0;dst_ready=0;repeat(4)@(negedge src_clk);reset_n=1;repeat(8)@(negedge src_clk);end
    endtask
    initial begin
        reset();
        for(integer i=0;i<256;i++)begin
            expected=i;send(i);wait(dst_valid);
            repeat(5)begin @(negedge src_clk);if(src_ready || !dst_valid || dst_data!==expected)$fatal(1,"stalled byte changed");end
            @(negedge dst_clk);dst_ready=1;wait(src_ready);@(negedge dst_clk);dst_ready=0;
        end
        if(count!=256)$fatal(1,"lost/duplicated bytes");
        @(negedge dst_clk);running=0;expected=8'ha5;send(8'ha5);
        repeat(50)@(negedge src_clk);if(src_ready || count!=256)$fatal(1,"ACK while destination clock stopped");
        running=1;wait(dst_valid);@(negedge dst_clk);dst_ready=1;wait(src_ready);
        if(count!=257)$fatal(1,"paused transfer lost");
        @(negedge dst_clk);dst_ready=0;send(8'h55);wait(dst_valid);reset();
        dst_ready=1;repeat(20)@(negedge src_clk);if(count!=257 || dst_valid)$fatal(1,"reset ghost byte");
        expected=8'hfe;send(8'hfe);wait(src_ready);if(count!=258)$fatal(1,"reset recovery");
        $display("PASS: byte CDC all values, backpressure stability, clock pause, reset in flight and exactly-once recovery");$finish;
    end
    initial begin #2000000;$fatal(1,"byte CDC timeout");end
endmodule
