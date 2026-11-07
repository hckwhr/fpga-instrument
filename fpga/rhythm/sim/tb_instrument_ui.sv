`timescale 1ns/1ps
// Images are actual RTL pixels, not a separate drawing of the intended design.
module tb_instrument_ui;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,frame=0,valid=0,update=0,audio_valid=0;
    reg [10:0] x=2047,next_x=0;
    reg [9:0] y=0;
    reg [67:0] status=DEFAULT_DISPLAY_STATUS;
    reg [11:0] extension=0;
    reg signed [15:0] audio=0;
    reg [1023:0] spectrum=0;
    wire [17:0] rgb,visual_rgb;
    reg [17:0] delayed_rgb=0;
    wire overlay;
    integer i,j,f,row,col,pixels=0,mode,bright=0,dark=0;
    reg [17:0] color;
    always #5 clk=~clk;
    always @(posedge clk)delayed_rgb<=rgb;
    instrument_panel_renderer #(.COMPACT_SCOPE(1),.UPLOAD_UI(1),.LIVE_KEYBOARD(1),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1),
        .MULTI_TIMBRE_ENABLE(1),.LIGHT_UI_ENABLE(1)) dut(
        .pixel_clk(clk),.reset_n(rst),.active_x(x),.next_active_x(next_x),.active_y(y),.predecode_y(y),
        .data_enable(valid),.hsync_in(1'b0),.vsync_in(1'b0),.frame_start(frame),
        .audio_sample(audio),.audio_sample_valid(audio_valid),.status_payload(status),
        .status_update(update),.upload_status(extension),.red(rgb[17:12]),.green(rgb[11:6]),.blue(rgb[5:0]));
    visual_feedback #(.LIGHT_UI_ENABLE(1)) visuals(
        .clk(clk),.reset_n(rst),.frame_start(frame),.enable(!status[ST_SETTING]),.x(x),.y(y),
        .spectrum(spectrum),.spectrum_update(update),.audio_pair({audio,audio}),
        .audio_pair_valid(audio_valid),.overlay(overlay),.rgb(visual_rgb));
    task commit;
        begin @(negedge clk);update=1;repeat(3)@(negedge clk);update=0;
            frame=1;@(negedge clk);frame=0;repeat(3)@(negedge clk);end
    endtask
    task pixel(input integer px,input integer py);
        begin
            @(negedge clk);valid=0;x=2047;next_x=px;y=py;
            @(negedge clk);valid=1;x=px;next_x=px+1;
            repeat(2)@(posedge clk);#1;color=overlay?visual_rgb:delayed_rgb;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=1;
        for(i=0;i<128;i++)spectrum[i*8+:8]=(i%16==3)?80:(i%7)*6;
        for(i=0;i<2048;i++)begin
            @(negedge clk);audio_valid=1;audio=$rtoi(5200*$sin(6.2831853*i/90.0));
        end
        @(negedge clk);audio_valid=0;
        status[ST_HELD_NOTES+:12]=12'h091;status[ST_VOICES+:6]=3;extension[5:4]=2;
        commit();commit();
        // Trace becomes active at the frame commit. Send a second burst through
        // the real delayed-pair path so the light phosphor palette is visible.
        for(i=0;i<2048;i++)begin
            @(negedge clk);audio_valid=1;audio=$rtoi(5200*$sin(6.2831853*i/90.0));
        end
        @(negedge clk);audio_valid=0;
        if(dut.status_glyph(0,9)!=139 || dut.status_glyph(0,11)!=141)$fatal(1,"Clarinet label missing");
        // A pending update must not tear the displayed instrument mid-frame.
        extension[5:4]=3;update=1;repeat(3)@(negedge clk);update=0;
        if(dut.instrument_active!=2)$fatal(1,"Instrument committed before frame edge");
        extension[5:4]=2;commit();
        for(i=0;i<12;i++)begin
            pixel(40+i*64,190);
            if(dut.piano_note_index!=i || dut.piano_note_is_black ||
                dut.piano_note_pressed!==status[ST_HELD_NOTES+i])$fatal(1,"White-key pixel identity %0d",i);
        end
        for(mode=0;mode<3;mode++)begin
            status[ST_SETTING]=mode!=0;status[ST_PAGE]=mode==2;
            status[ST_FIELD+:3]=mode==2 ? 3'd6 : 3'd1;commit();
            f=$fopen(mode==0?"sim/timbres_main.ppm":mode==1?"sim/timbres_settings.ppm":"sim/timbres_advanced.ppm","wb");
            if(!f)$fatal(1,"Cannot create pixel preview");
            $fwrite(f,"P6\n800 480\n255\n");
            for(row=0;row<480;row++)begin
                @(negedge clk);valid=0;x=2047;next_x=0;y=row;
                for(col=0;col<801;col++)begin
                    @(negedge clk);valid=col<800;x=col;next_x=col+1;
                    @(posedge clk);#1;
                    if(col!=0)begin
                        color=overlay?visual_rgb:delayed_rgb;
                        if((^color)===1'bx)$fatal(1,"Unknown rendered pixel %0d,%0d",col,row);
                        $fwrite(f,"%c%c%c",{color[17:12],color[17:16]},
                            {color[11:6],color[11:10]},{color[5:0],color[5:4]});
                        pixels++;
                        if(color[17:12]>50 && color[11:6]>50 && color[5:0]>50)bright++;
                        if(color[17:12]<24 && color[11:6]<30 && color[5:0]<32)dark++;
                    end
                end
            end
            $fclose(f);
        end
        if(pixels!=1152000 || bright<500000 || dark<10000)$fatal(1,"Light theme contrast/coverage");
        if(dut.settings_glyph(FIELD_WAVEFORM,1)!=143)$fatal(1,"Advanced field missing");
        $display("PASS: %0d actual RTL pixels, light surfaces=%0d dark detail=%0d, 12 white-key highlights, frame-atomic instrument labels",pixels,bright,dark);$finish;
    end
    initial begin #50000000;$fatal(1,"UI preview timeout");end
endmodule
