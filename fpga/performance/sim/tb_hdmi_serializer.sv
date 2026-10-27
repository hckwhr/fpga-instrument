`timescale 1ns/1ps
// Uses the generated PLL and unmodified gw5a primitive models.
module tb_hdmi_serializer;
    reg sys_clk=0,pll_reset=1;
    always #10 sys_clk=~sys_clk;
    wire serial_clk,pixel_clk,locked;
    GSR GSR(.GSRI(1'b1));
    wire video_locked;
    // Single PLL: the 1080p30 cascade is gone, so sys_clk feeds the video PLL
    // directly and its lock is the only lock.
    hdmi_pll_MOD pll(.clkin(sys_clk),.reset(pll_reset),.icpsel(6'd0),
        .lpfres(3'd0),.lpfcap(2'd0),.clkout0(serial_clk),.clkout1(pixel_clk),.clkout2(),.lock(video_locked));
    assign locked=video_locked;
    realtime last_pixel=0,last_serial=0;
    integer serial_edges=0,pixel_checks=0,ratio_periods=0;
    realtime phase_error;
    // 180 MHz divides 36 MHz by exactly 5, but 5.5555... ns is a repeating
    // decimal, so at finite resolution the coincident serial edge drifts a few
    // ps either side of the pixel edge. The counter is therefore never reset
    // (resetting it discards edges that arrive inside the sampling window) and
    // the ratio is checked cumulatively, which a wrong ratio cannot satisfy.
    always @(posedge serial_clk) if(locked)begin
        last_serial=$realtime;
        serial_edges=serial_edges+1;
    end
    always @(posedge pixel_clk)begin
        #0.002;
        if(locked && last_pixel!=0)begin
            if($realtime-last_pixel<27.777 || $realtime-last_pixel>27.779)
                $fatal(1,"PLL pixel period=%f",$realtime-last_pixel);
            pixel_checks=pixel_checks+1;
            ratio_periods=ratio_periods+1;
            if(serial_edges>5*ratio_periods+8 || serial_edges<5*ratio_periods-8)
                $fatal(1,"PLL cumulative ratio drifted edges=%0d periods=%0d",
                       serial_edges,ratio_periods);
            // Phase alignment means a serial edge coincides with the pixel
            // edge; measure the distance to the nearest one, on either side.
            phase_error=$realtime-last_serial;
            while(phase_error>=5.5555556) phase_error=phase_error-5.5555556;
            if(phase_error>0.05 && phase_error<5.5055556)
                $fatal(1,"PLL outputs are not phase aligned residue=%f pixel=%f serial=%f",phase_error,$realtime,last_serial);
        end
        last_pixel=locked ? $realtime : 0;
        // Only the ratio baseline restarts on relock; pixel_checks is the
        // run-long total the final assertion needs.
        if(!locked || last_pixel==0)begin serial_edges=0;ratio_periods=0;end
    end
    always @(negedge locked)last_pixel=0;
    reg [1:0] reset_sync=0;
    reg [1:0] serializer_reset_sync=0;
    wire reset_n=reset_sync[1];
    wire serializer_reset_n=serializer_reset_sync[1];
    always @(posedge pixel_clk or negedge locked)
        if(!locked)reset_sync<=0;else reset_sync<={reset_sync[0],1'b1};
    always @(negedge pixel_clk or negedge locked)
        if(!locked)serializer_reset_sync<=0;else serializer_reset_sync<={serializer_reset_sync[0],1'b1};
    reg de=0,hs=0,vs=0;
    reg [23:0] rgb=0;
    wire cp,cn;
    wire [2:0] dp,dn;
    hdmi_tmds_tx dut(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.reset_n(reset_n),.serializer_reset_n(serializer_reset_n),
        .de(de),.hsync(hs),.vsync(vs),.rgb(rgb),.clock_p(cp),.clock_n(cn),.data_p(dp),.data_n(dn));
    reg [29:0] expected[0:4095];
    integer count=0,stim=0;
    always @(posedge pixel_clk)begin
        if(reset_n)begin
            expected[count]={dut.symbols[2],dut.symbols[1],dut.symbols[0]};
            count=count+1;
            stim=stim+1;
            de<=stim%17<12;
            hs<=stim%4>=2;vs<=stim%4==1||stim%4==3;
            rgb<={8'(stim*11),8'(stim*7+19),8'(stim*13+31)};
        end else begin
            count=0;stim=0;de<=0;hs<=0;vs<=0;rgb<=0;
        end
    end
    integer epoch,word_index,matched,k,l,found,checked;
    reg [29:0] received;
    reg prev_clock;
    task automatic run_epoch;
        begin
            matched=-1;checked=0;prev_clock=0;
            while(checked<1000)begin
                // Find bit0 from the 1111100000 forwarded clock word.
                @(serial_clk);#0.001;
                if(reset_n && prev_clock===1'b1 && cp===1'b0)begin
                    received=0;
                    for(k=0;k<10;k++)begin
                        if(k!=0)begin @(serial_clk);#0.001;end
                        if(cp!==(k>=5)||cn!==!cp||dn!==~dp)
                            $fatal(1,"clock word or differential polarity k=%0d",k);
                        for(l=0;l<3;l++)received[l*10+k]=dp[l];
                    end
                    if(matched<0)begin
                        found=-1;
                        for(word_index=0;word_index<count;word_index++)
                            if(expected[word_index]===received)found=word_index;
                        // Start checking with a non-control pixel, so blanking
                        // duplicates cannot hide a skipped/doubled symbol.
                        if(found>=0 && received[9:0]!=10'b1101010100 &&
                           received[9:0]!=10'b0010101011 &&
                           received[9:0]!=10'b0101010100 &&
                           received[9:0]!=10'b1010101011) matched=found;
                    end else begin
                        matched=matched+1;
                        if(matched>=count || received!==expected[matched])
                            $fatal(1,"serializer sequence index=%0d exp=%h got=%h",matched,expected[matched],received);
                        checked=checked+1;
                    end
                end
                prev_clock=cp;
            end
        end
    endtask
    initial begin
        #200;pll_reset=0;
        wait(locked);
        run_epoch();
        #3;pll_reset=1;#200;pll_reset=0;
        wait(locked);
        run_epoch();
        if(pixel_checks<2000)$fatal(1,"PLL clock checks missing");
        $display("PASS: generated single PLL/OSER10, 2000 RGB/control words, 180/36MHz phase/ratio, LSB-first, differential/clock alignment, PLL reset restart");
        $finish;
    end
    initial begin #2000000;$fatal(1,"serializer timeout");end
endmodule
