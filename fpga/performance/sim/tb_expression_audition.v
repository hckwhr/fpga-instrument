`timescale 1ns/1ps
module tb_expression_audition;
    reg clk=0,reset_n=0,strobe=0,enable=0;
    wire wet,mute;
    wire [2:0] gates;
    wire [3:0] note;
    reg [1:0] preset=1;
    wire signed [15:0] pcm;
    integer i,fd,errors=0;
    reg previous_wet;
    reg [31:0] previous_word;
    always #5 clk=~clk;
    expression_audition seq(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .percussive(1'b0),.trigger(),.force_level(),
        .enable(enable),.wet(wet),.mute(mute),.gates(gates),.note(note));
    audio_voice_mixer mixer(.song_release(1'b0),.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .voice_trigger(3'd0),.voice_gate(gates),.mute(mute),.play_mode(1'b0),
        .tone_select(2'd0),.note_select(note),.keymap_select(1'b0),.octave_select(2'd1),
        .force_value(7'd96),.glide_select(wet && preset==1 ? 2'd3 : 2'd0),
        .vibrato_depth(wet && preset==2 ? 8'd128 : 8'd0),.bend(8'sd0),.sample(pcm));
    task check;
        input cond; input [8*100-1:0] message;
        begin if(cond!==1'b1) begin $display("ERROR: %0s",message);errors=errors+1;end end
    endtask
    task tick; begin @(posedge clk);#1;end endtask
    task slot;
        begin repeat(8)tick();strobe=1;tick();strobe=0;end
    endtask
    initial begin
        repeat(3)tick();reset_n=1;repeat(8)tick();
        check(mute && gates==0 && !wet,"disabled sequencer not silent/dry");
        for(preset=1;preset<=2;preset=preset+1) begin
            enable=0;repeat(8)tick();enable=1;
            fd=$fopen(preset==1?"sim/ab_glide.csv":"sim/ab_vibrato.csv","w");
            check(fd!=0,"capture failed");
            for(i=0;i<384000;i=i+1) begin
                previous_wet=wet;slot();
                $fwrite(fd,"%0d,%0d,%0d\n",pcm,mixer.expression_increment[0],previous_wet);
                check((^pcm)!==1'bx && pcm!=32767 && pcm!=-32768,"unknown or clipped PCM");
                if(i==37100 && preset==1) check(mixer.expression_increment[0]==35075158,"dry pitch did not jump to G");
                if(i==229100 && preset==1) check(mixer.expression_increment[0]>23409859 &&
                    mixer.expression_increment[0]<35075158,"wet glide did not traverse C-G");
                if(i==190000 || i==382000) check(pcm==0,"A/B separator failed to reach silence");
            end
            $fclose(fd);
            check(!wet,"eight-second A/B loop did not return to dry");
            enable=0;repeat(8)tick();check(mute && gates==0,"stop retained notes");
        end
        if(errors) $fatal(1,"audition failures %0d",errors);
        $display("PASS: identical C-G-C sequence, four-second A/B stages, production DDS, clean stop and PCM captures");
        $finish;
    end
endmodule
