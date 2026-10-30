`timescale 1ns/1ps
// Behavioral comparison against the frozen, board-observed controller.
module tb_integration_control;
    `include "instrument_contract.vh"
    reg clk=0, reset_n=0, setting=0;
    reg [2:0] keys=0;
    reg [31:0] rng=32'h6137cafe;
    reg [15:0] seen=0;
    integer i,j,k,checks=0;
    reg legacy_sequence=1;
    integer legacy_checks=0;
    always #5 clk=~clk;
    instrument_control #(.PLAY_GUARD_CYCLES(4),.PLAY_GUARD_COUNTER_WIDTH(3))
        dut(.clk(clk),.reset_n(reset_n),.key_pressed(keys),.setting_pressed(setting),
        .remote_song_start(1'b0), .song_select(), .song_change(), .song_tempo(), .song_accompaniment(),
            .play_trigger(),.play_mute(),.setting_mode(),.settings_page(),.selected_field(),.play_mode(),.tone_select(),.string_mode(),.note_select(),.force_value(),.keymap_select(),.octave_select(),.effect_select(),.effect_strength(),.glide_select(),.vibrato_select(),.audition_mode(),.audition_target(),.test_mode(),.test_polyphony(),.status_payload());
    baseline_integration_control #(.PLAY_GUARD_CYCLES(4),.PLAY_GUARD_COUNTER_WIDTH(3))
        prior(.clk(clk),.reset_n(reset_n),.key_pressed(keys),.setting_pressed(setting),
            .play_trigger(),.play_mute(),.setting_mode(),.settings_page(),.selected_field(),.play_mode(),.tone_select(),.string_mode(),.note_select(),.force_value(),.keymap_select(),.octave_select(),.effect_select(),.effect_strength(),.glide_select(),.vibrato_select(),.audition_mode(),.audition_target(),.test_mode(),.test_polyphony(),.status_payload());
    task compare;
        begin
            // The new eighth target changes subsequent menu state after the
            // old seven-target wrap. Compare common behavior until that explicit
            // transition, then resume on reset. Song lifecycle has its own test.
            if(!reset_n) legacy_sequence=1;
            if(dut.audition_target==7 && prior.audition_target==0) legacy_sequence=0;
            if (legacy_sequence && {dut.status_payload,dut.play_trigger,dut.play_mute,dut.settings_page,
                 dut.string_mode,dut.effect_strength,dut.glide_select,dut.vibrato_select,
                 dut.audition_mode,dut.audition_target} !==
                {prior.status_payload,prior.play_trigger,prior.play_mute,prior.settings_page,
                 prior.string_mode,prior.effect_strength,prior.glide_select,prior.vibrato_select,
                 prior.audition_mode,prior.audition_target})
                $fatal(1,"controller changed at check %0d",checks);
            if(legacy_sequence) legacy_checks=legacy_checks+1;
            if (dut.setting_mode) seen[{dut.settings_page,dut.selected_field}]=1'b1;
            checks=checks+1;
        end
    endtask
    task tick; begin @(posedge clk); #1; compare(); end endtask
    task press; input [2:0] value;
        begin @(negedge clk); keys=value; tick(); @(negedge clk); keys=0; tick(); end
    endtask
    initial begin
        repeat(2)tick();
        if(dut.status_payload!==DEFAULT_CONTROL_STATUS) $fatal(1,"reset control contract");
        if(dut.settings_field_id(0,7)!==FIELD_INVALID ||
           dut.settings_field_id(1,7)!==FIELD_INVALID) $fatal(1,"tabs alias a parameter");
        @(negedge clk);reset_n=1;setting=1;tick();
        @(negedge clk);setting=0;tick();
        // Both pages, all legal rows, both adjustment directions and wrap.
        for(i=0;i<2;i=i+1)begin
            press(i==0?3'b010:3'b100);
            for(j=0;j<(i==0?6:7);j=j+1)begin
                press(3'b001);
                for(k=0;k<16;k=k+1)press(3'b010);
                for(k=0;k<16;k=k+1)press(3'b100);
            end
            press(3'b001);
        end
        if(seen!==16'hffbf) $fatal(1,"page coverage incomplete: %h",seen);
        // Reproducible simultaneous S2/key edges, held keys, pending triggers.
        for(i=0;i<20000;i=i+1)begin
            @(negedge clk);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            keys=rng[2:0]; setting=(rng[6:3]==0);
            if(i%997==0)reset_n=0;else reset_n=1;
            tick();
        end
        if(legacy_checks<1000) $fatal(1,"insufficient legacy controller coverage");
        $display("PASS: controller common-path equivalence, both pages and 20000 mixed key/S2 cycles (%0d common checks)",legacy_checks);
        $finish;
    end
endmodule
