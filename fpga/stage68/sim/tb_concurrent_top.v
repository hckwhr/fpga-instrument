`timescale 1ns/1ps
// All-engine self-test through the production top level: mode decode, the
// three engines, the registered three-way mix, effects bypass and the real
// PT8211 serial output. PCM is decoded from the DAC pins, not tapped inside.
// The mode registers are forced as other top-level benches do; the key
// sequence that sets them is covered by tb_concurrent_entry.
module tb_concurrent_top;
    parameter integer SETTLE_SAMPLES = 42000;   // additive bank brings up 32 partials
    parameter integer CAPTURE_SAMPLES = 65536;
    reg clk=0, rst=0, concurrent=0;
    wire bck, ws, din;
    integer fd=0, bits=0, frames=0, last_frame=-1, cycles=0, k;
    integer minimum_poly=32, minimum_strings=8;
    reg last_ws=1, have_left=0, capturing=0;
    reg [15:0] word=0, left_word=0;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk) cycles=cycles+1;
    always @(negedge bck or negedge rst) begin
        if(!rst) begin bits=0;last_ws=1;word=0;have_left=0;last_frame=-1; end
        else begin
            if(ws!=last_ws) begin bits=1;word={15'd0,din};last_ws=ws; end
            else begin bits=bits+1;word={word[14:0],din}; end
            if(bits==16) begin
                if((^word)===1'bx || word==16'h7fff || word==16'h8000) $fatal(1,"invalid or full-scale DAC word");
                if(!ws) begin left_word=word;have_left=1; end
                else if(have_left) begin
                    if(word!==left_word) $fatal(1,"stereo mismatch");
                    if(last_frame>=0 && cycles-last_frame!=1024) $fatal(1,"DAC cadence");
                    last_frame=cycles;frames=frames+1;
                    if(capturing) begin
                        $fwrite(fd,"%0d\n",$signed(left_word));
                        if(dut.polyphony_active_voice_count<minimum_poly) minimum_poly=dut.polyphony_active_voice_count;
                        if(dut.string_voice_count<minimum_strings) minimum_strings=dut.string_voice_count;
                    end
                end
            end
        end
    end
    task samples; input integer n; begin
        for(k=0;k<n;k=k+1) @(posedge dut.audio_sample_strobe);
        @(negedge clk);
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        // self_test_active is a registered output of instrument_control in this
        // baseline, not an av_top assign, so forcing test_mode alone leaves it
        // low. Force it directly, as the other top-level benches do.
        force dut.test_mode=1'b1; force dut.test_polyphony=1'b1;
        force dut.self_test_active=1'b1;
        force dut.test_concurrent=concurrent;
        repeat(8) @(posedge clk); #3; rst=1;
        // Plain polyphony self-test with no key pressed: nothing sounds.
        samples(300);
        if(dut.concurrent_active || dut.string_voice_count!=0 || dut.polyphony_active_voice_count!=0 || left_word!=0)
            $fatal(1,"engines active before the all-engine mode was selected");
        concurrent=1;
        samples(SETTLE_SAMPLES);
        if(dut.polyphony_active_voice_count!=32) $fatal(1,"polyphony holds %0d of 32",dut.polyphony_active_voice_count);
        if(dut.string_voice_count!=8) $fatal(1,"strings active %0d of 8",dut.string_voice_count);
        if(!dut.additive_all_partials_active) $fatal(1,"additive partials not all active");
        fd=$fopen("sim/concurrent_top.csv","w"); if(!fd) $fatal(1,"capture open");
        $fwrite(fd,"mix\n"); capturing=1;
        samples(CAPTURE_SAMPLES);
        capturing=0; $fclose(fd);
        if(minimum_poly!=32 || minimum_strings!=8)
            $fatal(1,"units dropped during capture: poly %0d strings %0d",minimum_poly,minimum_strings);
        if(!dut.additive_all_partials_active) $fatal(1,"additive partial dropped");
        if(dut.string_deadline_misses!=0) $fatal(1,"string deadline miss");
        if(dut.spectrum_deadline_misses!=0) $fatal(1,"DFT overrun");
        // Leaving the mode returns to the plain polyphony self-test, silent.
        concurrent=0;
        samples(3000);
        if(dut.polyphony_active_voice_count!=0 || dut.string_voice_count!=0 || left_word!=0)
            $fatal(1,"sound left over after leaving the mode: poly %0d strings %0d pcm %0d",
                   dut.polyphony_active_voice_count,dut.string_voice_count,$signed(left_word));
        $display("PASS: 32 polyphony + 8 strings + 32 additive partials held together for %0d samples through PT8211 (%0d stereo frames, cadence exact, no full-scale word); silent before and after",CAPTURE_SAMPLES,frames);
        $finish;
    end
    initial begin #2000000000; $fatal(1,"timeout"); end
endmodule
