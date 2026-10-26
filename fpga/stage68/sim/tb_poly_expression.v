`timescale 1ns/1ps
module tb_poly_expression;
    reg clk=0,rst=0,enabled=1,events=0,pluck=0;
    reg [2:0] trigger=0,gate=1;
    reg [3:0] note=0;
    reg [1:0] octave=0;
    reg signed [7:0] bend=0;
    reg [7:0] depth=0;
    reg event_valid=0,event_on=1;
    reg [15:0] event_id=1;
    wire event_ready;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count;
    integer divider=0,i,j,k,checks=0,fd=0,samples=0,peak=0;
    integer min_ratio=999999,max_ratio=0;
    reg [31:0] prior_phase[0:31],step[0:31];
    reg [31:0] checked;
    real ratio,expected,cents,max_cents=0;
    wire strobe=divider==0;
    always #5 clk=~clk;
    always @(negedge clk) divider=(!rst || divider==1023)?0:divider+1;
    polyphony_bank_32 dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(7'd96),
        .bend(bend),.vibrato_depth(depth),.glide_select(2'd0),.event_mode(events),.event_flush(1'b0),
        .event_valid(event_valid),.event_on(event_on),.event_id(event_id),
        .event_note(note),.event_octave(octave),.event_force(7'd96),.event_ready(event_ready),
        .sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active());
    stage18_polyphony_bank_32 reference(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(7'd96),
        .event_mode(events),.event_flush(1'b0),.event_valid(event_valid),.event_on(event_on),
        .event_id(event_id),.event_note(note),.event_octave(octave),.event_force(7'd96),.event_ready(),
        .sample(old_pcm),.active_voice_count(),.held_note_mask(),.all_voices_active());
    always @(posedge clk) if(rst && strobe) begin
        checked=0;
        for(k=0;k<32;k=k+1) begin
            prior_phase[k]=dut.phase_accumulator[k]; step[k]=dut.expressed_increment[k];
            checked[k]=enabled && !dut.owner_change && dut.voice_active[k] && !dut.voice_stealing[k] &&
                !(dut.allocate_voice && dut.search_index==k) && !(dut.event_off && dut.id_match[k]);
        end
        #2;
        if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"invalid/clipped PCM");
        if(pcm>peak)peak=pcm;if(-pcm>peak)peak=-pcm;
        for(k=0;k<32;k=k+1)begin
            if(checked[k])begin
                if(dut.phase_accumulator[k]!==prior_phase[k]+step[k])$fatal(1,"phase discontinuity lane=%0d",k);
                checks=checks+1;
            end
            if(dut.envelope_gain[k]!==reference.envelope_gain[k] ||
               dut.voice_active[k]!==reference.voice_active[k] ||
               dut.phase_increment_reg[k]!==reference.phase_increment_reg[k])$fatal(1,"expression changed allocation/envelope");
        end
        if(events && pcm!==old_pcm)$fatal(1,"expression leaked into frozen event path");
    end
    task stream;input integer n;integer t;begin
        for(t=0;t<n;t=t+1)begin
            @(posedge clk);while(!strobe)@(posedge clk);#3;
            samples=samples+1;
            if(fd)$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",samples,
                bend,depth,dut.expression_ratio,dut.phase_increment_reg[0],dut.expressed_increment[0],
                dut.phase_increment_reg[7],dut.expressed_increment[7],dut.phase_increment_reg[31],dut.expressed_increment[31],count,pcm);
            @(negedge clk);
        end
    end endtask
    task strike;begin trigger=1;stream(1);trigger=0;repeat(330)@(negedge clk);end endtask
    task intervals;begin
        for(j=0;j<32;j=j+1)begin
            ratio=$itor(dut.expressed_increment[j])/$itor(dut.phase_increment_reg[j]);
            expected=$itor(dut.expression_ratio)/262144.0;
            cents=1200.0*$ln(ratio/expected)/$ln(2.0);if(cents<0)cents=-cents;
            if(cents>max_cents)max_cents=cents;
            if(cents>0.01)$fatal(1,"interval ratio error=%f lane=%0d",cents,j);
        end
    end endtask
    initial begin
        repeat(8)@(negedge clk);rst=1;
        for(i=0;i<32;i=i+1)begin note=i%12;octave=i/12;strike();end
        stream(4000);if(count!=32)$fatal(1,"not 32 live voices");
        // Independently compare every bend code against equal temperament.
        for(i=-128;i<=127;i=i+1)begin
            bend=i;repeat(64)@(negedge clk);intervals();
            ratio=$itor(dut.expressed_increment[0])/$itor(dut.phase_increment_reg[0]);
            expected=2.0**((i==127?128.0:i)/768.0);
            cents=1200.0*$ln(ratio/expected)/$ln(2.0);if(cents<0)cents=-cents;
            if(cents>0.06)$fatal(1,"bend tuning error %f",cents);
        end
        bend=0;depth=128;stream(2);
        fd=$fopen("sim/poly_expression.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,bend,depth,ratio,base0,step0,base7,step7,base31,step31,count,pcm\n");
        // More than one complete 5 Hz LFO period at production cadence.
        for(i=0;i<10000;i=i+1)begin
            stream(1);
            if(dut.expression_ratio<min_ratio)min_ratio=dut.expression_ratio;
            if(dut.expression_ratio>max_ratio)max_ratio=dut.expression_ratio;
            if(i%100==0)intervals();
        end
        if(min_ratio>254000 || max_ratio<270000)$fatal(1,"vibrato not oscillating at full depth");
        // All combined corners and all depth codes preserve pitch ratios.
        for(i=0;i<=128;i=i+1)begin depth=i;bend=i%2?-128:127;stream(1);intervals();end
        // New notes and repeated stealing while modulation is live.
        depth=64;bend=127;
        for(i=0;i<40;i=i+1)begin note=(i+5)%12;octave=i%3;strike();stream(20);end
        depth=0;bend=0;stream(3);
        for(j=0;j<32;j=j+1)if(dut.expressed_increment[j]!==dut.phase_increment_reg[j])$fatal(1,"neutral not exact");
        gate=0;stream(30000);if(count!=0 || pcm!=0)$fatal(1,"release not silent");
        $fclose(fd);fd=0;
        // Manual pluck continues its one-shot decay with the key already up,
        // while its pitch follows the same live expression ratio.
        pluck=1;depth=128;bend=127;note=7;octave=1;strike();stream(500);
        if(count!=1 || !dut.voice_one_shot[dut.next_voice_index-5'd1])$fatal(1,"expressed pluck missing");
        // Nonzero controls must not affect event-owned music, including switching.
        events=1;bend=-128;depth=128;stream(2);event_valid=1;
        @(posedge clk);while(!event_ready)@(posedge clk);@(negedge clk);event_valid=0;
        stream(2000);if(count!=1)$fatal(1,"event voice missing");
        event_on=0;event_valid=1;@(posedge clk);while(!event_ready)@(posedge clk);@(negedge clk);event_valid=0;
        stream(3000);if(count!=0)$fatal(1,"event release failed");
        enabled=0;stream(2);if(pcm!=0)$fatal(1,"disable not silent");
        if(checks<500000)$fatal(1,"insufficient lane coverage");
        $display("PASS: 32 parallel expressed lanes; %0d phase checks; 256 bends; 129 depths; max ratio error=%f cent; vibrato ratio=%0d..%0d; stealing, tails, neutral, event bypass; peak=%0d",checks,max_cents,min_ratio,max_ratio,peak);
        $finish;
    end
    initial begin #650000000;$fatal(1,"timeout");end
endmodule
