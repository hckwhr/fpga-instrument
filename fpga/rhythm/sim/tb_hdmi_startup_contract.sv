`timescale 1ns/1fs
// Uses the official DHCE/OSER10 models, including the four-stage CEN path.
module tb_hdmi_startup_contract;
    reg pixel_clk=0,serial_clk=0,reset_n=0;
    always #6.734006734 pixel_clk=~pixel_clk;
    always #1.346801347 serial_clk=~serial_clk;
    GSR GSR(.GSRI(1'b1));
    hdmi_tmds_tx dut(.pixel_clk(pixel_clk),.serial_clk(serial_clk),
        .reset_n(reset_n),.serializer_reset_n(reset_n),.de(1'b0),
        .hsync(1'b0),.vsync(1'b0),.rgb(24'd0),
        .clock_p(),.clock_n(),.data_p(),.data_n());
    realtime released_at=0,last_serial_edge=0;
    integer violations=0,positive_epochs=0,epoch;
    reg waiting_first=0,negative=0;
    always @(dut.gated_serial_clk) last_serial_edge=$realtime;
    always @(negedge reset_n)waiting_first=0;
    always @(posedge dut.serializer_release_n)begin
        released_at=$realtime;waiting_first=1;
        // Before release the DHCE must also have been closed long enough.
        if($realtime-last_serial_edge<180.0)begin
            violations++;
            if(!negative)$fatal(1,"FCLK was not quiescent before RESET release");
        end
    end
    always @(posedge dut.gated_serial_clk)begin
        if(dut.serializer_release_n && waiting_first)begin
            waiting_first=0;
            if($realtime-released_at<215.48)begin
                violations++;
                if(!negative)$fatal(1,"FCLK reopened too early: %f ns",$realtime-released_at);
            end else if(!negative)positive_epochs++;
        end
    end
    initial begin
        #0.1;reset_n=0;
        for(epoch=0;epoch<12;epoch++)begin
            #(17.3+epoch*0.731);reset_n=1;
            wait(dut.serial_running);repeat(20)@(posedge pixel_clk);
            #0.317;reset_n=0;
        end
        if(positive_epochs!=12 || violations!=0)$fatal(1,"Startup phase sweep incomplete");
        // Negative control: deliberately open FCLK BEFORE reset release. The
        // same observer must detect the violated quiet-clock prerequisite.
        negative=1;#17.91;reset_n=1;
        wait(dut.startup_count==6'd8);
        force dut.serial_running=1'b1;
        wait(dut.serializer_release_n);repeat(8)@(posedge serial_clk);
        if(violations==0)$fatal(1,"Negative clock-gating contract was not detected");
        reset_n=0;release dut.serial_running;
        $display("PASS: 12 reset phase sweeps, FCLK quiet before RESET release and >=215.488ns afterward; premature-clock negative control detected");
        $finish;
    end
    initial begin #20000;$fatal(1,"HDMI startup contract timeout");end
endmodule
