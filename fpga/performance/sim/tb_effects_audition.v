`timescale 1ns/1ps
// Production av_top routing, with only clock primitives and sample timing mocked.
module tb_effects_audition;
    reg clk=0,strobe=0,armed=0,menu=1;
    reg [2:0] target=2;
    reg [1:0] strength=1;
    reg signed [15:0] dry[0:191999];
    integer i,j,s,fd,cycles,errors=0,different,peak,mag;
    reg was_wet;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
        .status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task check;input cond;input [8*100-1:0] msg;
        begin if(cond!==1'b1)begin $display("ERROR: %0s",msg);errors=errors+1;
            if(errors>5)$fatal(1,"too many integration failures");end end endtask
    task slot;begin
        strobe=1;tick();strobe=0;cycles=0;
        repeat(20)begin tick();cycles=cycles+1;end
        while((|dut.strings_enabled.u_physical_string_bank.busy) && cycles<1023)begin tick();cycles=cycles+1;end
        check(cycles<1023,"string processing exceeded real 1024-clock slot");
        check(dut.string_deadline_misses==0,"string processing missed sample deadline");
    end endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.audition_mode=armed;
        force dut.audition_target=target;
        force dut.setting_mode=menu;
        force dut.test_mode=1'b0;
        force dut.string_mode=1'b0;
        force dut.effect_strength=strength;
        repeat(12)tick();
        for(s=0;s<3;s=s+1)for(j=2;j<=((s==1)?6:4);j=j+1)begin
            strength=s;
            menu=1;armed=0;target=j;repeat(300)slot();armed=1;menu=0;
            different=0;peak=0;
            if(s==1)case(j)
                2:fd=$fopen("sim/ab_delay.csv","w");
                3:fd=$fopen("sim/ab_chorus.csv","w");
                4:fd=$fopen("sim/ab_reverb.csv","w");
                5:fd=$fopen("sim/ab_force.csv","w");
                6:fd=$fopen("sim/ab_strings.csv","w");
            endcase
            else begin
                fd=$fopen($sformatf("sim/ab_strength_%0d_target_%0d.csv",s,j),"w");
            end
            check(fd!=0,"PCM capture failed");
            for(i=0;i<384000;i=i+1)begin
                was_wet=dut.audition_wet;slot();
                check((^dut.audio_sample)!==1'bx,"unknown production PCM");
                mag=dut.audio_sample<0?-dut.audio_sample:dut.audio_sample;
                if(mag>peak)peak=mag;
                check(mag<32767,"production audition clipped");
                if(i<192000)dry[i]=dut.audio_sample;
                else if(dut.audio_sample!=dry[i-192000])different=different+1;
                if(i==190000 || i==382000)check(dut.audio_sample==0,"separator not silent");
                if(i==10000 || i==202000)begin
                    check(dut.status_payload_cdc_audio[55:54]==strength,"LCD strength differs from effect setting");
                    check(dut.displayed_status_payload[18:17]==3,"LCD audition timbre differs from actual piano source");
                    check(dut.displayed_status_payload[12:6]==dut.audition_play_force,"LCD force differs from actual source");
                end
                $fwrite(fd,"%0d,%0d\n",dut.audio_sample,was_wet);
            end
            $fclose(fd);
            check(different>1000,"A/B target did not change the actual production sound");
            $display("AUDITION strength=%0d target=%0d peak=%0d different_samples=%0d",s,j,peak,different);
            menu=1;armed=0;repeat(300)slot();
        end
        if(errors)$fatal(1,"integration errors=%0d",errors);
        $display("PASS: production av_top delay/chorus/reverb/force/strings A-B routing, LCD payload, headroom, separators and string deadlines");
        $finish;
    end
    // Stage 30b harness: this bench forces av_top's mode wires directly, which
    // bypasses instrument_control. The three mode decodes are now registered
    // inside that module, so follow the forced wires with the same decode the
    // top level used to build. tb_song_page_mirror proves the registered
    // copies equal this decode on every clock for unforced operation.
    initial begin
        force dut.audition_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode;
        force dut.song_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode && dut.audition_target == 3'd7;
        force dut.self_test_active = dut.test_mode && !dut.setting_mode;
    end
endmodule
module audio_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=clkin;
    reg ready=0;
    initial #20 ready=1;
    assign lock=ready;
endmodule
module lcd_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=1'b0;
    reg ready=0;
    initial #20 ready=1;
    assign lock=ready;
endmodule
module ODDR(input D0,D1,TX,CLK,output Q0,Q1);
    assign Q0=CLK?D1:D0;
    assign Q1=TX;
endmodule
