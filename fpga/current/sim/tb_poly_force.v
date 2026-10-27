`timescale 1ns/1ps
module tb_poly_force;
    reg clk=0,rst=0;
    reg [2:0] trigger=0,gate=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] force_value=96;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count;
    integer divider=0,i,j,fd,delta,checks=0;
    reg [31:0] prior_phase[0:31];
    reg [11:0] prior_gain[0:31],prior_target[0:31];
    reg [31:0] prior_active,prior_steal;
    wire strobe=divider==0;
    always #5 clk=~clk;
    always @(negedge clk)divider=(!rst || divider==1023)?0:divider+1;
    polyphony_bank_32 dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(1'b0),.tone_select(2'd0),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(force_value),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active());
    stage15_polyphony_bank_32 reference(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(1'b0),.tone_select(2'd0),
        .note_select(note),.octave_select(octave),.keymap_select(1'b0),.force_value(force_value),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .sample(old_pcm),.active_voice_count(),.held_note_mask(),.all_voices_active());
    task tick;begin @(posedge clk);#2;end endtask
    task sample_once;
        integer lane;
        begin
            @(posedge clk);while(!strobe)@(posedge clk);
            prior_active=dut.voice_active;prior_steal=dut.voice_stealing;
            for(lane=0;lane<32;lane=lane+1)begin
                prior_phase[lane]=dut.phase_accumulator[lane];
                prior_gain[lane]=dut.envelope_gain[lane];prior_target[lane]=dut.envelope_target[lane];
            end
            #2;
            if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"unknown/clipped PCM");
            for(lane=0;lane<32;lane=lane+1)if(prior_active[lane] && !prior_steal[lane])begin
                if(dut.envelope_target[lane][3:0]!=0)$fatal(1,"target lost quantization invariant");
                delta=$signed({1'b0,dut.envelope_target[lane]})-$signed({1'b0,prior_target[lane]});
                if(delta>16 || delta < -16)$fatal(1,"force target jump lane=%0d delta=%0d",lane,delta);
                delta=$signed({1'b0,dut.envelope_gain[lane]})-$signed({1'b0,prior_gain[lane]});
                if(delta>16 || delta < -16)$fatal(1,"audible envelope step lane=%0d delta=%0d",lane,delta);
                if(dut.phase_accumulator[lane] !== (prior_phase[lane]+dut.phase_increment_reg[lane]))
                    $fatal(1,"pressure restarted phase");
                if(!gate[dut.voice_source[lane]] || dut.voice_releasing[lane])begin
                    if(dut.envelope_target[lane]!=prior_target[lane] || dut.envelope_gain[lane]>prior_gain[lane])
                        $fatal(1,"release tail followed new pressure");
                end
                checks=checks+1;
            end
        end
    endtask
    task reset_bank;begin
        @(negedge clk);rst=0;trigger=0;gate=0;force_value=96;
        repeat(4)tick();@(negedge clk);rst=1;repeat(16)tick();
    end endtask
    task strike;input [2:0] key;begin
        @(negedge clk);trigger=key;sample_once();@(negedge clk);trigger=0;repeat(320)tick();
        if(dut.allocator_state!=0)$fatal(1,"allocation deadline");
    end endtask
    task all_sustain;input integer expected;begin
        for(j=0;j<32;j=j+1)if(gate[dut.voice_source[j]])begin
            if(dut.envelope_gain[j]!=expected || dut.voice_attacking[j] || dut.voice_decaying[j])
                $fatal(1,"held lane %0d did not follow force: %0d expected=%0d",j,dut.envelope_gain[j],expected);
        end
    end endtask
    initial begin
        reset_bank();gate=3;
        for(i=0;i<32;i=i+1)begin note=i%12;octave=i/12;strike(i%2?2:1);end
        for(i=0;i<5000;i=i+1)begin sample_once();if(pcm!==old_pcm)$fatal(1,"constant-force PCM changed");end
        if(count!=32)$fatal(1,"32 lanes not allocated");all_sustain(2304);
        fd=$fopen("sim/poly_force.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,force,gates,target0,gain0,target1,gain1,old_gain0,pcm,old_pcm\n");
        for(i=0;i<12000;i=i+1)begin
            case(i)
                1000:force_value=16;
                2500:force_value=127;
                4000:force_value=0;
                5500:force_value=96;
                7000:gate=2;
                7500:force_value=0;
                9000:force_value=127;
            endcase
            if(i>=10500)force_value=i%2?0:127;
            sample_once();
            $fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",i,force_value,gate,
                dut.envelope_target[0],dut.envelope_gain[0],dut.envelope_target[1],dut.envelope_gain[1],
                reference.envelope_gain[0],pcm,old_pcm);
            if(i==2499)all_sustain(384);
            if(i==3999)all_sustain(3060);
            if(i==5499)begin all_sustain(0);if(count!=32 || pcm!=0)$fatal(1,"silent hold lost allocation");end
            if(i==6999)all_sustain(2304);
            if(i==8999)all_sustain(0);
            if(i==10499)all_sustain(3060);
        end
        $fclose(fd);
        gate=0;repeat(30000)sample_once();if(count || pcm)$fatal(1,"force test did not release");
        // Force changes in A and D must not jump or reset the envelope. Include
        // pressure zero, recovery, and release while a target is still slewing.
        for(i=0;i<2;i=i+1)begin
            reset_bank();gate=1;strike(1);repeat(i?500:20)sample_once();
            force_value=0;repeat(512)sample_once();
            if(dut.envelope_gain[0]!=0 || count!=1)$fatal(1,"A/D pressure zero not silent/held");
            force_value=127;repeat(5000)sample_once();
            if(dut.envelope_gain[0]!=3060)$fatal(1,"A/D pressure recovery failed");
            force_value=0;repeat(10)sample_once();gate=0;force_value=127;
            repeat(30000)sample_once();if(count || pcm)$fatal(1,"release resurrected");
        end
        $display("PASS: 32 live touch lanes; %0d bounded gain/target and continuous phase checks; unchanged constant-force PCM; 0/16/96/127 force; silent hold/recovery; isolated tails; A/D changes; chatter; final silence",checks);
        $finish;
    end
    initial begin #1400000000;$fatal(1,"timeout");end
endmodule
