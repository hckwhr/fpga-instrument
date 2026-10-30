`timescale 1ns/1ps
module tb_live_articulation_guide;
    reg clk=0,rst=0,valid=0,onoff=1,live=1,pluck=0,single_key=1,flush=0,piano=0,custom=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [1:0] octave=1,glide=0;
    reg [71:0] map=0;
    wire ready;wire [11:0] held,guide;wire signed [15:0] pcm;
    integer div=0,lane,j,owner;reg [31:0] origin,target;
    wire strobe=div==0;
    always #5 clk=~clk;
    always @(negedge clk)div=div==63?0:div+1;
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.LIVE_ARTICULATION(1),.KEY_GUIDE_ENABLE(1),
        .KEYBOARD_SCALE_SUPPORT(1),.CUSTOM_KEYMAP_SUPPORT(1),.SCORE_ENVELOPE_ENABLE(1)) dut(
        .clk(clk),.reset_n(rst),.clock_enable(1'b1),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(pluck),.tone_select(2'd0),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd96),
        .key_forces({12{7'd96}}),.glide_select(glide),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(flush),.live_event_enable(live),.live_single_note(single_key),
        .keyboard_piano(piano),.custom_enabled(custom),.custom_map(map),
        .event_valid(valid),.event_on(onoff),.event_id(id),.event_note(note),.event_octave(octave),
        .wide_event_octave(1'b0),.event_force(7'd96),.event_ready(ready),.sample(pcm),
        .held_note_mask(held),.guide_key_mask(guide));
    task samples(input integer n);repeat(n)begin @(posedge clk);while(!strobe)@(posedge clk);@(negedge clk);end endtask
    task send(input integer ident,input integer pitch,input integer oct,input bit state);
        begin @(negedge clk);id=ident;note=pitch;octave=oct;onoff=state;valid=1;
            do @(posedge clk);while(!ready);@(negedge clk);valid=0;
            repeat(100)@(negedge clk);
        end
    endtask
    task find_owner(input integer ident);
        begin owner=-1;for(j=0;j<32;j++)if(dut.voice_id_valid[j] && dut.voice_id[j]==ident)owner=j;
            if(owner<0)$fatal(1,"missing owner %d",ident);end
    endtask
    task clear;
        begin @(negedge clk);flush=1;samples(600);flush=0;samples(2);end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=1;samples(2);
        pluck=1;send(1,0,1,1);find_owner(1);lane=owner;send(1,0,1,0);samples(300);
        if(dut.envelope_gain[lane]==0 || !dut.voice_one_shot[lane] || held!=0)
            $fatal(1,"short pluck OFF killed attack/tail or retained key ownership");
        clear();pluck=0;send(2,0,1,1);find_owner(2);lane=owner;samples(1200);
        if(dut.voice_one_shot[lane] || dut.envelope_gain[lane]<1000)$fatal(1,"held envelope did not sustain");
        send(2,0,1,0);samples(1300);
        if(dut.voice_active[lane])$fatal(1,"held OFF did not retire voice");
        clear();glide=1;single_key=1;send(3,0,1,1);find_owner(3);origin=dut.phase_increment_reg[owner];
        send(3,0,1,0);send(4,7,1,1);find_owner(4);lane=owner;
        target=dut.phase_increment_reg[lane];samples(100);
        if(dut.expressed_increment[lane]<=origin || dut.expressed_increment[lane]>=target)
            $fatal(1,"live mono pitch did not glide");
        samples(4200);if(dut.expressed_increment[lane]!=target)$fatal(1,"glide missed target");
        single_key=0;send(5,4,1,1);find_owner(5);samples(3);
        if(dut.expressed_increment[owner]!=dut.phase_increment_reg[owner])$fatal(1,"chord inherited another pitch");
        clear();live=0;pluck=1;piano=1;
        send(10,4,1,1);find_owner(10);samples(4);
        if(guide!==12'h004 || dut.voice_one_shot[owner] || dut.expressed_increment[owner]!=dut.phase_increment_reg[owner])
            $fatal(1,"score articulation or white-key E4 guide wrong");
        send(11,0,2,1);samples(4);if(guide!==12'h084)$fatal(1,"C5 not mapped to high Do");
        send(12,1,1,1);samples(4);if(guide!==12'h084)$fatal(1,"unplayable sharp indicated wrong key");
        send(10,4,1,0);send(13,4,1,1);send(10,4,1,0);samples(4);
        if(guide!==12'h084)$fatal(1,"stale OFF cleared new guide");
        clear();custom=1;map={12{6'b101011}};map[5:0]={2'd1,4'd4};map[11:6]={2'd1,4'd4};
        send(20,4,1,1);samples(4);if(guide!==12'h001)$fatal(1,"duplicate mapping must choose first matching key");
        send(21,4,2,1);samples(4);if(guide!==12'h001)$fatal(1,"octave mismatch lit a key");
        send(20,4,1,0);samples(4);if(guide!==0)$fatal(1,"released guide stuck");
        $display("PASS: live pluck/held, quick OFF, mono glide/chord isolation, unchanged score articulation, white/custom/octave/duplicate guide");$finish;
    end
    initial begin #20000000;$fatal(1,"articulation timeout");end
endmodule
