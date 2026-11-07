`timescale 1ns/1ps
module tb_instrument_menu;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,setting=0;
    reg [2:0] keys=0;
    wire [1:0] instrument,tone;
    wire strings,piano;
    integer n;
    always #5 clk=~clk;
    instrument_control #(.MULTI_TIMBRE_ENABLE(1),.KEYBOARD_MODE_ENABLE(1),
        .LEGACY_VOICE_ENABLE(0),.ADDITIVE_BANK_ENABLE(0)) dut(
        .clk(clk),.reset_n(rst),.clock_enable(1'b1),.setting_pressed(setting),
        .key_pressed(keys),.remote_song_start(1'b0),.remote_select_request(1'b0),.remote_select_id(1'b0),
        .instrument_select(instrument),.tone_select(tone),.string_mode(strings),.keyboard_piano(piano));
    task ticks;repeat(3)@(negedge clk);endtask
    task press(input [2:0] mask);begin keys=mask;ticks();keys=0;ticks();end endtask
    task check(input integer selection);
        begin
            if(!piano || tone!=3 || strings!=(selection==1) || instrument!=(selection<2?0:selection-1))
                $fatal(1,"Menu selection=%0d tone=%0d bank=%0d strings=%b piano=%b",selection,tone,instrument,strings,piano);
        end
    endtask
    initial begin
        ticks();rst=1;ticks();check(0);setting=1;ticks();setting=0;ticks();press(1);press(1);
        if(dut.edit_field!=FIELD_TONE)$fatal(1,"Tone row unreachable");
        for(n=1;n<=10;n++)begin press(4);check(n%5);end
        for(n=9;n>=0;n--)begin press(2);check(n%5);end
        // Last extension row remains reachable, now advanced synthesis waveform.
        repeat(5)press(1);press(4);repeat(7)press(1);
        if(dut.edit_field!=FIELD_WAVEFORM)$fatal(1,"Advanced wave row missing");
        for(n=0;n<6;n++)begin
            press(4);if(tone!=n%3 || strings || instrument!=0 || !piano)$fatal(1,"Advanced wave/pitch independence");
        end
        press(1);if(dut.selected_field!=FIELD_TABS)$fatal(1,"Menu trapped");
        $display("PASS: five instruments both directions, persistent white-key pitch, advanced triangle/square/saw and tabs");$finish;
    end
    initial begin #100000;$fatal(1,"Instrument menu timeout");end
endmodule
