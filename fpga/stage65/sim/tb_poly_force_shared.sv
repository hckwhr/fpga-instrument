`timescale 1ns/1ps
module force_shared_case #(parameter PERIOD=1024,NEGATIVE=0,HALF_RATE=0)(output reg finished=0);
    reg physical_clk=0,ce=1,rst=0,strobe=0,valid=0,on=1,flush=0;
    always #5 physical_clk=~physical_clk;
    always @(negedge physical_clk)if(HALF_RATE)ce<=!ce;
    wire clk=physical_clk && ce;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [83:0] forces={12{7'd96}},snapshot=0;
    integer divider=0;
    always @(negedge clk)begin
        divider=(!rst || divider==PERIOD-1)?0:divider+1;
        strobe=divider==0;
    end
    // Independent sample-and-hold reference contract for asynchronous ADC data.
    always @(posedge clk)if(!rst)snapshot<=0;else if(strobe)snapshot<=forces;
    wire ready,ref_ready;
    wire signed [15:0] pcm,ref_pcm;
    wire [5:0] count,ref_count;
    wire [11:0] held,ref_held;
    polyphony_bank_32 #(.CE_ENABLE(HALF_RATE),.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),.SHARED_KEY_FORCE(1)) dut(
        .clk(physical_clk),.clock_enable(ce),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),.voice_trigger(3'd0),.voice_gate(3'd0),
        .play_mode(1'b0),.tone_select(2'd0),.note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),
        .force_value(7'd96),.key_forces(forces),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(flush),.event_valid(valid),.event_on(on),.live_event_enable(1'b1),
        .event_id(id),.event_note(note),.event_octave(2'd1),.wide_event_octave(1'b0),.event_force(7'd96),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(held),.all_voices_active());
    stage54_polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1)) reference(
        .clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),.voice_trigger(3'd0),.voice_gate(3'd0),
        .play_mode(1'b0),.tone_select(2'd0),.note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),
        .force_value(7'd96),.key_forces(snapshot),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(flush),.event_valid(valid),.event_on(on),.live_event_enable(1'b1),
        .event_id(id),.event_note(note),.event_octave(2'd1),.wide_event_octave(1'b0),.event_force(7'd96),
        .event_ready(ref_ready),.sample(ref_pcm),.active_voice_count(ref_count),.held_note_mask(ref_held),.all_voices_active());
    integer mismatches=0,pcm_differences=0,checks=0;
    reg compare=0;
    always @(posedge clk)begin
        #1;
        if(rst && compare && !finished) begin
            checks++;
            if(ready!==ref_ready || held!==ref_held || count!==ref_count)
                $fatal(1,"Shared force changed event ownership period=%d ready=%b/%b held=%h/%h count=%d/%d time=%t",PERIOD,ready,ref_ready,held,ref_held,count,ref_count,$time);
            if(pcm!==ref_pcm)begin
                pcm_differences++;
                if(!NEGATIVE)$fatal(1,"Shared force PCM differs at period %d",PERIOD);
            end
            for(integer k=0;k<32;k++)
                if(dut.envelope_target[k]!==reference.envelope_target[k] || dut.envelope_gain[k]!==reference.envelope_gain[k])begin
                    mismatches++;
                    if(!NEGATIVE)$fatal(1,"Shared force envelope differs lane=%d period=%d",k,PERIOD);
                end
        end
    end
    task samples(input integer n);repeat(n)begin @(posedge strobe);@(negedge clk);end endtask
    task event_send(input integer number,input bit is_on);
        @(negedge clk);id=number;note=number%12;on=is_on;valid=1;
        do @(posedge clk);while(!ready);
        @(negedge clk);valid=0;
    endtask
    integer i,k;
    reg [31:0] rng=32'h1234ABCD;
    initial begin
        repeat(5)@(negedge clk);rst=1;samples(3);
        for(i=0;i<32;i++)begin event_send(i,1);samples(3);end
        samples(200);if(count!=32)$fatal(1,"Shared force test did not fill 32 lanes");compare=1;
        for(i=0;i<200;i++)begin
            // Vary phase relative to the sample edge, including one clock before.
            repeat(i%PERIOD)@(negedge clk);
            for(k=0;k<12;k++)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                forces[k*7+:7]=(i%3==0)?7'd0:(i%3==1)?7'd127:rng[6:0];
            end
            samples(2);
        end
        forces={12{7'd96}};samples(4);
        for(i=0;i<32;i++)event_send(i,0);
        samples(20);flush=1;samples(3);flush=0;samples(3);
        if(NEGATIVE && (mismatches==0 || pcm_differences==0))$fatal(1,"Sub-bound strobe did not expose shared-force failure");
        $display("Shared force period=%d negative=%d checks=%d envelope_differences=%d pcm_differences=%d",PERIOD,NEGATIVE,checks,mismatches,pcm_differences);
        finished=1;
    end
endmodule

module tb_half_rate_force;
    wire a,b,c;
    force_shared_case #(.HALF_RATE(1),.PERIOD(512)) production(a);
    force_shared_case #(.HALF_RATE(1),.PERIOD(33)) minimum_interval(b);
    force_shared_case #(.HALF_RATE(1),.PERIOD(16),.NEGATIVE(1)) negative(c);
    initial begin wait(a && b && c);$display("PASS: real CE force at 512/33 engine steps matches frozen reference; 16-step negative diverges");$finish;end
    initial begin #40000000;$fatal(1,"CE force timeout");end
endmodule
module tb_poly_force_shared;
    wire a,b,c,d;
    force_shared_case #(.PERIOD(1024)) production(a);
    force_shared_case #(.PERIOD(64)) boundary(b);
    force_shared_case #(.PERIOD(16),.NEGATIVE(1)) negative(c);
    force_shared_case #(.PERIOD(33)) minimum_interval(d);
    initial begin wait(a && b && c && d);$display("PASS: shared force 32 lanes, asynchronous updates, positive 33/64/1024 clocks and negative 16-clock PCM divergence");$finish;end
    initial begin #30000000;$fatal(1,"Shared force test timeout");end
endmodule
