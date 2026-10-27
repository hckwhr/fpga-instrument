`timescale 1ns/1ps
module tb_hdmi_timing_800x600;
    reg clk=0,reset_n=0;
    always #5 clk=~clk;
    wire hs,vs,de,frame,panel;
    wire [10:0] x,nx;
    wire [9:0] y;
    hdmi_timing_800x600 dut(clk,reset_n,hs,vs,de,frame,panel,x,nx,y);
    integer h,v,f,active,panel_pixels,hs_pixels,vs_pixels;
    integer expected_x,expected_y,next_h,expected_nx;
    reg expected_panel;
    initial begin
        repeat(3)@(negedge clk);
        reset_n=1;
        for(f=0;f<2;f=f+1)begin
            active=0;panel_pixels=0;hs_pixels=0;vs_pixels=0;
            for(v=0;v<625;v=v+1)for(h=0;h<1024;h=h+1)begin
                if(de!==(h<800 && v<600) ||
                   hs!==(h>=824 && h<896) || vs!==(v>=601 && v<603) ||
                   frame!==(h==0 && v==0))$fatal(1,"Raster mismatch h=%0d v=%0d",h,v);
                expected_panel=h<800 && v>=60 && v<540;
                expected_x=expected_panel ? h : 2047;
                expected_y=expected_panel ? (v-60) : 1023;
                next_h=(h+1)%1024;
                expected_nx=next_h<800 && v>=60 && v<540 ? next_h : 2047;
                if(panel!==expected_panel || x!==11'(expected_x) || y!==10'(expected_y) || nx!==11'(expected_nx))
                    $fatal(1,"1:1 viewport/lookahead mismatch h=%0d v=%0d x=%0d nx=%0d y=%0d",h,v,x,nx,y);
                active+=de;panel_pixels+=panel;hs_pixels+=hs;vs_pixels+=vs;
                @(negedge clk);
            end
            if(active!=480000 || panel_pixels!=384000 || hs_pixels!=45000 || vs_pixels!=2048)
                $fatal(1,"Raster totals active=%0d panel=%0d hs=%0d vs=%0d",active,panel_pixels,hs_pixels,vs_pixels);
        end
        reset_n=0;#1;
        if(!frame || x!=2047 || y!=1023)$fatal(1,"Reset raster origin");
        $display("PASS: two complete 1024x625 DMT 800x600@56 frames; 800x600 active; positive 72/2 sync; 1:1 dashboard and RAM lookahead boundaries");
        $finish;
    end
    initial begin #60000000;$fatal(1,"800x600 raster timeout");end
endmodule
