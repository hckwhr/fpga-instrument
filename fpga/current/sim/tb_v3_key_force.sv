`timescale 1ns/1ps
module tb_v3_key_force;
    reg clk=0,rst=0;
    always #10 clk=~clk;
    reg [9:0] div=0;
    always @(negedge clk)div=(!rst || div==1023)?0:div+1'b1;
    wire strobe=div==0;
    reg [11:0] keys=0;
    reg [83:0] forces=0;
    wire valid,on,ready;
    wire [15:0] id;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] velocity;
    wire [11:0] held;
    integer accepted=0;
    keyboard_note_events #(.PER_KEY_FORCE_ENABLE(1)) events(
        .clk(clk),.reset_n(rst),.enable(1'b1),.keys(keys),.octave(2'd1),.velocity(7'd99),
        .key_forces(forces),.event_ready(ready),.event_valid(valid),.event_on(on),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(velocity));
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1)) bank(
        .clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(1'b1),.voice_trigger(3'd0),.voice_gate(3'd0),
        .play_mode(1'b0),.tone_select(2'd0),.note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),
        .force_value(7'd99),.key_forces(forces),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on),.live_event_enable(1'b1),
        .event_id(id),.event_note(note),.event_octave(octave),.wide_event_octave(1'b0),.event_force(velocity),
        .event_ready(ready),.sample(),.active_voice_count(),.held_note_mask(held),.all_voices_active());
    always @(posedge clk)if(rst && valid && ready && on)begin
        if(velocity!==forces[note*7+:7])$fatal(1,"Wrong per-key ON velocity");accepted++;
    end
    task samples(input integer n);repeat(n)begin @(posedge strobe);@(negedge clk);end endtask
    initial begin
        repeat(5)@(negedge clk);rst=1;samples(2);
        forces[6:0]=20;forces[83:77]=100;keys=12'h801;samples(300);
        if(accepted!=2 || held!==12'h801 || bank.envelope_target[0]!=640 || bank.envelope_target[1]!=3200)
            $fatal(1,"Per-key targets collapsed %d %d",bank.envelope_target[0],bank.envelope_target[1]);
        forces[6:0]=80;samples(200);
        if(bank.envelope_target[0]!=2560 || bank.envelope_target[1]!=3200)$fatal(1,"Live pressure crossed lanes");
        keys=12'h800;samples(10);forces[6:0]=1;samples(20);
        if(bank.envelope_target[0]!=2560 || held!==12'h800)$fatal(1,"Release tail followed pressure");
        keys=0;samples(10);if(held!==0)$fatal(1,"OFF lost");
        $display("PASS: distinct ON velocities and continuous per-key envelope targets, isolated release tails");$finish;
    end
    initial begin #30000000;$fatal(1,"Per-key force timeout");end
endmodule
