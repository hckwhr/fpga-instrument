`timescale 1ns/1ps
module tb_string_menu;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,setting=0;
    reg [2:0] keys=0;
    always #5 clk=~clk;
    wire settings,strings,audition,song,test_active,test_poly,test_concurrent;
    wire [2:0] target;
    instrument_control #(.LEGACY_VOICE_ENABLE(0),.ADDITIVE_BANK_ENABLE(0),
        .STRING_BANK_ENABLE(1)) dut(.clk(clk),.reset_n(rst),.clock_enable(1'b1),
        .key_pressed(keys),.setting_pressed(setting),.remote_song_start(1'b0),
        .setting_mode(settings),.string_mode(strings),.audition_active(audition),
        .song_active(song),.audition_target(target),.self_test_active(test_active),
        .test_polyphony(test_poly),.test_concurrent(test_concurrent));
    task ticks;repeat(3)@(negedge clk);endtask
    task press(input [2:0] mask);begin keys=mask;ticks();keys=0;ticks();end endtask
    task menu;begin setting=1;ticks();setting=0;ticks();end endtask
    integer i,start_target;
    initial begin
        ticks();rst=1;ticks();
        if(target!=7)$fatal(1,"Default score target changed");
        menu();press(4); // extension tab
        // All six visible extension rows; additive is absent, string is present.
        for(i=0;i<6;i++)begin
            press(1);
            if(dut.edit_field==FIELD_ADDITIVE)$fatal(1,"Additive menu restored accidentally");
            press(4);
            if(dut.edit_field==FIELD_STRING && !strings)$fatal(1,"String entry missing");
            if(dut.edit_field==FIELD_POLYPHONY && (!test_poly||!test_concurrent))
                $fatal(1,"32-note event self-test not selected immediately");
        end
        if(dut.edit_field!=FIELD_AUDITION)$fatal(1,"Wrong final extension row");
        // KEY1 must leave score and visit every supported target, including
        // wraparound. The old per-clock clamp fails on the first iteration.
        start_target=target;
        for(i=0;i<8;i++)begin
            press(2);
            if(target!=((start_target+i+1)%8))$fatal(1,"Audition selection stuck");
        end
        while(target!=7)press(2);
        press(4);menu();
        if(!audition || !song || target!=7)$fatal(1,"Remaining audition does not play score");
        $display("PASS: string menu, additive hidden, all eight audition choices/wraparound, score audition and 32-note event self-test retained");
        $finish;
    end
    initial begin #100000;$fatal(1,"String menu timeout");end
endmodule
