`timescale 1ns/1ps
// Accepted LCD renderer is the pixel oracle. Render once at native resolution,
// then compare every pixel of the HDMI dashboard's 2x raster, including both
// repeated columns and rows. The waveform RAM is filled through its real input.
module tb_hdmi_panel_equivalence;
    reg clk=0,reset_n=0,frame=0,valid=0;
    always #5 clk=~clk;
    `include "instrument_contract.vh"
    reg [10:0] x=0,next_x=1;
    reg [9:0] y=0;
    reg signed [15:0] sample=0;
    reg sample_valid=0;
    reg [67:0] status=DEFAULT_DISPLAY_STATUS;
    reg [11:0] upload=0;
    wire [17:0] old_rgb,new_rgb;
    lcd_test_pattern #(.COMPACT_SCOPE(1),.UPLOAD_UI(1),.LIVE_KEYBOARD(1),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1)) reference (
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x),.active_y(y),
        .data_enable(valid),.hsync_in(1'b0),.vsync_in(1'b0),
        .hsync_out(),.vsync_out(),.de_out(),.frame_start(frame),
        .audio_sample(sample),.audio_sample_valid(sample_valid),
        .status_payload(status),.status_update(1'b1),.upload_status(upload),
        .red(old_rgb[17:12]),.green(old_rgb[11:6]),.blue(old_rgb[5:0]));
    instrument_panel_renderer #(.COMPACT_SCOPE(1),.UPLOAD_UI(1),.LIVE_KEYBOARD(1),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1)) migrated (
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x),.next_active_x(next_x),.active_y(y),.predecode_y(y),
        .data_enable(valid),.hsync_in(1'b0),.vsync_in(1'b0),
        .hsync_out(),.vsync_out(),.de_out(),.frame_start(frame),
        .audio_sample(sample),.audio_sample_valid(sample_valid),
        .status_payload(status),.status_update(1'b1),.upload_status(upload),
        .red(new_rgb[17:12]),.green(new_rgb[11:6]),.blue(new_rgb[5:0]));
    reg [17:0] golden[0:383999];
    integer row,col,scenario,i,compared=0;
    task commit;
        @(negedge clk);valid=0;frame=1;
        @(negedge clk);frame=0;
        repeat(3)@(negedge clk);
    endtask
    initial begin
        repeat(3)@(negedge clk);reset_n=1;
        // A nonconstant trace detects wrong synchronous-RAM lookahead at
        // four-column sample boundaries; silence would hide address mistakes.
        for(i=0;i<256;i++)begin
            @(negedge clk);sample_valid=1;sample=$signed(8'(i-128))*128;
        end
        @(negedge clk);sample_valid=0;
        commit();commit(); // settle the peak meter while retaining the trace
        if(!reference.display_valid || !migrated.display_valid)
            $fatal(1,"Waveform capture did not commit");
        for(scenario=0;scenario<3;scenario++)begin
            status[ST_SETTING]=(scenario!=0);
            status[ST_PAGE]=(scenario==2);
            status[ST_FIELD +: 3]=scenario;
            commit();
            // Native 800x480 reference. Coordinate 0 is prefetched during
            // the blank pixel immediately preceding each line.
            for(row=0;row<480;row++)begin
                @(negedge clk);valid=0;x=2047;next_x=0;y=row;
                for(col=0;col<800;col++)begin
                    @(negedge clk);valid=1;x=col;next_x=col+1;
                    @(posedge clk);#1;
                    if(old_rgb!==new_rgb)$fatal(1,"Native renderer changed x=%0d y=%0d",col,row);
                    golden[row*800+col]=old_rgb;
                end
            end
            for(row=0;row<960;row++)begin
                @(negedge clk);valid=0;x=2047;next_x=0;y=row/2;
                for(col=0;col<1600;col++)begin
                    @(negedge clk);valid=1;x=col/2;next_x=(col+1)/2;
                    @(posedge clk);#1;
                    if(new_rgb!==golden[(row/2)*800+col/2])
                        $fatal(1,"2x dashboard mismatch scenario=%0d x=%0d y=%0d got=%h expected=%h",
                            scenario,col,row,new_rgb,golden[(row/2)*800+col/2]);
                    compared++;
                end
            end
        end
        // Negative control: violate the one-edge predecode lead by changing Y
        // directly on an already-visible title-border pixel, without a blank
        // prefetch edge. The old combinational renderer sees the new row now;
        // the line cache must lag exactly this pixel. This must be observable,
        // otherwise this bench would not detect a missing predecode connection.
        @(negedge clk);valid=1;x=64;next_x=65;y=12;
        @(posedge clk);#1;
        if(new_rgb===old_rgb)$fatal(1,"Negative row-prefetch control failed to diverge");
        @(posedge clk);#1;
        if(new_rgb!==old_rgb)$fatal(1,"Row metadata did not recover after one capture edge");
        $display("PASS: %0d scaled dashboard pixels match accepted LCD, main view and both menu pages; nonconstant synchronous waveform history; missing-row-prefetch negative control detected",compared);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Dashboard equivalence timeout");end
endmodule
