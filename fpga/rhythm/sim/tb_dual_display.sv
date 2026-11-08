`timescale 1ns/1ps
module tb_dual_display;
    reg clk=0,audio_clk=0,locked=0;
    always #15 clk=~clk;
    always #10.172414 audio_clk=~audio_clk;
    reg [79:0] status=0;
    wire pclk,hs,vs,de,bl;wire [5:0] r,g,b;
    lcd_settings_display lcd(.sys_clk(clk),.audio_clk(audio_clk),.audio_reset_n(locked),
        .clock_enable(1'b1),.status_audio(status),.lcd_pclk(pclk),.lcd_hsync(hs),
        .lcd_vsync(vs),.lcd_de(de),.lcd_bl(bl),.lcd_r(r),.lcd_g(g),.lcd_b(b));
    reg frame=0,update=0;reg[10:0]x=0;reg[9:0]y=0;
    reg[67:0]stage_status=0;reg[12:0]guide=0;
    wire[17:0]stage_rgb;
    reg [1023:0] spectrum=0;reg [31:0] audio_pair=0;reg audio_valid=0;
    wire overlay;wire [17:0] visual_rgb;
    visual_feedback #(.LIGHT_UI_ENABLE(1),.PERFORMANCE_UI(1)) visuals(
        .clk(clk),.reset_n(locked),.frame_start(frame),.enable(1'b1),.x(x),.y(y),
        .spectrum(spectrum),.spectrum_update(update),.audio_pair(audio_pair),
        .audio_pair_valid(audio_valid),.overlay(overlay),.rgb(visual_rgb));
    performance_stage_renderer stage(.clk(clk),.reset_n(locked),.frame_start(frame),
        .status_update(update),.x(x),.y(y),.de(1'b1),.status_payload(stage_status),
        .guide_payload(guide),.rgb(stage_rgb));
    integer pixels=0,rows=0,cycles=0,nonwhite=0,frames=0;
    reg de_d=0;
    always @(negedge clk) if(bl)begin
        if(de)begin pixels++;if({r,g,b}!==18'h3ffff)nonwhite++;end
        if(de_d&&!de)rows++;
        de_d=de;
    end
    task point(input integer px,py,input[17:0]expected);
        begin @(negedge clk);x=px;y=py;@(posedge clk);#1;
            if(stage_rgb!==expected)$fatal(1,"stage pixel %0d,%0d expected %h got %h",px,py,expected,stage_rgb);
        end
    endtask
    task visual_point(input integer px,py,input[17:0]expected);
        begin @(negedge clk);x=px;y=py;repeat(3)@(posedge clk);#1;
            if(!overlay || visual_rgb!==expected)$fatal(1,"visual pixel %0d,%0d expected %h got %h marker=%b,%0d,%0d read=%0d,%0d live=%b,%0d,%0d",px,py,expected,visual_rgb,visuals.marker_valid,visuals.marker_x,visuals.marker_y,visuals.read_x,visuals.read_y,visuals.live_valid,visuals.live_x,visuals.live_y);
        end
    endtask
    initial begin
        force lcd.clk=clk;force lcd.locked=locked;
        repeat(5)@(negedge clk);locked=1;
        wait(bl);@(negedge clk);frame=1;update=1;
        @(negedge clk);frame=0;update=0;
        point(400,80,18'h3ffff);
        point(30,180,{6'd63,6'd63,6'd61});
        @(negedge clk);stage_status[56]=1;update=1;@(negedge clk);update=0;
        point(30,180,{6'd63,6'd63,6'd61}); // pending until frame boundary
        @(negedge clk);frame=1;@(negedge clk);frame=0;
        point(30,180,{6'd31,6'd48,6'd44});
        // A setting field in the held-key slot must not illuminate key 12.
        @(negedge clk);stage_status=68'd1<<23 | 68'd1<<67;frame=1;update=1;
        @(negedge clk);frame=0;update=0;
        point(750,180,{6'd63,6'd63,6'd61});
        @(negedge clk);spectrum[8+:8]=50;update=1;frame=1;
        @(negedge clk);update=0;frame=0;
        visual_point(20,420,{6'd12,6'd32,6'd55}); // blue spectrum, no palette conversion
        visual_point(100,240,18'h3ffff); // old text header is now blank paper
        @(negedge clk);audio_valid=1;audio_pair=0;
        @(negedge clk);audio_valid=0;frame=1;
        @(negedge clk);frame=0;
        visual_point(664,360,{6'd35,6'd14,6'd50}); // live XY cursor is purple
        wait(lcd.frame);@(negedge clk);
        // Skip startup partial frame and count two complete independent rasters.
        repeat(2)begin
            pixels=0;rows=0;nonwhite=0;
            repeat(1057*526)@(negedge clk);
            #1; // Let the raster monitor sample the final edge before assertions.
            if(pixels!=800*480 || rows!=480 || nonwhite==0)
                $fatal(1,"LCD raster pixels=%0d rows=%0d content=%0d",pixels,rows,nonwhite);
        end
        if(!lcd.u_menu.status_active[23])$fatal(1,"LCD did not keep settings page");
        locked=0;#1;if(bl || de)$fatal(1,"LCD unsafe on lock loss");
        $display("PASS: dual display 800x480 LCD settings raster, HDMI white/blue/purple pixels, frame-atomic keys, settings mask, reset blanking");$finish;
    end
    initial begin #80000000;$fatal(1,"dual display timeout");end
endmodule
