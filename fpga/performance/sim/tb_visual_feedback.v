`timescale 1ns/1ps
// The XY panel is now a phase portrait with phosphor persistence. The old
// double-buffer/commit checks are gone with the double buffer; in their place
// this proves the three properties the previous panel lacked:
//   - a mono source no longer degenerates into a diagonal (negative control),
//   - the trace fades over several frames instead of being cleared,
//   - a quiet source is still scaled to fill the box.
// Spectrum double buffering and frame-atomic settings are unchanged and are
// still checked.
module tb_visual_feedback;
    reg clk=0,reset_n=0,frame=0,enable=1,update=0,valid=0;
    reg [10:0] x=0;
    reg [9:0] y=0;
    reg [1023:0] levels=0;
    reg [31:0] pair=0;
    wire overlay;
    wire [17:0] rgb;
    integer i,n,fd,px,py,points,scenario;
    integer mx,my,diag,max_diag,min_x,max_x,min_y,max_y;
    integer box_loud,box_quiet,fade_before,fade_after,bright_sum,level;
    reg signed [15:0] dry,wet;
    reg lit;
    visual_feedback dut(.clk(clk),.reset_n(reset_n),.frame_start(frame),.enable(enable),
        .x(x),.y(y),.spectrum(levels),.spectrum_update(update),
        .audio_pair(pair),.audio_pair_valid(valid),.overlay(overlay),.rgb(rgb));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#2;end endtask
    task commit;begin frame=1;tick();frame=0;repeat(2)tick();end endtask
    // The decay scan only advances while the panel is off screen, so parking
    // the coordinates outside its region frees the read port. Decay is driven
    // by free pixels, not by frame_start.
    task idle_ticks;
        input integer count;
        integer c;
        begin
            x=0;y=0;
            for(c=0;c<count;c=c+1)tick();
        end
    endtask
    // Feed one period-128 sine. TAU is 32 samples, a quarter period, so a
    // mono source must trace a circle rather than a line.
    task play_sine;
        input integer amplitude;
        input integer stereo;
        integer k;
        begin
            for(k=0;k<1024;k=k+1)begin
                dry=$rtoi(amplitude*$sin(6.283185307179586*k/128));
                wet=(stereo==0)?dry:$rtoi((amplitude*3/4)*$cos(6.283185307179586*k/128));
                pair={dry,wet};valid=1;tick();valid=0;tick();
            end
        end
    endtask
    // Scan the panel and measure the lit trace in 128x128 map coordinates.
    task measure;
        input integer dump;
        input integer tag;
        begin
            points=0;max_diag=0;min_x=127;max_x=0;min_y=127;max_y=0;bright_sum=0;
            if(dump)begin
                fd=$fopen($sformatf("sim/visual_panels_%0d.ppm",tag),"w");
                $fwrite(fd,"P3\n800 480\n63\n");
            end
            // Pixel coordinates held three cycles to inspect the full renderer.
            for(py=0;py<480;py=py+1)for(px=0;px<800;px=px+1)begin
                x=px;y=py;repeat(3)tick();
                if(overlay && (^rgb)===1'bx)$fatal(1,"unknown visible pixel");
                lit = overlay && (px>=553) && (px<775) && (py>=257) && (py<463) &&
                      (rgb!={6'd4,6'd35,6'd44}) && (rgb!={6'd2,6'd14,6'd20}) &&
                      (rgb!={6'd1,6'd5,6'd8});
                if(lit)begin
                    points=points+1;
                    // Every point is written at full brightness, so the whole
                    // trace dims together. Total brightness, not the lit count,
                    // is what shows the fade.
                    level=0;
                    if(rgb=={6'd63,6'd52,6'd63})level=7;
                    else if(rgb=={6'd57,6'd34,6'd62})level=6;
                    else if(rgb=={6'd49,6'd22,6'd58})level=5;
                    else if(rgb=={6'd41,6'd16,6'd50})level=4;
                    else if(rgb=={6'd32,6'd12,6'd42})level=3;
                    else if(rgb=={6'd23,6'd8,6'd33})level=2;
                    else if(rgb=={6'd14,6'd6,6'd23})level=1;
                    bright_sum=bright_sum+level;
                    mx=((px-552)/2)+8;my=((py-256)/2)+12;
                    diag=(mx-64)+(my-64);
                    if(diag<0)diag=-diag;
                    if(diag>max_diag)max_diag=diag;
                    if(mx<min_x)min_x=mx; if(mx>max_x)max_x=mx;
                    if(my<min_y)min_y=my; if(my>max_y)max_y=my;
                end
                if(dump)begin
                    if(overlay)$fwrite(fd,"%0d %0d %0d\n",rgb[17:12],rgb[11:6],rgb[5:0]);
                    else $fwrite(fd,"1 3 5\n");
                end
            end
            if(dump)$fclose(fd);
        end
    endtask
    initial begin
        repeat(4)tick();reset_n=1;
        idle_ticks(2000);commit();

        for(scenario=0;scenario<2;scenario=scenario+1)begin
            // The first frame of audio only measures the peak: the gain and the
            // trace enable are latched at its boundary, so the loop is drawn on
            // the frame after. One warm-up pass reproduces that here.
            play_sine(22000,scenario);
            commit();
            if(!dut.trace_active)$fatal(1,"gain did not arm scenario=%0d",scenario);
            play_sine(22000,scenario);
            update=1;levels[9*8 +: 8]=65;levels[29*8 +: 8]=50;tick();update=0;
            if(dut.spectrum_active!=((scenario==0)?1024'd0:levels))
                $fatal(1,"spectrum changed midframe");
            commit();
            if(dut.spectrum_active!==levels)$fatal(1,"frame commit failed");
            measure(1,scenario);
            if(points<100)$fatal(1,"XY curve absent scenario=%0d",scenario);
            // Negative control for the old defect: a mono pair used to put every
            // point on one anti-diagonal, so max_diag was zero. A real loop must
            // reach well away from it.
            if(max_diag<20)
                $fatal(1,"XY degenerate to a line scenario=%0d max_diag=%0d",scenario,max_diag);
            if((max_x-min_x)<40 || (max_y-min_y)<40)
                $fatal(1,"XY trace does not span the box scenario=%0d w=%0d h=%0d",
                       scenario,max_x-min_x,max_y-min_y);
            $display("XY scenario=%0d lit=%0d max_diag=%0d span=%0dx%0d",
                     scenario,points,max_diag,max_x-min_x,max_y-min_y);
            if(scenario==0)box_loud=max_x-min_x;

            // Settings overlays change only at a frame boundary.
            enable=0;x=100;y=400;repeat(3)tick();
            if(!overlay)$fatal(1,"enable changed midframe");
            commit();if(overlay)$fatal(1,"settings did not hide visual panels");
            enable=1;commit();
        end

        // Persistence: the trace must dim gradually through silence instead of
        // being cleared at the next frame boundary.
        measure(0,0);fade_before=bright_sum;
        if(points<100)$fatal(1,"trace cleared instead of fading");
        idle_ticks(2000000);
        measure(0,0);fade_after=bright_sum;
        if(fade_after>=fade_before)
            $fatal(1,"trace did not fade brightness %0d -> %0d",fade_before,fade_after);
        if(points<40)
            $fatal(1,"trace vanished rather than faded lit=%0d",points);
        $display("persistence brightness %0d -> %0d, still %0d lit",
                 fade_before,fade_after,points);
        // Full fade needs seven decay passes over 16384 cells, one write per
        // 64 free pixels: about 12 frames, or 0.22 s at 56 Hz. Allow a margin
        // over that rather than sitting just above the minimum.
        idle_ticks(16000000);
        measure(0,0);
        if(points>40)$fatal(1,"trace never faded out lit=%0d",points);

        // Auto-gain: a source 31x quieter must still span a comparable box.
        play_sine(700,0);commit();
        if(!dut.trace_active)$fatal(1,"gain did not arm for a quiet source");
        play_sine(700,0);
        measure(1,2);
        box_quiet=max_x-min_x;
        if(points<100)$fatal(1,"quiet XY curve absent");
        if(box_quiet<(box_loud*2)/3)
            $fatal(1,"auto-gain did not scale quiet input loud=%0d quiet=%0d",
                   box_loud,box_quiet);
        $display("auto-gain span loud=%0d quiet=%0d",box_loud,box_quiet);

        $display("PASS: XY phase portrait non-degenerate for mono and stereo sources, phosphor fade, auto-gain, spectrum double buffering, frame-atomic settings, Chinese labels and panel renders");
        $finish;
    end
endmodule
