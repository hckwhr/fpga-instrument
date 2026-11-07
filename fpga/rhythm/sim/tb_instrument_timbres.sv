`timescale 1ns/1ps
// Independent harmonic oracle; never reads the DUT ROM for expected samples.
module tb_instrument_timbres;
    reg clk=0,rst=0,valid=0,on_event=1,enable=1;
    reg [1:0] instrument=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    integer divider=0,period=128,bank,i,j,k,checks=0,divergences=0,nonzero=0;
    integer expected_pcm,term,oracle[0:3][0:127];
    real maxima[0:3],a,value;
    wire ce=!divider[0];
    wire strobe=divider==0;
    wire ready,old_ready;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count;
    always #5 clk=~clk;
    always @(negedge clk) divider=(!rst || divider==period-1)?0:divider+1;
    `include "piano_wave.vh"
    polyphony_bank_32 #(.CE_ENABLE(1),.MULTI_TIMBRE_ENABLE(1)) dut(
        .clk(clk),.reset_n(rst),.clock_enable(ce),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .instrument_select(instrument),.note_select(4'd0),.keymap_select(1'b0),
        .octave_select(2'd1),.force_value(7'd96),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on_event),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(7'd96),
        .wide_event_octave(1'b0),.event_ready(ready),.sample(pcm),.active_voice_count(count));
    polyphony_bank_32 #(.CE_ENABLE(1)) original(
        .clk(clk),.reset_n(rst),.clock_enable(ce),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .instrument_select(2'd0),.note_select(4'd0),.keymap_select(1'b0),
        .octave_select(2'd1),.force_value(7'd96),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on_event),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(7'd96),
        .wide_event_octave(1'b0),.event_ready(old_ready),.sample(old_pcm));
    function real harmonic(input integer b,input real p);
        case(b)
            1:harmonic=$sin(p)+0.09*$sin(2*p)+0.025*$sin(3*p)+0.01*$sin(4*p);
            2:harmonic=$sin(p)+0.025*$sin(2*p)+0.42*$sin(3*p)+0.01*$sin(4*p)+0.18*$sin(5*p)+0.005*$sin(6*p)+0.06*$sin(7*p);
            default:harmonic=$sin(p)+0.5*$sin(2*p)+0.18*$sin(3*p)+0.32*$sin(4*p)+0.06*$sin(5*p)+0.09*$sin(6*p)+0.12*$sin(8*p);
        endcase
    endfunction
    function integer wave(input [31:0] phase,input integer b);
        integer index,delta;
        begin index=phase[31:25];delta=oracle[b][(index+1)%128]-oracle[b][index];
            wave=oracle[b][index]+((delta*integer'(phase[24:17]))>>>8);
        end
    endfunction
    task send(input bit start,input integer occurrence,input integer pitch);
        begin
            @(negedge clk);valid=1;on_event=start;id=occurrence;note=pitch%12;octave=pitch/12;
            @(posedge clk);while(!(ce && ready && old_ready))@(posedge clk);
            @(negedge clk);valid=0;
            repeat(160)@(negedge clk);
        end
    endtask
    task check_samples(input integer samples,input bit negative);
        integer n,lane,expected;
        begin
            for(n=0;n<samples;n++) begin
                @(posedge clk);while(!strobe)@(posedge clk);
                expected=0;
                for(lane=0;lane<32;lane++)begin
                    term=wave(dut.phase_accumulator[lane],instrument)*integer'(dut.envelope_gain[lane]);
                    expected+=term>>>16;
                    if({dut.phase_accumulator[lane],dut.envelope_gain[lane],dut.voice_id[lane]}!==
                        {original.phase_accumulator[lane],original.envelope_gain[lane],original.voice_id[lane]})
                        $fatal(1,"Instrument modified independent voice state lane=%0d",lane);
                end
                if(expected>32767)expected=32767;
                if(expected< -32768)expected=-32768;
                #1;
                if((^pcm)===1'bx)$fatal(1,"Unknown audio");
                if(!negative && pcm!==16'(expected))$fatal(1,"bank=%0d expected=%0d got=%0d",instrument,expected,pcm);
                if(!negative && instrument==0 && pcm!==old_pcm)$fatal(1,"Original piano PCM changed");
                if(negative && pcm!==16'(expected))divergences++;
                if(pcm!=0)nonzero++;
                checks++;
            end
        end
    endtask
    initial begin
        for(i=0;i<128;i++)oracle[0][i]=piano_point(i);
        for(bank=1;bank<4;bank++)begin
            maxima[bank]=0;
            for(i=0;i<128;i++)begin
                a=harmonic(bank,6.283185307179586*i/128.0);
                if(a<0)a=-a;if(a>maxima[bank])maxima[bank]=a;
            end
            for(i=0;i<128;i++)begin
                value=7081.0*harmonic(bank,6.283185307179586*i/128.0)/maxima[bank];
                oracle[bank][i]=$rtoi(value+(value<0?-0.5:0.5));
            end
        end
        #1;
        for(bank=0;bank<4;bank++)for(i=0;i<128;i++)begin
            if($signed(dut.instrument_rom.points[bank*128+i][32:17])!=oracle[bank][i] ||
               $signed(dut.instrument_rom.points[bank*128+i][16:0])!=oracle[bank][(i+1)%128]-oracle[bank][i])
                $fatal(1,"Independent knot/delta mismatch bank=%0d index=%0d",bank,i);
        end
        for(bank=0;bank<4;bank++)begin
            @(negedge clk);rst=0;instrument=bank;repeat(4)@(negedge clk);rst=1;
            repeat(160)@(negedge clk);
            for(i=0;i<32;i++)send(1,100+i,i);
            if(count!=32)$fatal(1,"Lost 32-voice capacity");
            check_samples(200,0); // 64 enabled steps, contractual minimum
            @(negedge clk);period=1024;divider=1;
            check_samples(100,0); // board cadence, 512 enabled steps
            for(i=0;i<32;i++)send(0,100+i,i);
            if(dut.voice_id_valid!=0)$fatal(1,"OFF ownership leaked");
            check_samples(20,0);
            @(negedge clk);period=128;divider=1;
        end
        // Deliberately violate the same ROM contract, require observable error.
        @(negedge clk);rst=0;instrument=2;period=32;repeat(4)@(negedge clk);rst=1;
        repeat(160)@(negedge clk);for(i=0;i<32;i++)send(1,200+i,i);
        check_samples(200,1);
        if(divergences==0 || nonzero<200)$fatal(1,"Negative control/coverage failed");
        $display("PASS: four independently calculated tables, %0d PCM samples, 32 states preserved, piano bit-exact, OFF IDs, sub-bound divergences=%0d",checks,divergences);
        $finish;
    end
    initial begin #20000000;$fatal(1,"Timbre test timeout");end
endmodule
