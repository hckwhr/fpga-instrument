`timescale 1ns/1ps
module tb_smooth_audio;
    reg clk=0, reset_n=0, strobe=0;
    reg [2:0] trigger=0, gate=0;
    reg pluck=1;
    reg [1:0] tone=3;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] force_level=96;
    wire signed [15:0] sound_new, sound_old, poly_sound;
    wire [5:0] count;
    wire full;
    reg poly_enable=0;
    reg [2:0] poly_trigger=0, poly_gate=0;
    integer fd, pd, i, j, previous_gain, decay_changes, peak, magnitude;
    integer attack_samples, last_step, tone_index, errors=0;
    integer note_index, octave_index, mode_index, stress_peak=0;
    reg [31:0] phase;
    real angle, reference_wave, error_value, max_error;
    reg signed [15:0] actual_wave;
    reg signed [15:0] reference_raw;
    always #5 clk=~clk;

    audio_voice_mixer modern(.song_release(1'b0),
        .glide_select(2'd0),.vibrato_depth(8'd0),.bend(8'sd0),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .voice_trigger(trigger),.voice_gate(gate),.mute(1'b0),
        .play_mode(pluck),.tone_select(tone),.note_select(note),
        .keymap_select(1'b1),.octave_select(octave),.force_value(force_level),.sample(sound_new));
    baseline_audio_voice_mixer legacy(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .voice_trigger(trigger),.voice_gate(gate),.mute(1'b0),
        .play_mode(pluck),.tone_select(tone),.note_select(note),
        .keymap_select(1'b1),.octave_select(octave),.force_value(force_level),.sample(sound_old));
    polyphony_bank_32 poly(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(poly_enable),
        .voice_trigger(poly_trigger),.voice_gate(poly_gate),.play_mode(1'b1),
        .tone_select(2'd3),.note_select(4'd0),.keymap_select(1'b0),
        .octave_select(2'd1),.force_value(7'd96),.sample(poly_sound),
        .active_voice_count(count),.held_note_mask(),.all_voices_active(full));

    task tick;
        begin @(posedge clk); #1; end
    endtask
    task mix_tick;
        begin
            reference_raw=legacy.raw_sample;
            strobe=1; tick(); strobe=0;
            // One sample enable, then drain the three-clock mixer pipeline.
            repeat(3) tick();
        end
    endtask
    task check;
        input condition;
        input [8*100-1:0] message;
        begin if (!condition) begin $display("ERROR: %0s",message); errors=errors+1; end end
    endtask

    initial begin
        repeat(3) tick(); reset_n=1; tick();
        // Exhaust every 5-bit sum and octave, including unused input encodings,
        // against the frozen arithmetic lookup (before comparing PCM below).
        for(i=0;i<32;i=i+1) for(j=0;j<4;j=j+1)
            check(modern.phase_increment(i,j) === legacy.phase_increment(i%12,j,i/12),
                "flattened pitch lookup differs from frozen arithmetic");
        max_error=0;
        // Independent analytic reference across all 15-bit interpolated phases.
        for(i=0;i<32768;i=i+1) begin
            phase=i<<17;
            actual_wave=modern.piano_wave(phase);
            angle=6.283185307179586*i/32768.0;
            reference_wave=6500.0*($sin(angle)+0.28*$sin(2.0*angle)+0.12*$sin(3.0*angle)+0.04*$sin(4.0*angle));
            error_value=actual_wave-reference_wave;
            if(error_value<0) error_value=-error_value;
            if(error_value>max_error) max_error=error_value;
        end
        $display("PIANO max interpolation error=%0.3f PCM counts",max_error);
        // h=2*pi/128: h^2/8 * 6500*(1+4*.28+9*.12+16*.04),
        // plus knot rounding, fraction quantization and truncation is <12.
        check(max_error<12.0,"piano interpolation exceeds analytic error bound");
        check(modern.piano_wave(32'd0)==0,"piano does not start at zero crossing");

        // Real RTL output: same I-IV-V-I phrase, previous soft vs bright tone.
        // Render one enable/sample, waiting for the documented output latency.
        fd=$fopen("sim/phrase_before_after.csv","w");
        check(fd!=0,"cannot open phrase output");
        strobe=1;
        for(i=0;i<144000;i=i+1) begin
            case(i)
                0: trigger=1;
                19200: trigger=2;
                38400: trigger=4;
                57600: trigger=1;
                default: trigger=0;
            endcase
            mix_tick();
            check(sound_new!==16'sh7fff && sound_new!==16'sh8000,"ordinary piano clipped");
            $fwrite(fd,"%0d,%0d\n",sound_old,sound_new);
        end
        $fclose(fd);
        check(sound_new==0,"ordinary pluck did not end in silence");
        strobe=0;

        // Basic timbres now share the brighter filter. Capture the same phrase
        // against the previous soft release and preserve the oscillator/envelope.
        for(tone_index=0;tone_index<3;tone_index=tone_index+1) begin
            reset_n=0; tick(); reset_n=1; tick();
            tone=tone_index;
            case(tone_index)
                0: fd=$fopen("sim/triangle_before_after.csv","w");
                1: fd=$fopen("sim/square_before_after.csv","w");
                2: fd=$fopen("sim/saw_before_after.csv","w");
            endcase
            check(fd!=0,"cannot open basic timbre output");
            strobe=1;
            for(i=0;i<144000;i=i+1) begin
                case(i)
                    0: trigger=1;
                    19200: trigger=2;
                    38400: trigger=4;
                    57600: trigger=1;
                    default: trigger=0;
                endcase
                mix_tick();
                check(modern.raw_q===reference_raw,"basic oscillator or envelope changed");
                check((^sound_new)!==1'bx,"basic waveform has unknown output");
                check(sound_new!==16'sh7fff && sound_new!==16'sh8000,"basic waveform clipped");
                $fwrite(fd,"%0d,%0d\n",sound_old,sound_new);
            end
            $fclose(fd);
            check(sound_new==0,"basic pluck did not end in silence");
            strobe=0;
        end

        // Maximum force, four-voice chords, every root/octave and both envelopes.
        // Include the upper V-chord root offset, where folded harmonics are most audible.
        force_level=127;
        for(tone_index=0;tone_index<4;tone_index=tone_index+1)
        for(octave_index=0;octave_index<3;octave_index=octave_index+1)
        for(note_index=0;note_index<12;note_index=note_index+1)
        for(mode_index=0;mode_index<2;mode_index=mode_index+1) begin
            strobe=0; reset_n=0; tick(); reset_n=1; tick();
            tone=tone_index; octave=octave_index; note=note_index; pluck=mode_index;
            gate=7; strobe=1;
            for(i=0;i<2048;i=i+1) begin
                trigger=(i==0)?3'b111:3'b000;
                mix_tick();
                check((^sound_new)!==1'bx,"stress output is unknown");
                check(modern.mixed_sample<32767 && modern.mixed_sample>-32768,"stress raw mix clipped");
                check(sound_new!==16'sh7fff && sound_new!==16'sh8000,"stress output clipped");
                magnitude=(sound_new<0)?-sound_new:sound_new;
                if(magnitude>stress_peak) stress_peak=magnitude;
            end
        end
        $display("HEADROOM: 288 tone/root/octave/envelope cases, peak=%0d",stress_peak);
        strobe=0; trigger=0; gate=0;

        // Render one 32-bank voice until its natural tail expires. Idle clocks
        // are compressed to 32/sample; one-note allocation and six mix stages
        // still settle. The allocation regression separately uses all 1024.
        pd=$fopen("sim/polyphony_tail.csv","w");
        check(pd!=0,"cannot open tail output");
        reset_n=0; tick(); reset_n=1; tick();
        poly_enable=1; poly_trigger=1; previous_gain=0; decay_changes=0;
        peak=0; attack_samples=0;
        for(i=0;i<90000;i=i+1) begin
            strobe=1; tick(); strobe=0; poly_trigger=0;
            repeat(31) tick();
            magnitude=(poly_sound<0)?-poly_sound:poly_sound;
            if(magnitude>peak) peak=magnitude;
            if(poly.envelope_gain[0]>previous_gain) begin
                check(poly.envelope_gain[0]-previous_gain<=16,"attack gain step too large");
                attack_samples=attack_samples+1;
            end else if(poly.envelope_gain[0]<previous_gain) begin
                last_step=previous_gain-poly.envelope_gain[0];
                check(last_step<=16,"decay gain step too large");
                decay_changes=decay_changes+1;
            end
            previous_gain=poly.envelope_gain[0];
            $fwrite(pd,"%0d,%0d\n",poly_sound,previous_gain);
        end
        $fclose(pd);
        $display("ENVELOPE attack=%0d samples, decay changes=%0d, peak=%0d",attack_samples,decay_changes,peak);
        check(attack_samples==192,"default attack duration changed");
        check(decay_changes>500,"tail does not have sufficient envelope resolution");
        check(count==0 && poly_sound==0,"dynamic tail did not reach exact silence");
        check(peak>200 && peak<512,"dynamic gain/headroom normalization changed");
        if(errors==0) $display("PASS: smooth timbre, envelope continuity, output headroom and RTL audio renders");
        else $fatal(1,"audio quality checks failed: %0d",errors);
        $finish;
    end
endmodule
