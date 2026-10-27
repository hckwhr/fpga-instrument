`timescale 1ns/1ps
module tb_fsr_instrument;
    reg clk=0,pixel_clk=0,miso=0;
    reg [9:0] code=0,frame_code;
    wire sclk,mosi,cs0,cs1;
    wire [3:0] led;
    wire [5:0] r,g,b;
    wire hs,vs,de;
    integer edges=0,triggers=0,k,peak,light_peak,heavy_peak,mag,deadline;
    reg [4:0] command;
    reg [1:0] tone=3;
    reg mode=1,strings=0,menu=0;
    reg [3:0] note=0;
    av_top #(.FSR_ENABLE(1),.FSR_SAMPLE_PERIOD_CYCLES(10000)) dut(
        .sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.adc_miso(miso),.adc_sclk(sclk),.adc_mosi(mosi),
        .adc_cs0_n(cs0),.adc_cs1_n(cs1),.adc_led(led),
        .lcd_r(r),.lcd_g(g),.lcd_b(b),.lcd_hsync(hs),.lcd_vsync(vs),.lcd_de(de));
    always #10 clk=~clk;
    always #15 pixel_clk=~pixel_clk;
    initial begin
        force dut.pixel_clk=pixel_clk;
        // Exercise existing menu choices without changing the menu/button RTL.
        force dut.tone_select=tone;force dut.play_mode=mode;force dut.string_mode=strings;
        force dut.note_select=note;force dut.setting_mode=menu;
    end
    always @(negedge cs0)begin edges=0;command=0;frame_code=code;miso=0;end
    always @(posedge sclk)begin
        if(cs1!==1 || cs0!==0)$fatal(1,"ADC CS conflict");
        if(edges<5)command={command[3:0],mosi};
        edges=edges+1;
        if(edges==5 && command!==5'b11000)$fatal(1,"Wrong CH0 command");
    end
    always @(negedge sclk)if(edges>=6 && edges<=15)miso=frame_code[15-edges];else miso=0;
    always @(posedge dut.fsr_trigger)triggers=triggers+1;
    task samples;input integer count;integer j;begin
        for(j=0;j<count;j=j+1)begin @(posedge dut.audio_sample_strobe);@(negedge clk);end
    end endtask
    task press;input [9:0] value;begin
        code=value;wait(dut.fsr_gate);samples(4);
        if(dut.dds_gate!==3'b001 || dut.dds_force<7'd12 || dut.dds_tone!==tone || dut.dds_note!==note)
            $fatal(1,"FSR did not use actual original note/timbre/force route");
        if(dut.displayed_status_payload[2:0]!==3'b001 || dut.displayed_status_payload[12:6]!==dut.live_force)
            $fatal(1,"Original LCD key/force mismatch");
    end endtask
    task release_key;begin code=0;wait(!dut.fsr_gate);samples(300);end endtask
    task measure;output integer result;integer j,a;begin
        result=0;
        for(j=0;j<600;j=j+1)begin
            samples(1);a=$signed(dut.audio_sample);if(a<0)a=-a;
            if(a>result)result=a;
            if(a>=32767)$fatal(1,"Clipped instrument PCM");
        end
    end endtask
    initial begin
        samples(50);
        // Original defaults must remain piano, C-major chord, pluck, no effect.
        if(dut.keymap_select!==1 || dut.octave_select!==1 || dut.effect_select!==0)
            $fatal(1,"Original instrument defaults changed");
        press(180);measure(light_peak);release_key();
        press(384);measure(heavy_peak);
        if(light_peak<20 || heavy_peak<=light_peak)$fatal(1,"Piano pressure response light=%d heavy=%d",light_peak,heavy_peak);
        if(led!==0 || triggers!=2)$fatal(1,"Heavy threshold or held-key retrigger");
        // Actual original renderer commits the same status over its production CDC.
        repeat(2)@(posedge dut.lcd_frame_start);samples(2);
        if(dut.u_lcd_test_pattern.status_active[2:0]!==1 || dut.u_lcd_test_pattern.status_active[18:17]!==3)
            $fatal(1,"Original renderer did not receive FSR piano status");
        release_key();
        // Selected pitch and each existing non-piano timbre use the same event route.
        mode=0;note=7;
        for(k=0;k<3;k=k+1)begin
            tone=k;press(384);samples(600);measure(peak);
            if(peak<20)$fatal(1,"Selected timbre silent %d",k);
            release_key();
        end
        strings=1;tone=3;press(384);samples(600);measure(peak);
        if(peak<20 || dut.string_voice_count==0 || dut.string_deadline_misses!=0)
            $fatal(1,"Physical string route failed");
        release_key();strings=0;
        // Pressure must never navigate menus, change a score, or play behind settings.
        menu=1;deadline=triggers;code=384;samples(600);
        if(dut.fsr_gate || triggers!=deadline || dut.u_instrument_control.key_pressed!==0 || dut.audio_sample!==0)
            $fatal(1,"FSR leaked into settings/menu or muted audio");
        menu=0;samples(300);
        if(dut.fsr_gate || triggers!=deadline)$fatal(1,"Held press retriggered when leaving menu");
        code=0;samples(300);press(384);
        force dut.fsr_input.u_fsr.valid_sys=0;samples(15000);
        if(dut.fsr_ready || dut.fsr_gate || dut.audio_sample!==0)$fatal(1,"Stale ADC did not release original audio");
        release dut.fsr_input.u_fsr.valid_sys;
        code=0;samples(300);press(180);
        if(triggers!=deadline+2)$fatal(1,"Release/recovery event count mismatch");
        $display("PASS: original piano/timbres/strings note selection, real ADC CH0, pressure gain %0d/%0d, LCD original renderer, menu isolation, held rearm, timeout recovery",light_peak,heavy_peak);
        $finish;
    end
    initial begin #1500000000;$fatal(1,"FSR instrument test timeout");end
endmodule
