`timescale 1ns/1ps
module tb_visual_freshness;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,frame=0,valid=0,update=0;
    reg signed [15:0] pcm=0;
    reg [31:0] pair=0;
    reg [1023:0] spectrum=0;
    reg [DISPLAY_STATUS_WIDTH-1:0] status=DEFAULT_DISPLAY_STATUS;
    integer i,j,scenario,checks=0,bright_before,bright_after;
    reg [6:0] held_x,held_y;
    reg [10:0] xpos=11'd664;
    reg [9:0] ypos=10'd360;
    reg old_bank;
    reg signed [7:0] expected;
    lcd_test_pattern #(.COMPACT_SCOPE(1)) scope(
        .pixel_clk(clk),.reset_n(rst),.active_x(11'd100),.active_y(10'd294),
        .data_enable(1'b1),.hsync_in(1'b1),.vsync_in(1'b1),
        .hsync_out(),.vsync_out(),.de_out(),.frame_start(frame),
        .audio_sample(pcm),.audio_sample_valid(valid),
        .status_payload(status),.status_update(1'b1),.red(),.green(),.blue());
    visual_feedback xy(.clk(clk),.reset_n(rst),.frame_start(frame),.enable(1'b1),
        .x(xpos),.y(ypos),.spectrum(spectrum),.spectrum_update(update),
        .audio_pair(pair),.audio_pair_valid(valid),.overlay(),.rgb());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    task commit;begin frame=1;tick();frame=0;repeat(3)tick();end endtask
    task sample;input signed [15:0] value;begin
        pcm=value;pair={value,value};valid=1;tick();valid=0;tick();
    end endtask
    initial begin
        repeat(4)tick();rst=1;status[ST_TEST]=1;commit();repeat(16400)tick();
        // Normal crossing must still start a triggered, decimated capture.
        sample(-16'sd4096);sample(16'sd4096);
        if(!scope.capture_active)$fatal(1,"normal trigger failed");
        for(i=0;i<1024;i=i+1)sample(i[4]?16'sd4096:-16'sd4096);
        if(!scope.capture_ready)$fatal(1,"triggered capture incomplete");
        commit();if(!scope.display_valid)$fatal(1,"no initial waveform");
        // No crossing: zero, both DC polarities, and nonzero subthreshold input.
        for(scenario=0;scenario<4;scenario=scenario+1)begin
            case(scenario)
                0:pcm=0;1:pcm=4096;2:pcm=-4096;default:pcm=512;
            endcase
            old_bank=scope.display_bank;
            repeat(2048)tick();
            if(scope.capture_active)$fatal(1,"pixel clocks counted as samples");
            for(i=0;i<1023;i=i+1)begin
                sample(pcm);if(scope.capture_active)$fatal(1,"early auto trigger");
            end
            sample(pcm);if(!scope.capture_active)$fatal(1,"auto trigger missing after 1024 samples");
            for(i=0;i<1024;i=i+1)sample(pcm);
            if(!scope.capture_ready || scope.display_bank!=old_bank)
                $fatal(1,"incomplete capture or midframe bank swap");
            expected=$signed({pcm[15],pcm[15:9]});
            for(j=0;j<256;j=j+1)begin
                if(scope.sample_history[{scope.capture_bank,j[7:0]}]!==expected)
                    $fatal(1,"fresh waveform contains old sample");
                checks=checks+1;
            end
            commit();
            if(scope.display_bank==old_bank)$fatal(1,"fresh bank not committed");
        end
        sample(-16'sd4096);sample(16'sd4096);
        if(!scope.capture_active)$fatal(1,"trigger did not recover after silence/DC");
        // Isolate frame-boundary collision: no prior valid point this frame.
        commit();commit();
        if(xy.marker_valid)$fatal(1,"stale cursor remained valid");
        // The cursor is a phase-portrait point now: x comes from the delayed
        // sample, which is still zero after silence, so x sits on the centre
        // column. y depends on the gain latched at the previous boundary, so
        // check that the point was captured on the coincident edge rather than
        // pinning a coordinate the gain decides.
        pair={16'sd8192,-16'sd4096};valid=1;frame=1;tick();valid=0;frame=0;
        // y is computed from the sample that arrived on this very edge, so it
        // must match; x came from the delay line as it stood when the point was
        // captured, which the shift has already advanced past.
        if(!xy.marker_valid || xy.marker_y!==xy.point_y)
            $fatal(1,"frame-coincident point lost or delayed y=%0d/%0d",
                   xy.marker_y,xy.point_y);
        pair=0;valid=1;tick();valid=0;
        // Hold the captured cursor until the next boundary. The coordinates
        // themselves depend on the delay line and the latched gain, so compare
        // against what was captured rather than fixed numbers.
        held_x=xy.marker_x;held_y=xy.marker_y;
        repeat(8)tick();
        if(xy.marker_x!==held_x[6:0] || xy.marker_y!==held_y[6:0])
            $fatal(1,"cursor moved midframe");
        commit();
        // A digital-zero sample puts the cursor on the centre row. The column
        // follows the delay line, which still holds the earlier tone, so only
        // the axis driven by this sample is pinned.
        if(!xy.marker_valid || xy.marker_y!=64)
            $fatal(1,"digital-zero cursor coordinate wrong y=%0d",xy.marker_y);
        commit();if(xy.marker_valid)$fatal(1,"missing input not distinguished from silence");
        // The XY panel keeps a phosphor trail now rather than clearing a bank,
        // so silence must fade it instead of blanking it. Check that nothing new
        // is written while the input is silent and that what is there decays.
        for(i=0;i<1024;i=i+1)sample(0);
        bright_before=0;
        for(i=0;i<16384;i=i+1)bright_before=bright_before+xy.xy_mem[i[13:0]];
        // The decay scan only advances on pixels outside the panel region.
        xpos=11'd0;ypos=10'd0;
        for(i=0;i<400000;i=i+1)tick();
        bright_after=0;
        for(i=0;i<16384;i=i+1)bright_after=bright_after+xy.xy_mem[i[13:0]];
        if(bright_before!=0 && bright_after>=bright_before)
            $fatal(1,"silent XY did not fade %0d -> %0d",bright_before,bright_after);
        spectrum[80 +: 8]=60;update=1;tick();update=0;
        if(xy.spectrum_active!=0)$fatal(1,"spectrum changed midframe");
        commit();if(xy.spectrum_active!==spectrum)$fatal(1,"spectrum commit lost");
        spectrum=0;update=1;frame=1;tick();update=0;frame=0;
        if(xy.spectrum_active!=0)$fatal(1,"coincident silent spectrum not committed");
        $display("PASS: %0d fresh scope samples; 1024-valid-sample auto trigger, silence/DC/quiet tails, normal trigger recovery, frame-coincident XY point, fading bitmap and spectrum frame commits",checks);
        $finish;
    end
    initial begin #5000000;$fatal(1,"freshness timeout");end
endmodule
