`timescale 1ns/1ps
module tb_touch_preview;
    reg src_clk=0,clk=0,reset_n=0,frame_start=0,de=1;
    always #10 src_clk=~src_clk;
    always #15 clk=~clk;
    reg [24:0] source=0;
    wire [24:0] status;
    wire updated,overlay;
    wire [17:0] rgb;
    reg [10:0] px=600,py=100;
    status_bundle_cdc #(.WIDTH(25)) cdc (
        .src_clk(src_clk),.src_reset_n(reset_n),.src_payload(source),
        .dst_clk(clk),.dst_reset_n(reset_n),.dst_payload(status),.dst_update(updated)
    );
    touch_preview dut(.clk(clk),.reset_n(reset_n),.frame_start(frame_start),
        .data_enable(de),.pixel_x(px),.pixel_y(py),.touch_status(status),.overlay(overlay),.rgb(rgb));
    task frame;
        begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;end
    endtask
    task pixel;
        input [10:0] x,y;
        input enabled;
        input expected;
        begin
            @(negedge clk);px=x;py=y;de=enabled;
            repeat(2) @(posedge clk);#1;
            if(overlay!==expected) $fatal(1,"Overlay/latency mismatch at %d,%d",x,y);
        end
    endtask
    initial begin
        #100;reset_n=1;
        source={1'b1,1'b1,3'd1,10'd512,10'd300};
        wait(status===source);
        pixel(656,91,1,0); // no mid-frame update
        frame;pixel(656,91,1,1);
        if(rgb!==18'h3ffff) $fatal(1,"Single-touch color");
        pixel(650,90,1,0);pixel(656,91,0,0);pixel(528,50,1,1);
        source={1'b1,1'b1,3'd5,10'd1000,10'd500};
        wait(status===source);pixel(656,91,1,1);
        frame;pixel(656,91,1,0);pixel(778,141,1,1);
        if(rgb!==18'h3f000) $fatal(1,"Multi-touch color");
        source=0;wait(status===source);frame;pixel(528,50,1,0);
        $display("PASS: coherent CDC, frame commit, touch preview scale, DE and 2-cycle alignment");$finish;
    end
    initial begin #100000;$fatal(1,"Watchdog");end
endmodule
