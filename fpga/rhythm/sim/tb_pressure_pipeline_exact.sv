`timescale 1ns/1ps
// Frozen pre-pipeline module is the oracle. Inject ONLY complete scanner
// transactions; physical SPI and downstream audio are covered by the retained
// analog, production-latency and HDMI pin suites.
module tb_pressure_pipeline_exact;
    reg sys_clk=0,audio_clk=0,rst=0,ce=0;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always @(negedge audio_clk)ce<=~ce;
    reg [159:0] raw_frame=0;
    reg valid=0;
    integer frames_checked=0,values_checked=0,k,g,d,n;
    v3_analog_input #(.CE_ENABLE(1),.SETTLE_FRAMES(2),.CALIBRATION_LOG2(3)) dut(
        .sys_clk(sys_clk),.audio_clk(audio_clk),.sys_reset_n(rst),.audio_reset_n(rst),
        .clock_enable(ce),.sample_strobe(1'b0),.adc_miso(1'b0),.manual_vibrato(2'd0));
    rhythm_baseline_analog #(.CE_ENABLE(1),.SETTLE_FRAMES(2),.CALIBRATION_LOG2(3)) refdut(
        .sys_clk(sys_clk),.audio_clk(audio_clk),.sys_reset_n(rst),.audio_reset_n(rst),
        .clock_enable(ce),.sample_strobe(1'b0),.adc_miso(1'b0),.manual_vibrato(2'd0));
    reg [3:0] expected_valid=0;
    reg [143:0] expected_frame[0:3];
    integer j;
    always @(posedge sys_clk)begin
        if(!dut.src_reset[1])begin
            expected_valid=0;
            for(j=0;j<4;j=j+1)expected_frame[j]=0;
        end else begin
            if(dut.publish!==expected_valid[3])$fatal(1,"Publication latency changed");
            if(dut.publish)begin
                if(dut.u_cdc.src_sample!==expected_frame[3])
                    $fatal(1,"Frame differs at %0d got=%h expected=%h",frames_checked,dut.u_cdc.src_sample,expected_frame[3]);
                frames_checked=frames_checked+1;
            end
            for(j=3;j>0;j=j-1)expected_frame[j]=expected_frame[j-1];
            expected_frame[0]=refdut.u_cdc.src_sample;
            expected_valid={expected_valid[2:0],refdut.publish};
        end
    end
    task frame;
        @(negedge sys_clk);valid=1;
        @(negedge sys_clk);valid=0;
        repeat(10)@(negedge sys_clk);
    endtask
    initial begin
        force dut.raw=raw_frame;force refdut.raw=raw_frame;
        force dut.adc_valid=valid;force refdut.adc_valid=valid;
        repeat(5)@(negedge sys_clk);rst=1;
        repeat(5)@(negedge sys_clk);
        raw_frame[129:120]=512;raw_frame[139:130]=512;
        // Simultaneous first calibration must use old calibrated gates and
        // newly completed XY metadata, exactly as the original E1 submission.
        repeat(20)frame();
        if(dut.calibrated!==14'h3fff)$fatal(1,"Calibration incomplete");
        // Every delta (0..1023) and gain (128..255), distributed over 12 keys.
        for(g=0;g<128;g=g+1)begin
            raw_frame[149:140]=g*8;
            for(d=0;d<1024;d=d+12)begin
                for(k=0;k<12;k=k+1)begin
                    raw_frame[k*10+:10]=(d+k)&1023;
                    values_checked=values_checked+1;
                end
                raw_frame[129:120]=(d+g)&1023;
                raw_frame[139:130]=(1023-d+g)&1023;
                frame();
            end
        end
        // Alternating endpoints exercise both two-frame hysteresis histories.
        for(n=0;n<80;n=n+1)begin
            for(k=0;k<12;k=k+1)raw_frame[k*10+:10]=((n/2+k)%2) ? 1023 : 0;
            frame();
        end
        // Reset during each pipeline stage must cancel the outstanding frame.
        for(n=0;n<5;n=n+1)begin
            @(negedge sys_clk);valid=1;
            @(negedge sys_clk);valid=0;
            repeat(n)@(negedge sys_clk);
            rst=0;repeat(4)@(negedge sys_clk);rst=1;
            repeat(8)@(negedge sys_clk);
            raw_frame=0;raw_frame[129:120]=512;raw_frame[139:130]=512;
            repeat(20)frame();
        end
        // Relearn nonzero, unequal baselines, then hit underflow and every
        // hysteresis boundary independently across the twelve sensors.
        rst=0;repeat(4)@(negedge sys_clk);rst=1;
        repeat(8)@(negedge sys_clk);
        for(k=0;k<12;k=k+1)raw_frame[k*10+:10]=20+k;
        raw_frame[129:120]=529;raw_frame[139:130]=503;
        repeat(20)frame();
        for(n=0;n<1024;n=n+1)begin
            for(k=0;k<12;k=k+1)raw_frame[k*10+:10]=(n+17*k)&1023;
            raw_frame[149:140]=(n*37)&1023;
            frame();
        end
        if(frames_checked<11000 || values_checked<131072)$fatal(1,"Insufficient coverage");
        $display("PASS: pressure pipeline frozen-reference frames=%0d curve cases=%0d added latency=80ns",frames_checked,values_checked);
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
