`timescale 1ns/1ps
module tb_pitch_expression;
    reg clk=0,reset_n=0,strobe=0,mute=0,pluck=0,chord=1;
    reg [2:0] triggers=0,gates=0;
    reg [1:0] tone=3,octave=1,glide=0,vibrato=0;
    reg [3:0] note=0;
    reg [6:0] force_level=96;
    wire signed [15:0] sample,reference_sample;
    reg unit_start=0,unit_active=1;
    reg [31:0] unit_target=23409859,unit_seed=23409859;
    reg [1:0] unit_glide=0,unit_vibrato=0;
    reg signed [7:0] unit_lfo=0;
    wire [31:0] unit_increment;
    integer errors=0,i,j,k,t,o,m,fd,previous,limit,mag,peak=0;
    integer min_increment,max_increment;
    reg [31:0] expected_phase;
    audio_voice_mixer dut(.song_release(1'b0),.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .voice_trigger(triggers),.voice_gate(gates),.mute(mute),.play_mode(pluck),
        .tone_select(tone),.note_select(note),.keymap_select(chord),.octave_select(octave),
        .force_value(force_level),.glide_select(glide),
        .vibrato_depth(vibrato==0?8'd0:vibrato==1?8'd32:vibrato==2?8'd64:8'd128),.bend(8'sd0),.sample(sample));
    baseline_expression_mixer baseline(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .voice_trigger(triggers),.voice_gate(gates),.mute(mute),.play_mode(pluck),
        .tone_select(tone),.note_select(note),.keymap_select(chord),.octave_select(octave),
        .force_value(force_level),.sample(reference_sample));
    pitch_expression unit(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(!mute),.active(unit_active),.note_start(unit_start),
        .target_increment(unit_target),.start_increment(unit_seed),.start_valid(1'b1),
        .glide_select(unit_glide),
        .vibrato_depth(unit_vibrato==0?8'd0:unit_vibrato==1?8'd32:unit_vibrato==2?8'd64:8'd128),.lfo(unit_lfo),.bend(8'sd0),
        .expressed_increment(unit_increment));
    always #5 clk=~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task check;
        input cond; input [8*110-1:0] message;
        begin if(!cond) begin $display("ERROR: %0s",message); errors=errors+1; end end
    endtask
    task next_sample;
        begin
            // Idle clocks allow registered pitch products to settle, matching
            // the real 1024-clock slot without simulating its idle remainder.
            repeat(8)tick();
            expected_phase=(dut.voice0_gain==0)?0:
                dut.voice0_phase_accumulator+dut.expression_increment[0];
            strobe=1; tick(); strobe=0; triggers=0; unit_start=0;
            check(dut.voice0_phase_accumulator==expected_phase,"oscillator did not consume expressed frequency");
            // The mixer commits this sample three clocks after the strobe.
            // Keep the phase check at acceptance, then compare completed PCM.
            repeat(3)tick();
            check((^sample)!==1'bx,"expression produced unknown PCM");
            if(glide==0 && vibrato==0) check(sample===reference_sample,"disabled expressions changed baseline PCM");
            check({dut.voice0_gain,dut.voice1_gain,dut.voice2_gain,dut.voice3_gain}===
                {baseline.voice0_gain,baseline.voice1_gain,baseline.voice2_gain,baseline.voice3_gain},
                "pitch modulation changed amplitude envelope");
            mag=sample<0?-sample:sample; if(mag>peak)peak=mag;
            check(mag<32767,"expression output clipped");
        end
    endtask
    task restart;
        begin reset_n=0; strobe=0; triggers=0; gates=0; repeat(3)tick(); reset_n=1; repeat(8)tick(); end
    endtask
    initial begin
        restart();
        // Exact off-mode equivalence over all ordinary tone/root/octave/mode combinations.
        for(t=0;t<4;t=t+1) for(k=0;k<12;k=k+1) for(o=0;o<3;o=o+1) for(m=0;m<2;m=m+1) begin
            tone=t; note=k; octave=o; pluck=m;
            triggers=1; gates=1; repeat(32)next_sample();
            triggers=4; gates=4; repeat(32)next_sample();
            gates=0; repeat(8)next_sample();
        end
        $display("BYPASS 288 tone/root/octave/mode cases are PCM-identical");
        // Both directions, all durations, exact target, no overshoot.
        for(j=1;j<=3;j=j+1) begin
            unit_glide=0; unit_target=23409859; next_sample();
            unit_glide=j; unit_target=35075158; unit_start=1; next_sample();
            previous=unit_increment; limit=(j==1)?4096:(j==2)?8192:16384;
            check(previous==23409859,"glide did not start at previous frequency");
            for(i=0;i<limit+2;i=i+1) begin
                next_sample();
                check(unit_increment>=previous && unit_increment<=35075158,"rising glide overshot/reversed");
                previous=unit_increment;
            end
            check(unit_increment==35075158,"glide failed to reach exact upper target");
            unit_target=23409859; next_sample(); previous=unit_increment;
            for(i=0;i<limit+2;i=i+1) begin
                next_sample();
                check(unit_increment<=previous && unit_increment>=23409859,"falling glide overshot/reversed");
                previous=unit_increment;
            end
            check(unit_increment==23409859,"glide failed to reach exact lower target");
        end
        // Reverse direction during a glide: retarget from the current pitch.
        unit_glide=3; unit_target=35075158; unit_start=1; next_sample();
        repeat(500)next_sample(); previous=unit_increment;
        unit_target=23409859; next_sample();
        check(unit_increment==previous,"mid-glide retarget jumped in pitch");
        repeat(17000)next_sample();
        check(unit_increment==23409859,"mid-glide reversal missed target");
        // Simultaneous glide/vibrato: modulation follows the moving base.
        unit_target=35075158; unit_start=1; unit_vibrato=3; unit_lfo=64; next_sample();
        repeat(500)next_sample();
        check(unit_increment>unit.base_increment && unit_increment<35075158,
            "combined glide/vibrato did not track moving base");
        unit_vibrato=0; unit_glide=0; unit_target=23409859; next_sample();
        for(j=1;j<=3;j=j+1) begin
            unit_vibrato=j; unit_lfo=-128; next_sample(); next_sample();
            min_increment=unit_increment;
            unit_lfo=127; next_sample(); next_sample(); max_increment=unit_increment;
            check(min_increment<23409859 && max_increment>23409859,"vibrato did not modulate both sides");
            check(min_increment>22600000 && max_increment<24200000,"vibrato depth is out of range");
            $display("VIBRATO depth=%0d min_word=%0d max_word=%0d",j,min_increment,max_increment);
        end
        unit_vibrato=0; next_sample(); check(unit_increment==unit_target,"vibrato off did not restore exact pitch");
        // Production chord glide and a real PCM export.
        glide=3; vibrato=0; tone=3; note=0; octave=1; pluck=0; chord=1; restart();
        fd=$fopen("sim/expression_glide.csv","w"); check(fd!=0,"cannot write glide capture");
        for(i=0;i<28800;i=i+1) begin
            if(i==0) begin triggers=1; gates=1; end
            if(i==4800) begin triggers=2; gates=2; end
            next_sample();
            $fwrite(fd,"%0d,%0d\n",sample,dut.expression_increment[0]);
            if(i==6000) check(dut.expression_increment[0]>23409859 && dut.expression_increment[0]<31248413,
                "chord transition did not glide between C and F");
        end
        $fclose(fd);
        check(dut.expression_increment[0]==31248413,"chord glide missed F4 target");
        // A fresh single-note slot starts at the previously played key pitch.
        chord=0; restart(); triggers=1; gates=1; repeat(500)next_sample();
        triggers=2; gates=2; next_sample();
        check(dut.expressions[1].pitch.base_increment==23409859,"single-key glide lost previous note seed");
        repeat(17000)next_sample();
        check(dut.expression_increment[1]==26276679,"single-key glide missed D4 target");
        glide=0; vibrato=3; chord=0; restart();
        fd=$fopen("sim/expression_vibrato.csv","w"); check(fd!=0,"cannot write vibrato capture");
        for(i=0;i<96000;i=i+1) begin
            if(i==0) begin triggers=1; gates=1; end
            next_sample();
            $fwrite(fd,"%0d,%0d\n",sample,dut.expression_increment[0]);
        end
        $fclose(fd);
        mute=1; repeat(8)tick(); check(sample==0,"mute did not silence expressions");
        check(dut.expressions[0].pitch.glide_left==0 && !dut.last_note_valid,"mute retained stale glide history");
        $display("EXPRESSION peak_pcm=%0d",peak);
        if(errors) $fatal(1,"expression failures: %0d",errors);
        $display("PASS: exact bypass, three glide speeds, three vibrato depths, unchanged envelopes, production phase path and PCM captures");
        $finish;
    end
endmodule
