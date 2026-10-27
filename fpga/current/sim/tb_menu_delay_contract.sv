`timescale 1ns/1ps
`default_nettype none
// Control-level test: real menu FSM and production string bank. Inputs are
// post-debounce levels (not a physical pin/debounce test). Delay is a test-only
// model of the proposed bounded control path, NOT an implementation delay.
module tb_menu_delay_contract #(parameter integer MUTATION=0);
    reg clk=0, reset_n=0, ce=0;
    always #10.172414 clk=~clk;
    always @(posedge clk) if(!reset_n) ce<=0; else ce<=~ce;
    reg [2:0] keys=0;
    reg setting=0, remote_start=0;
    wire settings, test_mode, poly, concurrent, selftest, mute;
    wire string_mode, audition_active;
    instrument_control #(.CE_ENABLE(1)) control(
        .clk(clk),.reset_n(reset_n),.clock_enable(ce),
        .key_pressed(keys),.setting_pressed(setting),.remote_song_start(remote_start),
        .setting_mode(settings),.test_mode(test_mode),.test_polyphony(poly),
        .test_concurrent(concurrent),.self_test_active(selftest),.play_mute(mute),
        .string_mode(string_mode),.audition_active(audition_active));
    wire poly_delayed;
    assign #40.0 poly_delayed=poly;
    reg [9:0] physical_slot=0;
    always @(posedge clk) if(!reset_n)physical_slot<=0;else physical_slot<=physical_slot+1'b1;
    wire sample_tick=(physical_slot==10'd1023);
    wire [1:0] enabled;
    wire [7:0] active [0:1];
    wire signed [15:0] pcm [0:1];
    genvar c;
    generate for(c=0;c<2;c=c+1)begin: copies
        wire selected=c==0 ? poly : poly_delayed;
        // Exactly av_top's test-mode enable/mux cone. Non-test ordinary string
        // enable is forced OFF by the real menu mute, independent of selected.
        wire all_active=MUTATION ? selected : (selftest && selected && concurrent);
        wire bank_enable=all_active || (string_mode && !mute && !audition_active);
        wire [2:0] trigger;
        wire [3:0] note;
        wire [1:0] octave;
        assign enabled[c]=bank_enable;
        concurrent_test_source #(.CE_ENABLE(1),.STARTUP_INTERVAL_SAMPLES(2),.PLUCK_INTERVAL_SAMPLES(4)) source(
            .clk(clk),.reset_n(reset_n),.clock_enable(ce),.sample_strobe(sample_tick),
            .enable(all_active),.event_ready(1'b1),.string_trigger(trigger),
            .string_note(note),.string_octave(octave));
        physical_string_bank #(.CE_ENABLE(1)) bank(
            .clk(clk),.reset_n(reset_n),.clock_enable(ce),.sample_strobe(sample_tick),
            .enable(bank_enable),.voice_trigger(trigger),.voice_gate(3'd0),
            .play_mode(all_active),.keymap_select(1'b0),.note_select(note),.octave_select(octave),
            .force_value(7'd96),.bend(8'sd0),.vibrato_depth(8'd0),.sample(pcm[c]),.active_voices(active[c]));
    end endgenerate
    integer changes=0, compared=0, fill_edges=0, loop_edges=0;
    reg previous_poly=0;
    reg [7:0] seen=0;
    // Explicit property: changing the menu bit never changes either effective
    // receiver enable during its 40 ns propagation window.
    always @(posedge clk) begin
        #0.1;
        if(reset_n && $time>100)begin
            if(poly!==previous_poly)begin
                changes=changes+1;
                if(!settings || selftest || !mute)$fatal(1,"menu bit changed outside masked state");
            end
            previous_poly=poly;
            if(enabled[0]!==enabled[1])$fatal(1,"MENU_DELAY_UNSAFE: receiver enable differs");
            if(pcm[0]!==pcm[1] || active[0]!==active[1])$fatal(1,"MENU_DELAY_UNSAFE: audio/state differs");
            compared=compared+1;seen=seen|active[0];
        end
    end
    generate for(c=0;c<8;c=c+1)begin: state_checks
        always @(posedge clk)begin
            #0.2;
            if(reset_n && $time>100)begin
                if(copies[0].bank.strings[c].voice.fill_phase !== copies[1].bank.strings[c].voice.fill_phase ||
                   copies[0].bank.strings[c].voice.loop_value !== copies[1].bank.strings[c].voice.loop_value ||
                   copies[0].bank.strings[c].voice.state !== copies[1].bank.strings[c].voice.state)
                    $fatal(1,"MENU_DELAY_UNSAFE: fill/loop differs lane %0d",c);
                if(copies[0].bank.strings[c].voice.state==1)fill_edges=fill_edges+1;
                if(copies[0].bank.strings[c].voice.state==7)loop_edges=loop_edges+1;
            end
        end
    end endgenerate
    task step;
        begin @(negedge clk); while(!ce)@(negedge clk); @(posedge clk); #1; end
    endtask
    task press(input integer key);
        begin
            @(negedge clk);keys=0;setting=0;
            if(key==3)setting=1;else keys[key]=1;
            step();@(negedge clk);keys=0;setting=0;step();
        end
    endtask
    task select_poly;
        begin press(3);press(2);press(0);press(0);press(0);press(0);end
    endtask
    integer j;
    initial begin
        repeat(6)@(negedge clk);reset_n=1;
        select_poly();
        // Earliest permitted exit: setting press at the NEXT enabled edge
        // after changing poly, without waiting for another key-release sample.
        @(negedge clk);keys=3'b100;step();
        @(negedge clk);keys=0;setting=1;step();
        @(negedge clk);setting=0;step();
        if(settings || !poly || !selftest)$fatal(1,"earliest exit not exercised");
        // Actual 72-unit mode entry, then menu stop at different fill/loop phases.
        for(j=0;j<4;j=j+1)begin
            select_poly();press(2);press(2);press(3);
            repeat(22000+j*127)@(negedge clk);
            press(3); // stop while strings may be filling/feeding back
            // Navigate to additive and change poly 1 -> 0 while muted.
            press(2);press(0);press(0);press(0);press(2);
            press(3);repeat(17)@(negedge clk);
        end
        // Reset and remote override during menu transitions keep masks intact.
        @(negedge clk);reset_n=0;repeat(4)@(negedge clk);reset_n=1;
        repeat(8)@(negedge clk);remote_start=1;step();remote_start=0;step();
        if(changes<8 || seen!=8'hff || fill_edges==0 || loop_edges==0 || compared<80000)
            $fatal(1,"vacuous coverage changes=%0d lanes=%h fill=%0d loop=%0d cycles=%0d",changes,seen,fill_edges,loop_edges,compared);
        $display("# PASS: menu 40 ns delayed control equals reference; changes=%0d lanes=%h fill=%0d loop=%0d cycles=%0d; earliest exit +2 clocks",changes,seen,fill_edges,loop_edges,compared);
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
