`timescale 1ns/1ps
module tb_song_lcd;
    `include "instrument_contract.vh"
    reg clk=0,reset_n=0,frame_start=0,status_update=0;
    reg [DISPLAY_STATUS_WIDTH-1:0] payload=DEFAULT_DISPLAY_STATUS;
    reg [10:0] x=0;
    reg [9:0] y=0;
    wire [5:0] r,g,b;
    integer i,px,py,fd;
    lcd_test_pattern #(.COMPACT_SCOPE(1)) dut(
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x),.active_y(y),
        .data_enable(1'b1),.hsync_in(1'b1),.vsync_in(1'b1),.frame_start(frame_start),
        .audio_sample(16'sd0),.audio_sample_valid(1'b0),.status_payload(payload),.status_update(status_update),
        .red(r),.green(g),.blue(b),.hsync_out(),.vsync_out(),.de_out());
    always #5 clk=~clk;
    task commit;begin
        @(negedge clk);status_update=1;@(negedge clk);status_update=0;
        @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
    end endtask
    task snapshot; input [8*80-1:0] path;
        begin
            fd=$fopen(path,"w");if(!fd)$fatal(1,"image capture failed");
            $fwrite(fd,"P3\n800 480\n63\n");
            for(py=0;py<480;py=py+1)for(px=0;px<800;px=px+1)begin
                @(negedge clk);x=px;y=py;@(posedge clk);#1;
                if((^{r,g,b})===1'bx)$fatal(1,"unknown song pixel");
                $fwrite(fd,"%0d %0d %0d\n",r,g,b);
            end
            $fclose(fd);
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);reset_n=1;
        payload[ST_SETTING]=1;payload[ST_PAGE]=1;payload[ST_FIELD+:3]=6;
        payload[ST_AUDITION_TARGET+:3]=7;payload[ST_AUDITION_ARMED]=1;
        payload[ST_SONG_TEMPO+:2]=1;
        commit();
        if(dut.settings_glyph(FIELD_AUDITION,0)!=122 || dut.settings_glyph(FIELD_AUDITION,10)!=124 ||
           dut.settings_glyph(FIELD_AUDITION,12)!=125)$fatal(1,"missing Chinese song name");
        snapshot("sim/song_menu.ppm");
        payload[ST_SETTING]=0;payload[ST_AUDITION_ACTIVE]=1;
        payload[ST_PLAY_MODE]=0;payload[ST_KEYMAP]=0;payload[ST_KEYS+:3]=1;
        payload[ST_NOTE+:4]=7;payload[ST_DEADLINES+:8]=2;
        payload[ST_SONG_LENGTH+:8]=85;
        payload[ST_HELD_NOTES+:12]=12'h080;
        commit();
        if(dut.status_glyph(0,0)!=124 || dut.status_glyph(0,1)!=125 || dut.status_glyph(0,5)!=21 ||
           dut.status_glyph(0,15)!=36)$fatal(1,"song title/status/progress wrong");
        x=490;y=210;#1;if(!dut.piano_note_pressed)$fatal(1,"G key not highlighted");
        x=50;#1;if(dut.piano_note_pressed)$fatal(1,"wrong C key highlighted");
        snapshot("sim/song_playing.ppm");
        payload[ST_KEYS+:3]=0;payload[ST_AUDITION_WET]=1;payload[ST_DEADLINES+:8]=84;
        payload[ST_HELD_NOTES+:12]=12'd0;
        @(negedge clk);status_update=1;@(negedge clk);status_update=0;
        if(dut.status_glyph(0,5)!=21)$fatal(1,"song status changed mid-frame");
        @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
        if(dut.status_glyph(0,5)!=63 || dut.status_glyph(0,14)!=41 || dut.status_glyph(0,15)!=38)
            $fatal(1,"stopped 085/085 status wrong");
        payload[ST_SONG_SELECT]=1;payload[ST_DEADLINES+:8]=0;payload[ST_AUDITION_WET]=0;
        payload[ST_NOTE+:4]=4;payload[ST_KEYS+:3]=1;
        payload[ST_SONG_LENGTH+:8]=30;
        payload[ST_HELD_NOTES+:12]=12'h010;
        @(negedge clk);status_update=1;@(negedge clk);status_update=0;
        if(dut.status_glyph(0,0)!=124)$fatal(1,"title changed before frame boundary");
        @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
        if(dut.status_glyph(0,0)!=126 || dut.status_glyph(0,1)!=127 || dut.status_glyph(0,2)!=128 ||
           dut.status_glyph(0,18)!=36 || dut.status_glyph(0,19)!=33)$fatal(1,"Ode title/030 total wrong");
        if(dut.status_glyph(0,9)!=34 || dut.status_glyph(0,10)!=33 || dut.status_glyph(0,11)!=33)
            $fatal(1,"100 BPM missing");
        if(dut.status_glyph(1,0)!=33 || dut.status_glyph(1,1)!=78 || dut.status_glyph(1,2)!=0)
            $fatal(1,"missing K0 song selection help");
        for(i=0;i<24;i=i+1) if(dut.font_memory[4096+i]!==dut.chinese_font_row(8'd128,i))
            $fatal(1,"extended glyph ROM disagrees");
        snapshot("sim/song_ode_playing.ppm");
        payload[ST_SETTING]=1;payload[ST_AUDITION_ACTIVE]=0;
        payload[ST_AUDITION_WET]=1;payload[ST_DEADLINES+:8]=0;commit();
        if(dut.settings_glyph(FIELD_AUDITION,10)!=126 || dut.settings_glyph(FIELD_AUDITION,12)!=128)
            $fatal(1,"menu lost selected song title");
        snapshot("sim/song_ode_menu.ppm");
        payload[ST_SONG_ACCOMPANIMENT]=1;commit();
        if(dut.settings_glyph(FIELD_AUDITION,6)!=133 || dut.settings_glyph(FIELD_AUDITION,7)!=5)
            $fatal(1,"missing accompaniment setting label");
        snapshot("sim/song_ensemble_menu.ppm");
        payload[ST_SETTING]=0;payload[ST_AUDITION_ACTIVE]=1;
        payload[ST_AUDITION_WET]=0;
        payload[ST_VOICES+:6]=5;payload[ST_HELD_NOTES+:12]=12'h091;commit();
        if(dut.status_glyph(0,3)!=133 || dut.status_glyph(1,13)!=38 ||
           dut.status_glyph(1,15)!=36 || dut.status_glyph(1,16)!=35)
            $fatal(1,"accompaniment title or 05/32 missing");
        for(i=17;i<21;i=i+1)if(dut.status_glyph(1,i)!=0)
            $fatal(1,"song text overlaps digital level meter");
        snapshot("sim/song_ensemble_playing.ppm");
        payload[ST_SONG_SELECT]=0;payload[ST_SONG_LENGTH+:8]=84;commit();
        if(dut.status_glyph(0,18)!=41 || dut.status_glyph(0,19)!=37)
            $fatal(1,"data-driven Twinkle accompaniment length wrong");
        snapshot("sim/song_twinkle_ensemble_playing.ppm");
        payload[ST_SONG_LENGTH+:8]=255;commit();
        if(dut.status_glyph(0,17)!=35 || dut.status_glyph(0,18)!=38 || dut.status_glyph(0,19)!=38)
            $fatal(1,"three-digit data-driven total wrong");
        payload[ST_SETTING]=0;payload[ST_AUDITION_ACTIVE]=1;payload[ST_DEADLINES+:8]=254;commit();
        if(dut.status_glyph(0,13)!=35 || dut.status_glyph(0,14)!=38 || dut.status_glyph(0,15)!=38)
            $fatal(1,"255 position wraps");
        $display("PASS: song titles, three-digit progress, 100 BPM, extended font, note highlight and frame-atomic selection");
        $finish;
    end
endmodule
