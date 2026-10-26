`timescale 1ns/1ps
module tb_visual_top;
    `include "instrument_contract.vh"
    reg clk=0,pixel=0,rst=0;
    reg signed [15:0] dry=0,wet=0;
    reg [DISPLAY_STATUS_WIDTH-1:0] status=DEFAULT_DISPLAY_STATUS;
    wire de,hs,vs;
    wire [5:0] r,g,b;
    integer sample_number=0,fd,count,yellow,cyan,purple,n;
    reg [1:0] check_de=0,check_hs=3,check_vs=3;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
        .audio_bck(),.audio_ws(),.audio_din(),.status_led(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(hs),.lcd_vsync(vs),.lcd_de(de),.lcd_bl(),.lcd_r(r),.lcd_g(g),.lcd_b(b));
    always #5 clk=~clk;
    always #9.5 pixel=~pixel;
    always @(negedge clk)if(rst && dut.audio_sample_strobe)begin
        sample_number=sample_number+1;
        dry=$rtoi(18000*$sin(6.283185307179586*10*sample_number/1024));
        wet=$rtoi(16000*$cos(6.283185307179586*10*sample_number/1024));
    end
    always @(posedge pixel)begin
        if(!rst)begin check_de<=0;check_hs<=3;check_vs<=3;end
        else begin
            check_de<={check_de[0],dut.lcd_de_timing};
            check_hs<={check_hs[0],dut.lcd_hsync_timing};
            check_vs<={check_vs[0],dut.lcd_vsync_timing};
        end
        #2;
        if(rst && {de,hs,vs}!=={check_de[1],check_hs[1],check_vs[1]})$fatal(1,"top RGB/sync latency mismatch");
    end
    task frame;
        begin @(posedge dut.lcd_frame_start);@(negedge dut.lcd_frame_start);end
    endtask
    task render;
        input integer settings;
        begin
            fd=$fopen($sformatf("sim/visual_top_%0d.ppm",settings),"w");
            $fwrite(fd,"P3\n800 480\n63\n");
            count=0;yellow=0;cyan=0;purple=0;
            while(count<384000)begin
                @(posedge pixel);#3;
                if(de)begin
                    if((^{r,g,b})===1'bx)$fatal(1,"unknown top RGB");
                    $fwrite(fd,"%0d %0d %0d\n",r,g,b);count=count+1;
                    if(r>45 && g>35 && b<20)yellow=yellow+1;
                    if({r,g,b}=={6'd7,6'd54,6'd61})cyan=cyan+1;
                    // The XY trace is a phosphor ramp now, not one colour.
                    if({r,g,b}=={6'd63,6'd52,6'd63} || {r,g,b}=={6'd57,6'd34,6'd62} ||
                       {r,g,b}=={6'd49,6'd22,6'd58} || {r,g,b}=={6'd41,6'd16,6'd50} ||
                       {r,g,b}=={6'd32,6'd12,6'd42} || {r,g,b}=={6'd23,6'd8,6'd33} ||
                       {r,g,b}=={6'd14,6'd6,6'd23})purple=purple+1;
                    if(settings && dut.visual_overlay)$fatal(1,"panels cover settings");
                end
            end
            $fclose(fd);
            if(!settings && (yellow<50 || cyan<50 || purple<50))$fatal(1,"missing waveform/spectrum/XY: %0d %0d %0d",yellow,cyan,purple);
            $display("TOP page=%0d pixels=%0d wave=%0d spectrum=%0d XY=%0d",settings,count,yellow,cyan,purple);
        end
    endtask
    initial begin
        force dut.pixel_clk=pixel;
        force dut.audio_internal_reset_n=rst;
        force dut.pixel_internal_reset_n=rst;
        force dut.audio_sample=wet;
        force dut.pre_effect_audio_sample=dry;
        force dut.status_payload_pixel=status;
        force dut.status_payload_update_pixel=1'b1;
        repeat(4)@(negedge pixel);rst=1;
        repeat(4)frame();render(0);
        status[ST_SETTING]=1;repeat(2)frame();render(1);
        if(dut.spectrum_deadline_misses!=0)$fatal(1,"top spectrum overrun");
        $display("PASS: actual top composite, continuous raster, 384000 pixels/page, matched sync, live DFT/XY, settings unobscured");
        $finish;
    end
endmodule
