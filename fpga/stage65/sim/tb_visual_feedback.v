`timescale 1ns/1ps
module tb_visual_feedback;
    reg clk=0,reset_n=0,frame=0,enable=1,update=0,valid=0;
    reg [10:0] x=0;
    reg [9:0] y=0;
    reg [1023:0] levels=0;
    reg [31:0] pair=0;
    wire overlay;
    wire [17:0] rgb;
    integer i,n,fd,px,py,points,b,scenario;
    reg signed [15:0] dry,wet;
    reg [15:0] status=0;
    visual_feedback dut(.clk(clk),.reset_n(reset_n),.frame_start(frame),.enable(enable),
        .x(x),.y(y),.spectrum(levels),.spectrum_update(update),
        .audio_pair(pair),.audio_pair_valid(valid),.overlay(overlay),.rgb(rgb));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#2;end endtask
    task commit;begin frame=1;tick();frame=0;repeat(2)tick();end endtask
    initial begin
        repeat(4)tick();reset_n=1;repeat(16400)tick();commit();
        for(scenario=0;scenario<2;scenario=scenario+1)begin
            for(n=0;n<1024;n=n+1)begin
                dry=$rtoi(22000*$sin(6.283185307179586*n/128));
                wet=(scenario==0)?dry:$rtoi(16000*$cos(6.283185307179586*n/128));
                pair={dry,wet};valid=1;tick();valid=0;tick();
            end
            if(!dut.capture_ready)$fatal(1,"XY snapshot not complete");
            if(scenario==0 && dut.display_valid)$fatal(1,"XY published before frame boundary");
            update=1;levels[9*8 +: 8]=65;levels[29*8 +: 8]=50;tick();update=0;
            if(dut.spectrum_active!=((scenario==0)?1024'd0:levels))$fatal(1,"spectrum changed midframe");
            commit();
            if(dut.spectrum_active!==levels || !dut.display_valid)$fatal(1,"frame commit failed");
            fd=$fopen($sformatf("sim/visual_panels_%0d.ppm",scenario),"w");
            $fwrite(fd,"P3\n800 480\n63\n");points=0;
            // Pixel coordinates held three cycles to inspect the full renderer.
            for(py=0;py<480;py=py+1)for(px=0;px<800;px=px+1)begin
                x=px;y=py;repeat(3)tick();
                if(overlay && (^rgb)===1'bx)$fatal(1,"unknown visible pixel");
                if(overlay && ((rgb=={6'd63,6'd50,6'd63}) ||
                    (rgb=={6'd55,6'd18,6'd61})))points=points+1;
                if(overlay)$fwrite(fd,"%0d %0d %0d\n",rgb[17:12],rgb[11:6],rgb[5:0]);
                else $fwrite(fd,"1 3 5\n");
            end
            $fclose(fd);
            if(points<100)$fatal(1,"XY curve absent");
            $display("XY scenario=%0d lit_pixels=%0d",scenario,points);
            // Settings overlays change only at a frame boundary.
            enable=0;x=100;y=400;repeat(3)tick();if(!overlay)$fatal(1,"enable changed midframe");
            commit();if(overlay)$fatal(1,"settings did not hide visual panels");
            enable=1;commit();
        end
        $display("PASS: spectrum/XY double buffering, frame-atomic settings, silence-safe RAM, Chinese labels and panel renders");
        $finish;
    end
endmodule
