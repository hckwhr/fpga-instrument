`timescale 1ns/1ps
module tb_mixer_pipeline;
    reg clk=0,reset_n=0,strobe=0,mute=0,mode=0,keymap=0,song_release=0;
    reg [2:0] trigger=0,gate=0;
    reg [1:0] tone=3,octave=1,glide=0;
    reg [3:0] note=0;
    reg [6:0] force_level=96;
    reg signed [7:0] bend=0;
    reg [7:0] vibrato=0;
    reg [31:0] rng=32'h31415926;
    reg signed [15:0] history[0:2];
    reg signed [15:0] expected;
    wire signed [15:0] modern,legacy;
    integer cycle,j,nonzero=0,checks=0;
    always #5 clk=~clk;
    audio_voice_mixer #(.PIANO_FILTER_SHIFT(2)) dut(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),.song_release(song_release),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(mode),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(force_level),
        .glide_select(glide),.vibrato_depth(vibrato),.bend(bend),.sample(modern));
    stage5_audio_voice_mixer #(.PIANO_FILTER_SHIFT(2)) reference(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),.song_release(song_release),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(mode),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(force_level),
        .glide_select(glide),.vibrato_depth(vibrato),.bend(bend),.sample(legacy));
    initial begin
        for(j=0;j<3;j=j+1)history[j]=0;
        repeat(3)@(negedge clk);reset_n=1;
        for(cycle=0;cycle<220000;cycle=cycle+1)begin
            @(negedge clk);
            strobe=(cycle<40000)?1:(cycle<80000)?(cycle%2==0):
                   (cycle<180000)?(cycle%12==0):(cycle%1024==0);
            trigger=0;
            if(cycle%97==0)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                {mode,keymap,tone}=rng[3:0];octave=rng[5:4]%3;note=rng[9:6]%12;
                force_level=1+rng[16:10];if(force_level==0)force_level=127;
                gate=rng[19:17];trigger=rng[22:20];song_release=rng[23];
                glide=rng[25:24];bend=rng[31:24];vibrato=rng[15:8];
            end
            // Single-clock mute/reset interrupts all pipeline positions,
            // including outstanding work with no following sample strobe.
            mute=(cycle%1013==0);
            reset_n=(cycle%20011!=0);
            @(posedge clk);#1;
            if(!reset_n || mute)begin
                expected=0;for(j=0;j<3;j=j+1)history[j]=0;
            end else begin
                expected=history[2];history[2]=history[1];history[1]=history[0];history[0]=legacy;
            end
            if(modern!==expected)$fatal(1,"PCM mismatch cycle=%0d actual=%0d expected=%0d",cycle,modern,expected);
            if(dut.voice0_gain!==reference.voice0_gain || dut.voice3_gain!==reference.voice3_gain ||
               dut.voice0_phase_accumulator!==reference.voice0_phase_accumulator)
                $fatal(1,"voice state changed");
            if(modern!=0)nonzero=nonzero+1;
            checks=checks+1;
        end
        if(nonzero<10000)$fatal(1,"insufficient nonzero coverage");
        $display("PASS: %0d exact stage5 PCM checks at +3 clocks, cadence 1/2/12/1024, differing piano filter, all controls, mute/reset cancellation; nonzero=%0d",checks,nonzero);
        $finish;
    end
endmodule
