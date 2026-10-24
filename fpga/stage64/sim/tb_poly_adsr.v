`timescale 1ns/1ps
module tb_poly_adsr;
    reg clk=0,rst=0,enable=1,pluck=0;
    reg [2:0] trigger=0,gate=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] force_value=96;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count;
    integer divider=0,i,j,k,fd,index=0,previous,peak,expected,released,held;
    wire strobe=divider==0;
    always #5 clk=~clk;
    always @(negedge clk)divider=(!rst || divider==1023)?0:divider+1;
    polyphony_bank_32 dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(force_value),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active());
    stage12_polyphony_bank_32 reference(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(force_value),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .sample(old_pcm),.active_voice_count(),.held_note_mask(),.all_voices_active());
    task tick;begin @(posedge clk);#2;end endtask
    task sample_once;
        begin
            @(posedge clk);while(!strobe)@(posedge clk);#2;
            if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"unknown/clipped PCM");
        end
    endtask
    task reset_bank;
        begin
            @(negedge clk);rst=0;trigger=0;gate=0;enable=1;
            repeat(4)tick();@(negedge clk);rst=1;repeat(16)tick();
        end
    endtask
    task strike;input [2:0] key;
        begin
            @(negedge clk);trigger=key;sample_once();
            @(negedge clk);trigger=0;
            repeat(320)tick();
            if(dut.allocator_state!=0)$fatal(1,"allocation missed budget");
        end
    endtask
    initial begin
        // Actual 1024-clock slots, unchanged oscillator and old/new PCM captures.
        reset_bank();gate=1;strike(1);
        fd=$fopen("sim/poly_adsr_profile.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,gate,gain,old_gain,attack,decay,release,pcm,old_pcm\n");
        peak=0;
        for(i=0;i<40000;i=i+1)begin
            if(i==6000)gate=0;
            previous=dut.envelope_gain[0];sample_once();
            if(i<6000 && dut.envelope_gain[0]>peak)peak=dut.envelope_gain[0];
            if(i>=6000 && dut.envelope_gain[0]>previous)$fatal(1,"release rose");
            $fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",i,gate,
                dut.envelope_gain[0],reference.envelope_gain[0],dut.voice_attacking[0],
                dut.voice_decaying[0],dut.voice_releasing[0],pcm,old_pcm);
            if(i==5999 && (peak!=3072 || dut.envelope_gain[0]!=2304 || dut.voice_decaying[0]))
                $fatal(1,"touch did not reach peak then 75 percent sustain");
        end
        $fclose(fd);
        if(count || pcm || dut.voice_attacking || dut.voice_decaying)$fatal(1,"release did not finish");
        // All held lanes follow the one live force channel at independent ages.
        // Event-owned velocities remain independent (tb_polyphony_events).
        // Group release
        // must preserve the other key's phase/frequency/envelope ownership.
        reset_bank();gate=3;
        for(i=0;i<32;i=i+1)begin
            note=i%12;octave=i/12;force_value=(i==31)?127:1+4*i;
            strike((i%2)?2:1);
        end
        repeat(5000)sample_once();
        if(count!=32)$fatal(1,"not 32 held voices");
        for(i=0;i<32;i=i+1)begin
            expected=3060; // Last live force is 127; all held manual lanes track it.
            if(dut.envelope_gain[i]!=expected || dut.voice_attacking[i] || dut.voice_decaying[i])
                $fatal(1,"lane %0d not at independent sustain",i);
        end
        gate=2;repeat(30000)sample_once();
        if(count!=16)$fatal(1,"group release count");
        for(i=0;i<32;i=i+1)begin
            expected=3060;
            if((i%2)==0 && dut.voice_active[i])$fatal(1,"released lane stuck");
            if((i%2)==1 && (!dut.voice_active[i] || dut.envelope_gain[i]!=expected))
                $fatal(1,"unrelated held lane changed");
        end
        gate=3;force_value=96;note=0;octave=1;strike(1);
        if(count!=17)$fatal(1,"retrigger failed to use released lane");
        repeat(5000)sample_once();
        if(dut.envelope_gain[0]!=2304)$fatal(1,"retrigger did not restart ADSR");
        // Interrupt attack and decay; neither may bounce back into sustain.
        for(j=0;j<2;j=j+1)begin
            reset_bank();gate=1;force_value=127;strike(1);
            repeat(j?500:20)sample_once();gate=0;
            for(k=0;k<30000;k=k+1)begin
                previous=dut.envelope_gain[0];sample_once();
                if(dut.envelope_gain[0]>previous)$fatal(1,"interrupted envelope bounced");
            end
            if(count || dut.voice_decaying[0])$fatal(1,"interrupted envelope stuck");
        end
        // Pluck remains sample-exact to the frozen stage-12 bank for the entire
        // attack/tail (gate release must not truncate it).
        pluck=1;force_value=96;reset_bank();gate=1;strike(1);
        for(i=0;i<96000;i=i+1)begin
            if(i==200)gate=0;
            sample_once();
            if(pcm!==old_pcm || dut.envelope_gain[0]!==reference.envelope_gain[0] || dut.voice_decaying[0])
                $fatal(1,"pluck changed at sample %0d",i);
        end
        if(count || pcm)$fatal(1,"pluck tail did not finish");
        $display("PASS: real 1024-clock slots; complete touch ADSR; 32 held sustains at shared live force; independent group release/retrigger; attack/decay interruption; 96000 sample-exact legacy pluck samples; no clipped/unknown PCM");
        $finish;
    end
    initial begin #2600000000; $fatal(1,"timeout");end
endmodule
