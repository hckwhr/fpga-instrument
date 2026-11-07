`timescale 1ns/1ps
// Compare sample boundaries, not internal pipeline latency: both versions have
// exactly 1024 physical clocks per sample; only the engine CE differs.
module tb_half_rate_datapaths;
    reg clk=0, reset_n=0, ce=0, strobe=0, enable=1, trigger=0;
    reg held=1, pluck=1, mute=0;
    reg [5:0] note=12;
    reg [6:0] force_value=96;
    reg signed [16:0] delta=0;
    reg [1:0] mode=0, strength=1;
    reg signed [15:0] input_sample=0;
    wire signed [15:0] strings[0:1], additive[0:1], effects[0:1];
    wire [15:0] levels[0:1];
    wire [1:0] active, all_partials;
    integer frame, cycle, checks=0, audible=0, fractional=0;
    always #5 clk=~clk;
    always @(negedge clk) ce<=!ce;
    genvar g;
    generate for(g=0;g<2;g=g+1)begin: variants
        physical_string_voice #(.CE_ENABLE(g)) string_voice(
            .clock_enable(ce),.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
            .enable(enable),.trigger(trigger),.held(held),.pluck_mode(pluck),
            .note(note),.force_value(force_value),.delay_delta(delta),
            .sample(strings[g]),.active(active[g]),.level(levels[g]),.busy(),.accepting());
        additive_bank_32 #(.CE_ENABLE(g),.ACTIVATION_INTERVAL_SAMPLES(2)) add(
            .clock_enable(ce),.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
            .enable(enable),.sample(additive[g]),.all_partials_active(all_partials[g]));
        audio_effects #(.CE_ENABLE(g)) effect(
            .clock_enable(ce),.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
            .mute(mute),.effect_select(mode),.effect_strength(strength),
            .sample_in(input_sample),.sample_out(effects[g]));
    end endgenerate
    initial begin
        repeat(6)@(posedge clk);
        @(negedge clk); #1;reset_n=1;
        // Choose a CE-active sampling edge. Controls change well before each
        // sample; trigger is held for two physical clocks like the gated bank.
        while(!ce)begin @(negedge clk);#1;end
        for(frame=0;frame<10000;frame=frame+1)begin
            strobe=1;
            for(cycle=0;cycle<1024;cycle=cycle+1)begin
                @(negedge clk);#1;
                if(cycle==0)strobe=0;
                if(cycle==1)trigger=0;
                if(cycle==900)begin
                    if({strings[0],levels[0],active[0],additive[0],effects[0],all_partials[0]} !==
                       {strings[1],levels[1],active[1],additive[1],effects[1],all_partials[1]})
                        $fatal(1,"half-rate sample mismatch frame=%0d string=%0d/%0d additive=%0d/%0d effect=%0d/%0d",
                               frame,strings[0],strings[1],additive[0],additive[1],effects[0],effects[1]);
                    checks=checks+1;
                    if(strings[1]!=0)audible=audible+1;
                end
                if(cycle==960)begin
                    input_sample=(frame*173)%24000-12000;
                    if(frame%700==0)begin
                        note=(frame/700)%36;force_value=48+(frame%79);trigger=1;
                    end
                    delta=(frame%800<400)?17'sd12345:-17'sd23456;
                    held=(frame%1300)<1100;pluck=(frame%2100)<1500;
                    mode=(frame/2000)%4;strength=(frame/1700)%3;
                    mute=(frame%2900)>2850;
                    enable=(frame%3200)<3100;
                end
                // Assert at the end of the slot, so two physical edges see it.
                if(cycle==1021 && frame%700==0)trigger=1;
            end
        end
        if(checks!=10000 || audible<1000)$fatal(1,"insufficient sample coverage");
        $display("PASS: %0d sample boundaries: half-rate string FILL/feedback, 32 additive partials and all effects equal full-speed; %0d audible string samples",checks,audible);
        $finish;
    end
    initial begin #110000000;$fatal(1,"half-rate datapath timeout");end
endmodule
