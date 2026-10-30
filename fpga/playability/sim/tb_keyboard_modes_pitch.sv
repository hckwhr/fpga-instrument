`timescale 1ns/1ps
module tb_keyboard_modes_pitch;
    reg clk=0,rst=0,strobe=0,valid=0,on=1,piano=0,live=1;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [1:0] octave=0;
    reg [83:0] forces={12{7'd96}};
    wire ready,ref_ready;
    wire signed [15:0] pcm,ref_pcm;
    wire [11:0] held,ref_held;
    integer div=0,mode,o,k,lane,found,c_lane,high_lane,checks=0;
    always #5 clk=~clk;
    always @(negedge clk)begin
        div=(!rst || div==511)?0:div+1;strobe=div==0;
    end
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),
        .KEYBOARD_SCALE_SUPPORT(1),.SHARED_KEY_FORCE(1),.SHARED_PITCH(1),.SHARED_PITCH_LANES(16)) dut(
        .clk(clk),.clock_enable(1'b1),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd96),
        .key_forces(forces),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.keyboard_piano(piano),.event_id(id),.event_note(note),
        .event_octave(octave),.wide_event_octave(1'b0),.event_force(7'd96),
        .event_ready(ready),.sample(pcm),.held_note_mask(held));
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),
        .SHARED_KEY_FORCE(1),.SHARED_PITCH(1),.SHARED_PITCH_LANES(16)) reference(
        .clk(clk),.clock_enable(1'b1),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd96),
        .key_forces(forces),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.keyboard_piano(1'b0),.event_id(id),.event_note(note),
        .event_octave(octave),.wide_event_octave(1'b0),.event_force(7'd96),
        .event_ready(ref_ready),.sample(ref_pcm),.held_note_mask(ref_held));
    // Independent frequency table, not a call into the implementation mapper.
    function [31:0] expected(input integer key,input integer oct,input bit white);
        integer semitone,level;
        reg [31:0] base;
        begin
            semitone=key;level=oct;
            if(white)begin
                case(key)
                    0:semitone=0;1:semitone=2;2:semitone=4;3:semitone=5;
                    4:semitone=7;5:semitone=9;6:semitone=11;7:semitone=12;
                    8:semitone=14;9:semitone=16;10:semitone=17;11:semitone=19;
                endcase
            end
            if(semitone>=12)begin semitone-=12;level++;end
            case(semitone)
                0:base=23409859;1:base=24801882;2:base=26276679;3:base=27839171;
                4:base=29494575;5:base=31248413;6:base=33106541;7:base=35075158;
                8:base=37160835;9:base=39370534;10:base=41711627;11:base=44191930;
            endcase
            expected=level==0?base>>1:base<<(level-1);
        end
    endfunction
    always @(posedge clk)begin
        #1;
        if(rst && (!piano || !live))begin
            if(pcm!==ref_pcm || ready!==ref_ready || held!==ref_held)
                $fatal(1,"Original/score mode not cycle-exact");
            checks++;
        end
    end
    task samples(input integer n);repeat(n)begin @(posedge strobe);@(negedge clk);end endtask
    task send(input integer key,input integer identity,input bit is_on);begin
        @(negedge clk);note=key;id=identity;on=is_on;valid=1;
        do @(posedge clk);while(!ready);
        @(negedge clk);valid=0;samples(2);
    end endtask
    initial begin
        for(mode=0;mode<3;mode++)for(o=0;o<3;o++)begin
            rst=0;repeat(5)@(negedge clk);piano=mode!=0;live=mode!=2;octave=o;rst=1;samples(3);
            for(k=0;k<12;k++)send(k,k,1);
            samples(260);
            for(k=0;k<12;k++)begin
                found=0;
                for(lane=0;lane<32;lane++)if(dut.voice_id_valid[lane] && dut.voice_id[lane]==k)begin
                    found++;
                    if(dut.phase_increment_reg[lane]!==expected(k,o,mode==1) || dut.voice_note[lane]!=k)
                        $fatal(1,"Pitch/physical identity mismatch mode=%0d octave=%0d key=%0d",mode,o,k);
                end
                if(found!=1)$fatal(1,"Duplicate or missing owner");
            end
            for(k=0;k<12;k++)send(k,k,0);
            if(held!=0)$fatal(1,"OFF failed");
        end
        rst=0;repeat(5)@(negedge clk);piano=1;live=1;octave=1;rst=1;samples(3);
        send(0,100,1);send(7,101,1);samples(260);
        c_lane=-1;high_lane=-1;
        for(lane=0;lane<32;lane++)if(dut.voice_id_valid[lane])begin
            if(dut.voice_id[lane]==100)c_lane=lane;
            if(dut.voice_id[lane]==101)high_lane=lane;
        end
        if(c_lane<0 || high_lane<0 || c_lane==high_lane)$fatal(1,"Octave ownership aliases");
        forces[6:0]=32;forces[55:49]=120;samples(10);
        if(dut.envelope_target[c_lane]>=dut.envelope_target[high_lane])$fatal(1,"Octaves share pressure");
        send(0,100,0);send(0,102,1);send(0,100,0);samples(3);
        if(held!==12'h081 || dut.voice_releasing[high_lane])$fatal(1,"Stale OFF released new C/high C");
        $display("PASS: 12 keys x 3 octaves x 3 contexts; original and score PCM cycle exact (%0d checks); white-key pitches, C/high-C independent pressure and stale OFF",checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"Keyboard pitch timeout");end
endmodule
