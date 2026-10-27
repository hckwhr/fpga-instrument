`timescale 1ns/1ps
module tb_song_progress4096;
    reg pixel_clk=0,reset_n=0,frame_start=0,status_update=0;
    always #10 pixel_clk=~pixel_clk;
    reg [67:0] status_payload=0;
    reg [11:0] upload_status=0;
    lcd_test_pattern #(.UPLOAD_UI(1)) dut (
        .pixel_clk(pixel_clk),.reset_n(reset_n),.frame_start(frame_start),.status_update(status_update),
        .status_payload(status_payload),.upload_status(upload_status),.active_x(11'd0),.active_y(10'd0),
        .data_enable(1'b0),.hsync_in(1'b0),.vsync_in(1'b0),.audio_sample(16'd0),.audio_sample_valid(1'b0));
    task automatic show(input integer index,input integer length);
        begin
            @(negedge pixel_clk);status_payload[43:36]=index[7:0];status_payload[12:5]=length[7:0];
            upload_status={index[11:8],length[11:8],4'b1010};status_update=1;
            @(negedge pixel_clk);status_update=0;
            repeat(3)@(negedge pixel_clk);frame_start=1;
            @(negedge pixel_clk);frame_start=0;
            if(dut.song_position!==index+1 || dut.song_length!==length)$fatal(1,"LCD full progress wrong index=%d length=%d",index,length);
        end
    endtask
    initial begin
        repeat(3)@(negedge pixel_clk);reset_n=1;
        status_payload[49]=1;status_payload[53:51]=7;
        show(254,2048);show(255,2048);show(256,2048);show(1023,2048);show(2047,2048);
        if(dut.status_glyph(0,11)!==dut.digit_glyph(2) || dut.status_glyph(0,12)!==dut.digit_glyph(0) ||
           dut.status_glyph(0,13)!==dut.digit_glyph(4) || dut.status_glyph(0,14)!==dut.digit_glyph(8) ||
           dut.status_glyph(0,16)!==dut.digit_glyph(2) || dut.status_glyph(0,19)!==dut.digit_glyph(8))
            $fatal(1,"LCD four-digit glyphs wrong");
        $display("PASS: LCD 255/256/257 and 2048 progress, full count and four-digit glyphs");$finish;
    end
endmodule
