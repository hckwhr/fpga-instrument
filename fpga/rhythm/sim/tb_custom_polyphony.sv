`timescale 1ns/1ps
module tb_custom_polyphony;
    reg clk=0,reset_n=0,strobe=0,valid=0,note_on=1,live=1;
    reg[15:0]id=0;reg[3:0]key=0;reg[71:0]mapping=0;
    reg[83:0]forces={12{7'd96}};wire ready;wire[11:0]held;
    integer div=0,k,lane,found,owner;
    always #5 clk=~clk;
    always @(negedge clk)begin div=div==511?0:div+1;strobe=div==0;end
    polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1),.PER_KEY_FORCE_SUPPORT(1),.CUSTOM_KEYMAP_SUPPORT(1),
        .KEYBOARD_SCALE_SUPPORT(1),.SHARED_KEY_FORCE(1),.SHARED_PITCH(1),.SHARED_PITCH_LANES(16)) dut(
        .clk(clk),.clock_enable(1'b1),.reset_n(reset_n),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),.note_select(4'd0),
        .keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd96),.key_forces(forces),
        .glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),.event_mode(1'b1),.event_flush(1'b0),
        .event_valid(valid),.event_on(note_on),.event_id(id),.event_note(key),.event_octave(2'd1),.wide_event_octave(1'b0),
        .event_force(7'd96),.event_ready(ready),.live_event_enable(live),.keyboard_piano(1'b1),
        .custom_enabled(1'b1),.custom_map(mapping),.held_note_mask(held));
    task send(input integer source,input integer identity,input bit onoff);
        begin @(negedge clk);key=source;id=identity;note_on=onoff;valid=1;
            do @(posedge clk);while(!ready);@(negedge clk);valid=0;repeat(1024)@(negedge clk);end
    endtask
    initial begin
        // All keys intentionally share B5. Ownership and pressure remain distinct.
        mapping={12{6'b101011}};
        repeat(10)@(negedge clk);reset_n=1;repeat(1024)@(negedge clk);
        for(k=0;k<12;k++)send(k,k,1);
        repeat(30000)@(negedge clk);
        for(k=0;k<12;k++)begin
            found=0;
            for(lane=0;lane<32;lane++)if(dut.voice_id_valid[lane]&&dut.voice_id[lane]==k)begin
                found++;if(dut.phase_increment_reg[lane]!==32'd88383860 || dut.voice_note[lane]!=k)$fatal(1,"Mapped pitch or source-key force identity wrong");
            end
            if(found!=1)$fatal(1,"Same-pitch keys alias ownership");
        end
        send(0,0,0);send(0,30,1);send(0,0,0);
        if(held!==12'hfff)$fatal(1,"Stale release killed fresh owner");
        for(k=1;k<12;k++)send(k,k,0);send(0,30,0);
        if(held!=0)$fatal(1,"Mapped key stuck");
        // The upload path ignores custom keys and white-key conversion.
        live=0;send(0,50,1);found=0;
        for(lane=0;lane<32;lane++)if(dut.voice_id_valid[lane]&&dut.voice_id[lane]==50)begin
            found++;if(dut.phase_increment_reg[lane]!==32'd23409859)$fatal(1,"Custom mapping leaked into uploaded score");
        end
        if(found!=1)$fatal(1,"Score not allocated");
        $display("PASS: custom polyphony 12 same-pitch keys keep independent source/ID; stale OFF safe; score unaffected");$finish;
    end
    initial begin #2000000;$fatal(1,"timeout");end
endmodule
