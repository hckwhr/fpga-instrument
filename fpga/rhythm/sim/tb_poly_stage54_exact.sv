`timescale 1ns/1ps
module tb_poly_stage54_exact;
    reg clk=0,rst=0,enabled=1;
    always #5 clk=~clk;
    reg [9:0] divider=0;
    always @(negedge clk) divider=(!rst || divider==1023)?0:divider+1'b1;
    wire strobe=divider==0;
    reg [2:0] trigger=0,gate=0;
    reg pluck=0,chord=0;
    reg [1:0] tone=0,octave=1,glide=0;
    reg [3:0] root=0;
    reg [6:0] velocity=0;
    reg [83:0] forces=0;
    reg signed [7:0] bend=0;
    reg [7:0] vibrato=0;
    reg events=0,live=0,flush=0,valid=0,on=0,wide=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [1:0] event_octave=1;
    reg [6:0] event_force=0;
    wire ready,ref_ready;
    wire signed [15:0] sample,ref_sample;
    wire [5:0] count,ref_count;
    wire [11:0] held,ref_held;
    wire all_active,ref_all_active;
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),
        .SUSTAIN_COMPARE_PIPELINE(1)) dut(
        .clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),
        .tone_select(tone),.note_select(root),.keymap_select(chord),
        .octave_select(octave),.force_value(velocity),.key_forces(forces),
        .glide_select(glide),.bend(bend),.vibrato_depth(vibrato),
        .event_mode(events),.event_flush(flush),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.event_id(id),.event_note(note),
        .event_octave(event_octave),.wide_event_octave(wide),.event_force(event_force),
        .event_ready(ready),.sample(sample),.active_voice_count(count),
        .held_note_mask(held),.all_voices_active(all_active));
    stage54_polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),
        .SUSTAIN_COMPARE_PIPELINE(1)) reference(
        .clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),
        .tone_select(tone),.note_select(root),.keymap_select(chord),
        .octave_select(octave),.force_value(velocity),.key_forces(forces),
        .glide_select(glide),.bend(bend),.vibrato_depth(vibrato),
        .event_mode(events),.event_flush(flush),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.event_id(id),.event_note(note),
        .event_octave(event_octave),.wide_event_octave(wide),.event_force(event_force),
        .event_ready(ref_ready),.sample(ref_sample),.active_voice_count(ref_count),
        .held_note_mask(ref_held),.all_voices_active(ref_all_active));
    genvar g;
    generate for(g=0;g<32;g=g+1)begin: check_lane
        always @(negedge clk)if(rst)begin
            if(dut.u_voice_bank[g].key_force_q !== reference.u_voice_bank[g].key_force_q ||
               dut.u_voice_bank[g].sustain_gain_q !== reference.u_voice_bank[g].sustain_gain_q ||
               dut.envelope_target[g] !== reference.envelope_target[g] ||
               dut.envelope_gain[g] !== reference.envelope_gain[g] ||
               dut.envelope_count[g] !== reference.envelope_count[g] ||
               dut.phase_accumulator[g] !== reference.phase_accumulator[g] ||
               dut.phase_increment_reg[g] !== reference.phase_increment_reg[g] ||
               dut.voice_id[g] !== reference.voice_id[g] ||
               dut.voice_note[g] !== reference.voice_note[g] ||
               dut.u_voice_bank[g].glide_base !== reference.u_voice_bank[g].glide_base ||
               dut.u_voice_bank[g].modulated_q !== reference.u_voice_bank[g].modulated_q)
                $fatal(1,"Stage54 equivalence lane %0d target %0d/%0d sustain %0d/%0d",
                    g,dut.envelope_target[g],reference.envelope_target[g],
                    dut.u_voice_bank[g].sustain_gain_q,reference.u_voice_bank[g].sustain_gain_q);
            if(dut.u_voice_bank[g].sustain_gain_q !==
               (dut.envelope_target[g]-(dut.envelope_target[g]>>2)))
                $fatal(1,"Sustain mirror invariant lane %0d",g);
        end
    end endgenerate
    integer clocks=0;
    always @(negedge clk)if(rst)begin
        clocks=clocks+1;
        if({ready,sample,count,held,all_active,dut.voice_active,dut.voice_releasing,
            dut.voice_attacking,dut.voice_decaying,dut.voice_stealing} !==
           {ref_ready,ref_sample,ref_count,ref_held,ref_all_active,
            reference.voice_active,reference.voice_releasing,reference.voice_attacking,
            reference.voice_decaying,reference.voice_stealing})
            $fatal(1,"Stage54 outputs or envelope state diverged clock %0d",clocks);
    end
    task samples(input integer n);
        repeat(n)begin @(posedge strobe);@(negedge clk);end
    endtask
    task hit(input [2:0] mask);
        samples(1);trigger=mask;gate=mask;samples(1);trigger=0;
    endtask
    task event_send(input bit is_on,input integer occurrence,input integer pitch);
        @(negedge clk);valid=1;on=is_on;id=occurrence;note=pitch;
        do @(posedge clk);while(!ready);
        @(negedge clk);valid=0;
    endtask
    reg [31:0] rng=32'h54b10ace;
    integer i,k;
    initial begin
        repeat(5)@(negedge clk);rst=1;samples(2);
        velocity=127;hit(1);samples(300);
        velocity=0;samples(300);velocity=127;samples(300);
        bend=-128;vibrato=255;glide=3;root=7;hit(2);samples(50);
        chord=1;hit(7);samples(20);tone=3;pluck=1;hit(7);samples(40);
        gate=0;samples(50);enabled=0;samples(2);enabled=1;samples(2);
        events=1;live=1;pluck=0;chord=0;glide=0;bend=127;
        forces={12{7'd127}};event_force=127;
        for(i=0;i<40;i=i+1)begin
            event_octave=i%3;event_send(1,100+i,i%12);samples(1);
        end
        samples(300);
        if(count!=32)$fatal(1,"32 parallel live lanes not populated: %0d",count);
        for(i=0;i<256;i=i+1)begin
            for(k=0;k<12;k=k+1)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                forces[k*7+:7]=(i%3==0)?7'd0:(i%3==1)?7'd127:rng[6:0];
            end
            tone=i%4;samples(2);
        end
        forces=0;samples(300);forces={12{7'd127}};samples(300);
        for(i=8;i<40;i=i+1)event_send(0,100+i,i%12);
        samples(40);flush=1;samples(3);flush=0;live=0;
        event_force=127;event_send(1,500,11);samples(20);
        events=0;samples(4);velocity=0;gate=7;hit(7);samples(40);
        rst=0;repeat(4)@(negedge clk);rst=1;samples(4);
        $display("PASS: Stage54 cycle-exact 32-lane reference; live/manual force extrema, random per-key force, steal, glide, tone, OFF, flush, owner change and reset; %0d clocks",clocks);
        $finish;
    end
    initial begin #40000000;$fatal(1,"Stage54 equivalence timeout");end
endmodule
