`timescale 1ns/1ps
`default_nettype none
// Real key sequence into and out of the all-engine self-test, at the control
// module: the second KEY2 press on the polyphony row selects it, and every way
// of leaving the self-test also clears it.
module tb_concurrent_entry;
    reg clk = 0, reset_n = 0, setting = 0;
    reg [2:0] keys = 0;
    always #5 clk = ~clk;
    wire setting_mode, settings_page, test_mode, test_polyphony, test_concurrent;
    wire [2:0] selected_field;
    instrument_control #(.PLAY_GUARD_CYCLES(5), .PLAY_GUARD_COUNTER_WIDTH(3)) dut (
        .clk(clk), .reset_n(reset_n), .key_pressed(keys), .setting_pressed(setting),
        .remote_song_start(1'b0), .setting_mode(setting_mode), .settings_page(settings_page),
        .selected_field(selected_field), .test_mode(test_mode),
        .test_polyphony(test_polyphony), .test_concurrent(test_concurrent));

    integer checks = 0;
    task press; input integer key; begin
        @(negedge clk); if (key == 3) setting = 1; else keys[key] = 1;
        repeat (2) @(negedge clk); setting = 0; keys = 0;
        repeat (3) @(negedge clk);
    end endtask
    task expect; input mode; input poly; input concurrent; input [8*40-1:0] what; begin
        checks = checks + 1;
        if (test_mode !== mode || test_polyphony !== poly || test_concurrent !== concurrent) begin
            $display("# ERROR: %0s: test_mode=%b polyphony=%b concurrent=%b, wanted %b %b %b",
                     what, test_mode, test_polyphony, test_concurrent, mode, poly, concurrent);
            $finish;
        end
    end endtask
    // The concurrent flag may never be set while the self-test itself is off
    // for more than the one clock the register takes to follow it down.
    reg stray = 0;
    always @(posedge clk) begin
        if (reset_n && test_concurrent && !test_mode && stray) begin
            $display("# ERROR: test_concurrent outlived test_mode"); $finish;
        end
        stray <= test_concurrent && !test_mode;
    end

    initial begin
        repeat (3) @(negedge clk); reset_n = 1;
        press(3);                                   // enter the menu, on the tabs
        press(2);                                   // extension page
        if (!setting_mode || !settings_page) begin $display("# ERROR: menu navigation"); $finish; end
        press(0); press(0); press(0);               // rows 0, 1, 2 (additive)
        press(2); expect(1, 0, 0, "additive first press");
        press(2); expect(1, 0, 0, "additive second press");
        press(0);                                   // row 3 (polyphony)
        press(2); expect(1, 1, 0, "polyphony first press");
        press(2); expect(1, 1, 1, "polyphony second press");
        press(2); expect(1, 1, 0, "polyphony third press");
        press(2); expect(1, 1, 1, "polyphony fourth press");
        press(1); expect(0, 1, 0, "KEY1 stops the self-test");
        press(2); press(2); expect(1, 1, 1, "re-armed");
        press(3);                                   // leave the menu: it runs
        if (setting_mode) begin $display("# ERROR: still in menu"); $finish; end
        expect(1, 1, 1, "running outside the menu");
        press(3);                                   // re-enter: self-test ends
        expect(0, 1, 0, "menu entry stops it");
        press(0); press(0); press(0); press(0);     // tabs is row 7; walk back to polyphony
        $display("# PASS: %0d state checks; second KEY2 on the polyphony row toggles the all-engine self-test, every exit clears it", checks);
        $finish;
    end
endmodule
`default_nettype wire
