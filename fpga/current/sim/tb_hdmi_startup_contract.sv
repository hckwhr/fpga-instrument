`timescale 1ns/1fs
// Uses the official OSER10 model. The clock-stopped startup is gone: FCLK now
// runs continuously, so this checks the contract that replaced it.
//
//  - FCLK must never stop, least of all around a reset. A TMDS sink holds lock
//    from the clock lane, and gating it was what made the picture drop out.
//  - RESET must stay asserted long enough before release. The RTL holds it for
//    16 PCLK, which at 36 MHz is 444.4 ns.
//  - The release edge must be a falling PCLK edge, so the OSER10 RESET path is
//    captured cleanly.
//
// The negative control forces an early release and the same observer must
// report it, proving the check can fail.
module tb_hdmi_startup_contract;
    reg pixel_clk=0,serial_clk=0,reset_n=0;
    always #13.888888889 pixel_clk=~pixel_clk;
    always #2.777777778 serial_clk=~serial_clk;
    GSR GSR(.GSRI(1'b1));
    hdmi_tmds_tx dut(.pixel_clk(pixel_clk),.serial_clk(serial_clk),
        .reset_n(reset_n),.serializer_reset_n(reset_n),.de(1'b0),
        .hsync(1'b0),.vsync(1'b0),.rgb(24'd0),
        .clock_p(),.clock_n(),.data_p(),.data_n());
    realtime asserted_at=0,last_serial_edge=0,longest_serial_gap=0,gap;
    integer violations=0,positive_epochs=0,epoch;
    reg negative=0;
    // Track the largest gap between FCLK edges over the whole run. A free
    // running 180 MHz clock must never exceed half a period by any margin.
    always @(dut.gated_serial_clk)begin
        if(last_serial_edge!=0)begin
            gap=$realtime-last_serial_edge;
            if(gap>longest_serial_gap)longest_serial_gap=gap;
        end
        last_serial_edge=$realtime;
    end
    always @(negedge reset_n)asserted_at=$realtime;
    always @(posedge dut.serializer_release_n)begin
        // 16 PCLK at 36 MHz is 444.4 ns; allow for the reset being asserted
        // asynchronously part way through a cycle.
        if($realtime-asserted_at<430.0)begin
            violations++;
            if(!negative)
                $fatal(1,"RESET released after only %f ns",$realtime-asserted_at);
        end else if(!negative)positive_epochs++;
        // Release is timed off the falling PCLK edge.
        if(pixel_clk!==1'b0)begin
            violations++;
            if(!negative)$fatal(1,"RESET released off a rising PCLK edge");
        end
    end
    initial begin
        #0.1;reset_n=0;
        for(epoch=0;epoch<12;epoch++)begin
            #(17.3+epoch*0.731);reset_n=1;
            wait(dut.serializer_release_n);repeat(20)@(posedge pixel_clk);
            #0.317;reset_n=0;
        end
        if(positive_epochs!=12 || violations!=0)
            $fatal(1,"Startup phase sweep incomplete epochs=%0d violations=%0d",
                   positive_epochs,violations);
        if(longest_serial_gap>2.9)
            $fatal(1,"FCLK stopped: longest gap %f ns",longest_serial_gap);
        // Negative control: release RESET far too early. The same observer must
        // catch it, which shows the timing check is actually load bearing.
        negative=1;#17.91;reset_n=1;
        wait(dut.startup_count==6'd4);
        force dut.serializer_release_n=1'b1;
        repeat(8)@(posedge serial_clk);
        if(violations==0)$fatal(1,"Early-release negative control was not detected");
        release dut.serializer_release_n;reset_n=0;
        $display("PASS: 12 reset phase sweeps, RESET held >=16 PCLK and released on falling PCLK, FCLK free running (longest gap %f ns), early-release negative control detected",longest_serial_gap);
        $finish;
    end
    initial begin #40000;$fatal(1,"HDMI startup contract timeout");end
endmodule
