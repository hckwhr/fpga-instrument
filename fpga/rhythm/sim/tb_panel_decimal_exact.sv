`timescale 1ns/1ps
module tb_panel_decimal_exact;
    reg clk=0,reset_n=0,frame=0;
    always #5 clk=~clk;
    reg [11:0] position_value,length_value;
    reg [7:0] tempo_value,deadline_value;
    reg [6:0] force_value;
    reg [5:0] voice_value;
    integer value,layout,column;
    reg [15:0] expected;
    reg [7:0] actual_glyph,reference_glyph;
    reg [67:0] status_bus=0;
    reg [11:0] upload_bus=0;
    reg status_update=0,pixel_valid=0;
    reg [10:0] x=0;
    reg [9:0] y=0;
    wire [17:0] actual_rgb,reference_rgb;
    integer row,pixel;
    instrument_panel_renderer #(.UPLOAD_UI(1),.MULTI_TIMBRE_ENABLE(1),.LIGHT_UI_ENABLE(1)) dut(
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x),.next_active_x(x+11'd1),
        .active_y(y),.predecode_y(y),.data_enable(pixel_valid),
        .hsync_in(1'b0),.vsync_in(1'b0),.frame_start(frame),
        .audio_sample(16'd0),.audio_sample_valid(1'b0),
        .status_payload(status_bus),.status_update(status_update),.upload_status(upload_bus),
        .red(actual_rgb[17:12]),.green(actual_rgb[11:6]),.blue(actual_rgb[5:0]));
    // Frozen pre-change renderer retains the original constant dividers.
    baseline_decimal_panel #(.UPLOAD_UI(1),.MULTI_TIMBRE_ENABLE(1),.LIGHT_UI_ENABLE(1)) reference(
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x),.next_active_x(x+11'd1),
        .active_y(y),.predecode_y(y),.data_enable(pixel_valid),
        .hsync_in(1'b0),.vsync_in(1'b0),.frame_start(frame),
        .audio_sample(16'd0),.audio_sample_valid(1'b0),
        .status_payload(status_bus),.status_update(status_update),.upload_status(upload_bus),
        .red(reference_rgb[17:12]),.green(reference_rgb[11:6]),.blue(reference_rgb[5:0]));
    function [15:0] expected_decimal(input integer number);
        expected_decimal[15:12]=number/1000;
        expected_decimal[11:8]=(number/100)%10;
        expected_decimal[7:4]=(number/10)%10;
        expected_decimal[3:0]=number%10;
    endfunction
    task start_frame;
        @(negedge clk);frame=1;
        @(negedge clk);frame=0;
    endtask
    task await_digits;
        repeat(78)@(posedge clk);
        #1;
        if(dut.decimal_pending || dut.decimal_busy)$fatal(1,"78-clock deadline missed");
        if(dut.position_digits!==expected_decimal(position_value) ||
           dut.length_digits!==expected_decimal(length_value) ||
           {4'd0,dut.tempo_digits}!==expected_decimal(tempo_value) ||
           {4'd0,dut.deadline_digits}!==expected_decimal(deadline_value) ||
           {4'd0,dut.force_digits}!==expected_decimal(force_value) ||
           {8'd0,dut.voice_digits}!==expected_decimal(voice_value))
            $fatal(1,"shared converter mismatch position=%0d length=%0d",position_value,length_value);
    endtask
    initial begin
        force dut.song_position=position_value;
        force reference.song_position=position_value;
        force dut.song_length=length_value;
        force reference.song_length=length_value;
        force dut.tempo_bpm=tempo_value;
        force reference.tempo_bpm=tempo_value;
        force dut.string_deadline_misses=deadline_value;force reference.string_deadline_misses=deadline_value;
        force dut.force_value_active=force_value;force reference.force_value_active=force_value;
        force dut.polyphony_voice_count_active=voice_value;force reference.polyphony_voice_count_active=voice_value;
        force dut.audition_active=1'b1;
        force reference.audition_active=1'b1;
        force dut.audition_target=3'd7;
        force reference.audition_target=3'd7;
        force dut.uploaded_song=1'b1;
        force reference.uploaded_song=1'b1;
        position_value=0;length_value=0;tempo_value=0;deadline_value=0;force_value=0;voice_value=0;
        repeat(3)@(negedge clk);reset_n=1;
        start_frame();await_digits();
        @(negedge clk);position_value=4095;length_value=4095;
        start_frame();repeat(2)@(posedge clk);#1;
        if(dut.position_digits===16'h4095)$fatal(1,"early-use negative control failed");
        @(negedge clk);position_value=1234;length_value=2345;
        start_frame();await_digits();
        start_frame();repeat(7)@(negedge clk);reset_n=0;
        @(negedge clk);
        if(dut.decimal_busy || dut.decimal_pending)$fatal(1,"reset failed to abort conversion");
        reset_n=1;
        for(layout=0;layout<3;layout=layout+1)begin
            for(value=0;value<4096;value=value+1)begin
                @(negedge clk);position_value=value;
                // Exhaust every length and test both sides of the layout
                // boundary with every position, including out-of-range input.
                length_value=layout==0 ? 4095-value : layout==1 ? 999 : 1000;
                tempo_value=value[7:0];
                deadline_value=~value[7:0];force_value=value[6:0];voice_value=value[5:0];
                start_frame();await_digits();
                expected[15:12]=value/1000;
                expected[11:8]=(value/100)%10;
                expected[7:4]=(value/10)%10;
                expected[3:0]=value%10;
                if(dut.position_digits!==expected)
                    $fatal(1,"decimal mismatch value=%0d got=%h expected=%h",value,dut.position_digits,expected);
                for(column=0;column<20;column=column+1)begin
                    actual_glyph=dut.status_glyph(3'd0,column[4:0]);
                    reference_glyph=reference.status_glyph(3'd0,column[4:0]);
                    if(actual_glyph!==reference_glyph)
                        $fatal(1,"glyph mismatch pos=%0d len=%0d cell=%0d got=%0d expected=%0d",
                            position_value,length_value,column,actual_glyph,reference_glyph);
                end
            end
        end
        release dut.song_position;release reference.song_position;
        release dut.song_length;release reference.song_length;
        release dut.tempo_bpm;release reference.tempo_bpm;
        release dut.string_deadline_misses;release reference.string_deadline_misses;
        release dut.force_value_active;release reference.force_value_active;
        release dut.polyphony_voice_count_active;release reference.polyphony_voice_count_active;
        release dut.audition_active;release reference.audition_active;
        release dut.audition_target;release reference.audition_target;
        release dut.uploaded_song;release reference.uploaded_song;
        // Production snapshot ports: same-edge update/frame must use new data;
        // a later shadow update must NOT alter the frame being converted.
        @(negedge clk);
        status_bus=0;status_bus[49]=1;status_bus[53:51]=7;status_bus[47:46]=2;
        status_bus[43:36]=8'hd1;status_bus[12:5]=8'hff;
        upload_bus={4'h4,4'hf,4'b1010}; // index 1233 -> position 1234, length 4095
        status_update=1;frame=1;
        @(negedge clk);status_update=0;frame=0;
        repeat(3)@(negedge clk);
        status_bus[43:36]=99;status_bus[12:5]=8'he8;
        upload_bus={4'h0,4'h3,4'b1010};status_update=1; // next frame: 100/1000
        @(negedge clk);status_update=0;
        repeat(78)@(negedge clk);
        if(dut.position_digits!==16'h1234 || dut.length_digits!==16'h4095 || dut.tempo_digits!==12'h120)
            $fatal(1,"same-edge frame/update or stable-snapshot conversion failed");
        for(layout=0;layout<2;layout=layout+1)begin
            if(layout==1)begin
                start_frame();repeat(78)@(negedge clk);
                if(dut.position_digits!==16'h0100 || dut.length_digits!==16'h1000)
                    $fatal(1,"pending snapshot did not commit on next frame");
            end
            for(row=14;row<70;row=row+1)begin
                @(negedge clk);pixel_valid=0;x=2047;y=row;
                for(pixel=216;pixel<784;pixel=pixel+1)begin
                    @(negedge clk);pixel_valid=1;x=pixel;
                    @(posedge clk);#1;
                    if(actual_rgb!==reference_rgb)
                        $fatal(1,"song status pixel mismatch frame=%0d x=%0d y=%0d",layout,pixel,row);
                end
            end
            @(negedge clk);pixel_valid=0;
        end
        $display("PASS: six shared decimal fields exhaustive, all 4096 positions/lengths, 999/1000 layouts, 245760 frozen glyph comparisons, 78-clock deadline, early-use negative, frame restart/reset, same-edge snapshot and 63616 song pixels");
        $finish;
    end
    initial begin #20000000;$fatal(1,"decimal test timeout");end
endmodule
