`timescale 1ns/1ps
module tb_v3_analog_input;
    reg sys_clk=0,audio_clk=0,rst=0,running=1;
    always #10 if(running)sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    reg [9:0] div=0;
    always @(posedge audio_clk)div<=div+1'b1;
    wire strobe=div==0;
    reg [159:0] values=0;
    wire miso,sclk,mosi,cs0,cs1,ready,gate;
    wire [15:0] keys;
    wire [83:0] forces;
    wire [6:0] force_value;
    wire signed [7:0] bend;
    wire [7:0] vibrato;
    integer i;
    v3_analog_input #(.SPI_DIV(5),.SCAN_IDLE_CYCLES(200),.SETTLE_FRAMES(2),.CALIBRATION_LOG2(3)) dut(
        .sys_clk(sys_clk),.sys_reset_n(rst),.audio_clk(audio_clk),.audio_reset_n(rst),
        .sample_strobe(strobe),.adc_miso(miso),.manual_vibrato(2'd0),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs0),.adc_cs1_n(cs1),
        .keys(keys),.key_forces(forces),.force_value(force_value),.bend(bend),.vibrato_depth(vibrato),
        .pressure_gate(gate),.ready(ready));
    v3_dual_adc_model model(cs0,cs1,sclk,mosi,values,miso);
    // Independent serial reference of the previous contract, delayed by the
    // documented four clocks. Check every cycle, including releases/recovery.
    reg [6:0] expected_max[0:3];
    reg [6:0] reference_max;
    integer check_key,check_stage;
    always @(posedge audio_clk)begin
        if(!dut.dst_reset[1])begin
            for(check_stage=0;check_stage<4;check_stage++)expected_max[check_stage]=0;
        end else begin
            reference_max=0;
            for(check_key=0;check_key<12;check_key++)
                if(dut.keys_audio[check_key] && dut.forces_audio[check_key*7+:7]>reference_max)
                    reference_max=dut.forces_audio[check_key*7+:7];
            for(check_stage=3;check_stage>0;check_stage--)expected_max[check_stage]=expected_max[check_stage-1];
            expected_max[0]=reference_max;
        end
        #1;
        if(dut.max_force!==expected_max[3])$fatal(1,"Aggregate force pipeline mismatch");
        if(force_value!==(ready ? expected_max[3] : 7'd0))$fatal(1,"Aggregate force readiness mismatch");
    end
    task samples(input integer n);repeat(n)begin @(posedge strobe);@(negedge audio_clk);end endtask
    task frames(input integer n);repeat(n)begin @(posedge dut.adc_valid);repeat(20)@(negedge audio_clk);end endtask
    initial begin
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        values[129:120]=529;values[139:130]=503;values[149:140]=1023;
        values[9:0]=300;values[119:110]=1023;
        values[129:120]=1023;values[139:130]=0;
        repeat(10)@(negedge sys_clk);rst=1;samples(100);
        if(!ready || dut.calibrated[0] || dut.calibrated[11] || dut.calibrated[13:12]!=0 || keys!=0 || bend!=0 || vibrato!=0)
            $fatal(1,"Bad/held sensors blocked good keys or escaped calibration guard");
        values[19:10]=85;frames(5);
        // raw 85 against the learnt zero of 21 is delta 64; at the 2x pot gain
        // the velocity curve maps that to 79. The previous linear map gave 63.
        if(keys!==16'h002 || forces[13:7]!=79)$fatal(1,"Good key blocked by bad neighbours/joystick");
        values[19:10]=21;frames(5);if(keys!=0)$fatal(1,"Partial-board release failed");
        values[9:0]=20;values[119:110]=31;
        values[129:120]=529;values[139:130]=503;frames(18);
        if(keys!==0 || gate || bend!==0 || dut.center_x!=503 || dut.center_y!=529)
            $fatal(1,"Wrong independent baseline/XY calibration");
        values[9:0]=84;values[119:110]=285;frames(5);
        // Same delta 64 at 2x gain as above: 79 on the new velocity curve.
        if(keys!==16'h801 || forces[6:0]!=79 || forces[83:77]!=127 || force_value!=127)
            $fatal(1,"Independent key velocities lost keys=%h force0=%d force11=%d",keys,forces[6:0],forces[83:77]);
        values[9:0]=164;frames(4);
        if(forces[6:0]!=127 || forces[83:77]!=127)$fatal(1,"Cross-key pressure contamination");
        values[9:0]=38;frames(4);if(!keys[0])$fatal(1,"Hysteresis released too early");
        values[9:0]=31;frames(4);if(keys[0] || !keys[11])$fatal(1,"Independent key release failed");
        for(i=0;i<12;i++)values[i*10+:10]=320+i;
        frames(5);if(keys!==16'hfff)$fatal(1,"12-key chord missing");
        values[139:130]=950;values[129:120]=950;samples(200);
        if(bend<85 || vibrato<85)$fatal(1,"Joystick X/Y not routed");
        values[149:140]=0;frames(5);
        for(i=0;i<12;i++)if(forces[i*7+:7]!=127)$fatal(1,"Low sensitivity capped a firm press");
        values[9:0]=84;frames(5);
        // Unity gain: delta 64 is not amplified, so the curve itself maps it to
        // 55. The linear map gave 32. A firm press still reaches 127 above.
        if(forces[6:0]!=55)$fatal(1,"Low sensitivity is not unity gain");
        values[149:140]=1023;frames(5);
        // The pot now scales the sensor reading ahead of the velocity curve,
        // so doubling the reading no longer doubles the force: delta 64 becomes
        // 127 counts, which the curve maps to 79 rather than 2x55. What must
        // hold is that high sensitivity makes the same press register harder.
        if(forces[6:0]!=79)$fatal(1,"High sensitivity did not raise light pressure");
        values[159:150]=1023;frames(4);if(keys!==16'hfff)$fatal(1,"NC CH7 changed keys");
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        values[139:130]=50;values[129:120]=529;samples(300);
        if(keys!==0 || gate || bend> -85 || vibrato!==0)$fatal(1,"Release/negative bend failed");
        values[9:0]=300;frames(4);running=0;samples(260);
        if(ready || gate || keys!==0)$fatal(1,"Stale ADC frame held notes");
        running=1;wait(ready);frames(3);if(keys!==1)$fatal(1,"Frame recovery failed");
        rst=0;#1;if(keys!==0)$fatal(1,"Coupled reset failed");
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        repeat(10)@(negedge sys_clk);rst=1;
        for(i=0;i<30;i++)begin values[29:20]=(i%2) ? 20 : 60;frames(1);end
        if(!ready || dut.calibrated[2] || keys!=0)$fatal(1,"Noisy channel poisoned calibration");
        values[29:20]=22;frames(18);
        if(!dut.calibrated[2])$fatal(1,"Noisy channel failed to recover after stable release");
        $display("PASS: dual ADC, independent held/noisy/disconnected sensor calibration and recovery, 12 keys, independent force, hysteresis, X/Y, pot, NC CH7, timeout/reset");$finish;
    end
    initial begin #50000000;$fatal(1,"V3 analog timeout");end
endmodule
